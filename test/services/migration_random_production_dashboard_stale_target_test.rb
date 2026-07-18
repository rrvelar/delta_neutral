require "test_helper"

# 2026-07-14 fix: after a stop/repair the runner heartbeat is a historical
# snapshot; its target_short_eth / inside_tolerance must NOT be shown as current.
# The Production Control Center must render the fresh authoritative target and
# inside_tolerance when the runner is stopped.
class MigrationRandomProductionDashboardStaleTargetTest < ActiveSupport::TestCase
  STALE_TARGET = "1.599862590055613".freeze
  FRESH_TARGET = "1.468542942762735".freeze

  def dashboard(dir)
    MigrationRandomProductionDashboard.new(position: @position, log_dir: dir)
  end

  def write_files(dir, running:)
    FileUtils.mkdir_p(dir)
    # Fresh status file (post-repair): inside tolerance true, current short 1.465.
    File.write(dir.join("status_position_#{@position.id}.json"), JSON.pretty_generate(
      status: running ? "running" : "stopped",
      updated_at: Time.current.utc.iso8601,
      current_production_venue: "extended",
      inside_tolerance: true,
      direct_venue_shorts: { nado: "0.0", ethereal: "0.0", extended: "1.465" },
      blockers: []
    ))
    # Stale heartbeat from the last cycle: target 1.599863, out of tolerance.
    File.write(dir.join("heartbeat_position_#{@position.id}.json"), JSON.pretty_generate(
      status: running ? "running" : "stopped",
      updated_at: 8.hours.ago.utc.iso8601,
      current_production_venue: "extended",
      target_short_eth: STALE_TARGET,
      combined_short_eth: "1.711",
      inside_tolerance: false
    ))
    if running
      File.write(dir.join("lock_position_#{@position.id}.json"), JSON.pretty_generate(pid: Process.pid, runner: "random_production_runner"))
    end
  end

  test "stopped runner renders fresh target and inside_tolerance, not the stale heartbeat" do
    @position = position_with_fresh_snapshot
    dir = Rails.root.join("tmp/prod-dash-target-#{SecureRandom.hex(4)}")
    write_files(dir, running: false)

    report = dashboard(dir).report

    assert_equal FRESH_TARGET, report[:target_short_eth]
    refute_equal STALE_TARGET, report[:target_short_eth]
    assert_equal true, report[:inside_tolerance]
    assert_match(/live position snapshot \(runner stopped\)/, report[:target_source])
    # historical heartbeat value is still surfaced separately, labeled
    assert_equal STALE_TARGET, report[:heartbeat_target_short_eth]
  end

  test "stopped runner with no fresh snapshot target does not leak the stale heartbeat target" do
    @position = position_with_fresh_snapshot(target: nil)
    dir = Rails.root.join("tmp/prod-dash-target-#{SecureRandom.hex(4)}")
    write_files(dir, running: false)

    report = dashboard(dir).report

    assert_nil report[:target_short_eth]
    refute_equal STALE_TARGET, report[:target_short_eth]
    assert_equal true, report[:inside_tolerance]
    assert_match(/fresh target unavailable/, report[:target_source])
  end

  test "report surfaces fresh operational warnings" do
    @position = position_with_fresh_snapshot
    dir = Rails.root.join("tmp/prod-dash-target-#{SecureRandom.hex(4)}")
    write_files(dir, running: false)
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test")

    report = dashboard(dir).report

    warnings = Array(report[:operational_warnings])
    assert warnings.any? { |w| w.include?("EXTENDED_AUTO_REBALANCE_ENABLED") && w.include?("DB override") }, warnings.inspect
  end

  test "report surfaces the extended venue admission status" do
    @position = position_with_fresh_snapshot
    dir = Rails.root.join("tmp/prod-dash-target-#{SecureRandom.hex(4)}")
    write_files(dir, running: false)
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    report = dashboard(dir).report

    status = report[:extended_venue_status]
    assert_equal "PROBATION", status[:state]
    assert_equal true, status[:autonomous_production_blocked]
    assert status.key?(:submit_health)
  end

  test "running runner keeps heartbeat target as current" do
    @position = position_with_fresh_snapshot
    dir = Rails.root.join("tmp/prod-dash-target-#{SecureRandom.hex(4)}")
    write_files(dir, running: true)

    report = dashboard(dir).report

    assert_equal STALE_TARGET, report[:target_short_eth]
    assert_equal false, report[:inside_tolerance]
    assert_match(/last heartbeat \(runner active\)/, report[:target_source])
  end

  private

  def position_with_fresh_snapshot(target: MigrationRandomProductionDashboardStaleTargetTest::FRESH_TARGET)
    position = Position.create!(
      user: users(:one), wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH", asset1: "USDC", asset0_amount: "1.4685", asset1_amount: "500",
      asset0_price_usd: "2000", asset1_price_usd: "1",
      external_id: SecureRandom.hex(6), pool_address: "0x#{SecureRandom.hex(20)}", active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current, refresh_status: "ok", stale: false,
      production_venue: "extended", selected_venue: "extended",
      target_short_eth: target, tolerance_abs_eth: "0.044",
      combined_short_eth: "1.465", drift_eth: "0.003", inside_tolerance: true,
      extended_short_eth: "1.465", ethereal_short_eth: "0", nado_short_eth: "0",
      signer_status: "ok"
    )
    position
  end
end
