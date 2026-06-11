require "test_helper"

class MigrationRandomProductionRunnerTest < ActiveSupport::TestCase
  test "uses proven burn-in random execution path" do
    position = migration_position
    dir = tmp_dir
    events = []
    fake = FakeBurnInRunner.new(events: [ cycle_event ])

    result = runner(position: position, log_dir: dir, runner_factory: ->(event_callback:, stop_requested:) {
      events << { callback: event_callback, stop: stop_requested }
      fake.callback = event_callback
      fake
    }).run

    assert_equal "success", result.status
    assert_equal [ "cycle" ], fake.emitted_events.map { |event| event.fetch(:event) }
    assert_equal "nado", JSON.parse(File.read(dir.join("heartbeat_position_#{position.id}.json"))).fetch("current_production_venue")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "starts burn-in runner with production defaults" do
    position = migration_position
    dir = tmp_dir
    captured = nil
    fake = FakeBurnInRunner.new(events: [ cycle_event ])

    MigrationRandomBurnInRunner.stub(:new, ->(**kwargs) {
      captured = kwargs
      fake
    }) do
      result = runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory).run
      assert_equal "success", result.status
    end

    assert_equal 3900, captured.fetch(:interval_seconds)
    assert_equal 300, captured.fetch(:rebalance_hold_interval_seconds)
    assert_equal true, captured.fetch(:rebalance_after_migration)
    assert_equal true, captured.fetch(:rebalance_during_hold)
    assert_equal true, captured.fetch(:rebalance_before_next_migration)
    assert_equal true, captured.fetch(:rebalance_only_if_outside_tolerance)
    assert_equal 4, captured.fetch(:rebalance_readback_recheck_attempts)
    assert_equal 5, captured.fetch(:rebalance_readback_recheck_interval_seconds)
    assert_equal MigrationRandomBurnInRunner::CONFIRMATION, captured.fetch(:confirmation)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "writes heartbeat status and lock files" do
    position = migration_position
    dir = tmp_dir
    fake = FakeBurnInRunner.new(events: [ cycle_event ])

    runner(position: position, log_dir: dir, runner_factory: ->(event_callback:, **) {
      fake.callback = event_callback
      fake
    }).run

    assert_predicate dir.join("heartbeat_position_#{position.id}.json"), :exist?
    assert_predicate dir.join("status_position_#{position.id}.json"), :exist?
    assert_predicate dir.join("latest_position_#{position.id}.jsonl"), :exist?
    assert_not_predicate dir.join("lock_position_#{position.id}.json"), :exist?
    status = JSON.parse(File.read(dir.join("status_position_#{position.id}.json")))
    assert_equal "success", status.fetch("status")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "refuses parallel run for active lock" do
    position = migration_position
    dir = tmp_dir
    FileUtils.mkdir_p(dir)
    File.write(dir.join("lock_position_#{position.id}.json"), JSON.generate(runner: "random_burn_in", pid: Process.pid))

    result = runner(position: position, log_dir: dir).run

    assert_equal "blocked", result.status
    assert_match "random_burn_in already running", result.blockers.join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "stale lock recovers only after direct preflight is safe" do
    position = migration_position
    dir = tmp_dir
    FileUtils.mkdir_p(dir)
    File.write(dir.join("lock_position_#{position.id}.json"), JSON.generate(runner: "random_production_runner", pid: 99_999_999))
    fake = FakeBurnInRunner.new(events: [ cycle_event ])

    safe = runner(position: position, log_dir: dir, runner_factory: ->(event_callback:, **) {
      fake.callback = event_callback
      fake
    }).run
    File.write(dir.join("lock_position_#{position.id}.json"), JSON.generate(runner: "random_production_runner", pid: 99_999_999))
    unsafe = runner(position: position, log_dir: dir, preflight_factory: unsafe_open_orders_preflight_factory, runner_factory: ->(**) { fake }).run

    assert_equal "success", safe.status
    assert_equal "blocked", unsafe.status
    assert_includes unsafe.blockers, "direct preflight open orders are nonzero or unknown"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "stop request disables gates and exits cleanly" do
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_AUTO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", enabled: true)
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir)
    service.stop!

    result = runner(position: position, log_dir: dir, runner_factory: ->(event_callback:, stop_requested:) {
      FakeBurnInRunner.new(status: stop_requested.call ? "stopped" : "success", blockers: stop_requested.call ? [ "stop requested" ] : [])
    }).run

    assert_equal "stopped", result.status
    assert_equal false, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "TERM or INT path disables gates in ensure" do
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_AUTO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", enabled: true)
    position = migration_position
    dir = tmp_dir

    result = runner(position: position, log_dir: dir, runner_factory: ->(**) { RaisingBurnInRunner.new }).run

    assert_equal "stopped", result.status
    assert_equal false, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "restart from safe active venue continues" do
    position = migration_position
    dir = tmp_dir
    result = runner(position: position, log_dir: dir, runner_factory: ->(**) { FakeBurnInRunner.new }).run

    assert_equal "success", result.status
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "restart from outside tolerance active venue allows pre-start rebalance path" do
    position = migration_position
    dir = tmp_dir
    result = runner(position: position, log_dir: dir, preflight_factory: outside_tolerance_preflight_factory, runner_factory: ->(**) { FakeBurnInRunner.new }).run

    assert_equal "success", result.status
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "restart with open orders does not continue" do
    position = migration_position
    dir = tmp_dir
    result = runner(position: position, log_dir: dir, preflight_factory: unsafe_open_orders_preflight_factory).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "direct preflight open orders are nonzero or unknown"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "restart with multiple venue exposure does not continue" do
    position = migration_position
    dir = tmp_dir
    result = runner(position: position, log_dir: dir, preflight_factory: multiple_exposure_preflight_factory).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "direct preflight must show exactly one active venue exposure"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "snapshot blockers are diagnostic when direct preflight is clean" do
    position = migration_position
    position.position_dashboard_snapshot.update!(
      refresh_status: "partial",
      source_errors: JSON.generate({ extended: "critical Extended readback failed" })
    )
    dir = tmp_dir
    service = runner(position: position, log_dir: dir, runner_factory: ->(**) { FakeBurnInRunner.new })

    result = service.run
    status = service.status

    assert_equal "success", result.status
    assert_equal "dashboard_snapshot_diagnostic", status.fetch(:dashboard_snapshot_diagnostic).fetch(:label)
    assert_equal true, status.fetch(:dashboard_snapshot_diagnostic).fetch(:accepted_for_execution)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "hold timing warning has five second grace" do
    position = migration_position
    runner = MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: 1,
      interval_seconds: 3900,
      max_cycles: 1,
      live: false
    )

    warning = runner.send(:hold_monitor_gap_warning, expected_checks: 13, expected_span: 3600, actual_span: 3599, checks: Array.new(13) { {} })

    assert_nil warning
  end

  test "24 hour canary dry-run path submits zero orders and signatures" do
    position = migration_position
    dir = tmp_dir
    fake = FakeBurnInRunner.new(summary: { orders_submitted: 0, signatures_created: 0 })

    result = runner(position: position, live: false, duration_minutes: 1440, log_dir: dir, runner_factory: ->(**) { fake }).run

    assert_equal "success", result.status
    assert_equal 0, result.summary.fetch(:orders_submitted)
    assert_equal 0, result.summary.fetch(:signatures_created)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "systemd documentation is present" do
    doc = Rails.root.join("docs/RANDOM_PRODUCTION_RUNNER.md")

    assert_predicate doc, :exist?
    assert_includes File.read(doc), "delta-neutral-random-production-6.service"
    assert_includes File.read(doc), "migration:random_production_runner"
  end

  private

  def runner(position:, live: true, duration_minutes: 0, log_dir:, preflight_factory: safe_preflight_factory, runner_factory: nil)
    MigrationRandomProductionRunner.new(
      position: position,
      live: live,
      confirmation: MigrationRandomProductionRunner::CONFIRMATION,
      duration_minutes: duration_minutes,
      log_dir: log_dir,
      preflight_factory: preflight_factory,
      runner_factory: runner_factory,
      trap_signals: false
    )
  end

  def tmp_dir
    Rails.root.join("tmp/test-random-production-#{SecureRandom.hex(4)}")
  end

  def migration_position
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "2.65",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    ).tap do |position|
      position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "nado")
      position.create_position_dashboard_snapshot!(
        refreshed_at: Time.current,
        refresh_status: "ok",
        stale: false,
        production_venue: "nado",
        selected_venue: "nado",
        target_short_eth: "2.12",
        tolerance_abs_eth: "0.0636",
        combined_short_eth: "2.12",
        drift_eth: "0",
        inside_tolerance: true,
        extended_short_eth: "0",
        ethereal_short_eth: "0",
        nado_short_eth: "2.12",
        extended_status: "flat",
        ethereal_status: "flat",
        nado_status: "active",
        extended_source_status: "ok",
        ethereal_source_status: "ok",
        nado_source_status: "ok",
        open_orders_count_extended: 0,
        signer_status: "ok"
      )
    end
  end

  def safe_preflight_factory
    ->(position:, stage:) { preflight(venue_shorts: { "nado" => "2.12" }, inside: true, blockers: []) }
  end

  def outside_tolerance_preflight_factory
    ->(position:, stage:) {
      preflight(
        venue_shorts: { "nado" => "1.90" },
        inside: false,
        blockers: [ "current hedge outside tolerance: target_short_eth=2.12 current_short_eth=1.90" ]
      )
    }
  end

  def unsafe_open_orders_preflight_factory
    ->(position:, stage:) { preflight(venue_shorts: { "nado" => "2.12" }, inside: true, open_orders_status: "nonzero", blockers: [ "nado open orders could not be confirmed zero" ]) }
  end

  def multiple_exposure_preflight_factory
    ->(position:, stage:) { preflight(venue_shorts: { "nado" => "1.0", "ethereal" => "1.12" }, inside: true, blockers: []) }
  end

  def preflight(venue_shorts:, inside:, blockers:, open_orders_status: "zero")
    venues = HedgeVenues::SUPPORTED_KEYS.to_h do |venue|
      [ venue, { short_eth: BigDecimal(venue_shorts.fetch(venue, "0")), open_orders_status: open_orders_status, open_orders_count: open_orders_status == "zero" ? 0 : 1 } ]
    end
    combined = venues.values.sum(BigDecimal("0")) { |venue| venue.fetch(:short_eth) }
    {
      preflight_source: "test_random_production_preflight",
      accepted: blockers.empty?,
      blockers: blockers,
      warnings: [],
      production_venue: venue_shorts.key("nado") ? "nado" : venue_shorts.keys.first,
      target: { target_short_eth: BigDecimal("2.12"), target_source: "test", target_fresh: true },
      venues: venues,
      active_short_venues: venues.select { |_venue, payload| payload.fetch(:short_eth).positive? }.keys,
      combined_short_eth: combined,
      drift_eth: BigDecimal("2.12") - combined,
      inside_tolerance: inside,
      proof_report: { routes: [], completed_route_proofs: [], missing_route_proofs: [], stale_route_proofs: [] },
      readiness: { blockers: [] },
      signer: { status: "ok", payload: { ok: true } }
    }
  end

  def cycle_event
    {
      event: "cycle",
      cycle: 3,
      route: "extended->nado",
      hold_rebalance_checks: [ { checked_at: Time.current.utc.iso8601 } ],
      status: "success"
    }
  end

  class FakeBurnInRunner
    attr_reader :emitted_events
    attr_writer :callback

    def initialize(status: "success", blockers: [], events: [], summary: {})
      @status = status
      @blockers = blockers
      @events = events
      @summary = { orders_submitted: 0, signatures_created: 0 }.merge(summary)
      @emitted_events = []
    end

    def run
      @events.each do |event|
        @emitted_events << event
        @callback&.call(event)
      end
      MigrationRandomBurnInRunner::Result.new(@status, @blockers, [], "tmp/fake.jsonl", @summary)
    end
  end

  class RaisingBurnInRunner
    def run
      raise SignalException, "TERM"
    end
  end
end
