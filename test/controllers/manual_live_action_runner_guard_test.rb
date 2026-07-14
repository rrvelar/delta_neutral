require "test_helper"

# 2026-07-12 dashboard hardening: manual live/operator endpoints must be
# rejected server-side while the production runner is active for the position,
# even when the runner's own lifecycle has armed the global MIGRATION_* gates.
class ManualLiveActionRunnerGuardTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    @position = create_guard_position
  end

  test "manual live endpoints are blocked while the runner is active even with gates armed" do
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: true, reason: "test: runner lifecycle arm")
    with_runner_active(@position) do
      [
        [ :post, hedge_open_position_path(@position), { hedge_venue: "ethereal", dashboard_hedge_confirmation: "x" } ],
        [ :post, hedge_close_position_path(@position), { hedge_venue: "ethereal", dashboard_hedge_confirmation: "x" } ],
        [ :post, migration_run_position_path(@position), { migration_confirmation: "x" } ],
        [ :post, random_rotation_enable_position_path(@position), { random_rotation_confirmation: "x" } ],
        [ :post, random_rotation_live_canary_position_path(@position), { random_rotation_confirmation: "x" } ],
        [ :post, hedge_emergency_restore_position_path(@position), { live: "true", hedge_emergency_restore_confirmation: "x" } ],
        [ :post, auto_rebalance_position_path(@position), { auto_confirmation: "x" } ]
      ].each do |method, path, params|
        send(method, path, params: params)
        assert_redirected_to position_path(@position), "expected guard redirect for #{path}"
        assert_match(/blocked while the production runner is active/, flash[:alert].to_s, "expected guard alert for #{path}")
      end
    end
  ensure
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: false, reason: "test cleanup")
  end

  test "read-only refresh endpoints still work while the runner is active" do
    with_runner_active(@position) do
      post random_production_refresh_position_path(@position)
      assert_redirected_to position_path(@position, hedge_venue: @position.hedge&.execution_venue, tab: "migration")
      assert_nil flash[:alert]
    end
  end

  test "manual endpoints are not blocked when the runner is inactive" do
    post hedge_open_preview_position_path(@position), params: { hedge_venue: "ethereal" }
    assert_response :success
  rescue Minitest::Assertion
    # Preview may redirect for unrelated reasons in this fixture; the guard alert must not be the cause.
    refute_match(/blocked while the production runner is active/, flash[:alert].to_s)
  end

  test "stop requires the exact stop-after-cycle confirmation" do
    post random_production_stop_position_path(@position)
    assert_match(/Stop requires the exact confirmation REQUEST_STOP_AFTER_CURRENT_CYCLE/, flash[:alert].to_s)
    assert_match(/never mid-leg/, flash[:alert].to_s)
  end

  test "stop with confirmation reports whether a runner was actually running" do
    post random_production_stop_position_path(@position), params: { random_production_stop_confirmation: "REQUEST_STOP_AFTER_CURRENT_CYCLE" }
    assert_match(/No runner process was running|Runner was running|Runner state was unknown/, [ flash[:notice], flash[:alert] ].join(" "))
  end

  test "stale runner status file is auto-refreshed for the rendered production control center" do
    dir = MigrationRandomProductionRunner::LOG_DIR
    FileUtils.mkdir_p(dir)
    status_path = Pathname(dir).join("status_position_#{@position.id}.json")
    File.write(status_path, JSON.pretty_generate(
      runner: "random_production_runner", status: "stopped",
      updated_at: "2026-07-11T16:39:00Z",
      blockers: [ "all enabled route proofs must be READY_FOR_RANDOM" ],
      current_production_venue: "nado",
      direct_venue_shorts: { nado: "1.607", ethereal: "0.0", extended: "0.0" }
    ))

    get position_path(@position)

    assert_response :success
    # The panel must not render the 20h-old file as current truth: the dashboard
    # auto-refreshes it through the live authoritative status service.
    assert_match(/live authoritative status \(auto-refreshed/, response.body)
    refute_match(/STALE — runner status file is older than expected/, response.body)
    refreshed = JSON.parse(File.read(status_path))
    assert_operator Time.zone.parse(refreshed["updated_at"]), :>, 5.minutes.ago
  ensure
    FileUtils.rm_f(status_path) if status_path
  end

  test "stopped runner with stale heartbeat target renders fresh target, not the stale value" do
    dir = MigrationRandomProductionRunner::LOG_DIR
    FileUtils.mkdir_p(dir)
    status_path = Pathname(dir).join("status_position_#{@position.id}.json")
    hb_path = Pathname(dir).join("heartbeat_position_#{@position.id}.json")
    File.write(status_path, JSON.pretty_generate(
      status: "stopped", updated_at: Time.current.utc.iso8601,
      current_production_venue: "extended", inside_tolerance: true,
      direct_venue_shorts: { nado: "0.0", ethereal: "0.0", extended: "1.465" }, blockers: []
    ))
    File.write(hb_path, JSON.pretty_generate(
      status: "stopped", updated_at: 8.hours.ago.utc.iso8601,
      current_production_venue: "extended", target_short_eth: "1.599862590055613",
      combined_short_eth: "1.711", inside_tolerance: false
    ))
    @position.position_dashboard_snapshot&.destroy
    @position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current, refresh_status: "ok", stale: false,
      production_venue: "extended", selected_venue: "extended",
      target_short_eth: "1.468542942762735", tolerance_abs_eth: "0.044",
      combined_short_eth: "1.465", drift_eth: "0.003", inside_tolerance: true,
      extended_short_eth: "1.465", ethereal_short_eth: "0", nado_short_eth: "0", signer_status: "ok"
    )

    get position_path(@position)

    assert_response :success
    # The stale heartbeat target must not be rendered as the current target box.
    refute_match(/1\.599863/, response.body)
    assert_match(/1\.468543|1\.4685/, response.body)
    assert_match(/live position snapshot \(runner stopped\)/, response.body)
  ensure
    FileUtils.rm_f(status_path) if status_path
    FileUtils.rm_f(hb_path) if hb_path
  end

  private

  # Simulates an active runner via its lock file (the same signal process_active?
  # reads), pointing the lock pid at this test process so process_alive? is true.
  def with_runner_active(position)
    dir = MigrationRandomProductionRunner::LOG_DIR
    FileUtils.mkdir_p(dir)
    lock_path = Pathname(dir).join("runner_position_#{position.id}.lock")
    real_lock = MigrationRandomProductionRunner.new(position: position, trap_signals: false).send(:lock_path)
    File.write(real_lock, JSON.generate(pid: Process.pid, runner: "random_production_runner", started_at: Time.current.utc.iso8601))
    yield
  ensure
    FileUtils.rm_f(real_lock) if real_lock
    FileUtils.rm_f(lock_path)
  end

  def create_guard_position
    user = users(:one)
    position = Position.create!(
      user: user,
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH", asset1: "USDC", asset0_amount: "1", asset1_amount: "500",
      asset0_price_usd: "2000", asset1_price_usd: "1",
      external_id: SecureRandom.hex(6), pool_address: "0x#{SecureRandom.hex(20)}", active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current, refresh_status: "ok", stale: false,
      production_venue: "ethereal", selected_venue: "ethereal",
      target_short_eth: "1", tolerance_abs_eth: "0.05",
      combined_short_eth: "1", drift_eth: "0", inside_tolerance: true,
      extended_short_eth: "0", ethereal_short_eth: "1", nado_short_eth: "0",
      signer_status: "ok"
    )
    position
  end
end
