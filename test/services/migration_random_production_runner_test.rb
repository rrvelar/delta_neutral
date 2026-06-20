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

    assert_equal 28_800, captured.fetch(:interval_seconds)
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

  test "post migration progress updates heartbeat venue cycle and route immediately" do
    position = migration_position
    dir = tmp_dir
    fake = FakeBurnInRunner.new(events: [
      {
        event: "cycle_progress",
        progress: "post_migration_finalized",
        cycle: 1,
        route: "ethereal->nado",
        from_venue: "ethereal",
        to_venue: "nado",
        status: "success"
      }
    ])

    runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory(venue: "nado"), runner_factory: ->(event_callback:, **) {
      fake.callback = event_callback
      fake
    }).run

    heartbeat = JSON.parse(File.read(dir.join("heartbeat_position_#{position.id}.json")))
    status = JSON.parse(File.read(dir.join("status_position_#{position.id}.json")))

    assert_equal "nado", heartbeat.fetch("current_production_venue")
    assert_equal 1, heartbeat.fetch("last_cycle")
    assert_equal "ethereal->nado", heartbeat.fetch("last_route")
    assert_equal "nado", status.fetch("current_production_venue")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "hold check progress updates heartbeat during long hold" do
    position = migration_position
    dir = tmp_dir
    checked_at = Time.current.utc.iso8601
    fake = FakeBurnInRunner.new(events: [
      {
        event: "hold_check",
        cycle: 1,
        route: "ethereal->nado",
        checked_at: checked_at,
        hold_rebalance_checks_count: 1,
        status: "running",
        blockers: []
      }
    ])

    runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory(venue: "nado"), runner_factory: ->(event_callback:, **) {
      fake.callback = event_callback
      fake
    }).run

    heartbeat = JSON.parse(File.read(dir.join("heartbeat_position_#{position.id}.json")))

    assert_equal "nado", heartbeat.fetch("current_production_venue")
    assert_equal "ethereal->nado", heartbeat.fetch("last_route")
    assert_equal checked_at, heartbeat.fetch("last_hold_check_at")
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

  test "clears stale stop request on fresh start" do
    position = migration_position
    dir = tmp_dir
    FileUtils.mkdir_p(dir)
    stop_path = dir.join("stop_position_#{position.id}.json")
    File.write(stop_path, JSON.generate(status: "stop_requested", position_id: position.id))

    result = runner(position: position, log_dir: dir, runner_factory: ->(**) { FakeBurnInRunner.new }).run

    assert_equal "success", result.status
    assert_not_predicate stop_path, :exist?
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "stop request disables gates and exits cleanly" do
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_AUTO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", enabled: true)
    position = migration_position
    dir = tmp_dir

    result = runner(position: position, log_dir: dir, runner_factory: ->(event_callback:, stop_requested:) {
      StopDuringRunBurnInRunner.new(
        stop_path: dir.join("stop_position_#{position.id}.json"),
        stop_requested: stop_requested
      )
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
    assert_match "unsafe_multiple_exposure", result.blockers.join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "duplicate runner process blocks start even when lock is missing" do
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir)

    service.stub(:duplicate_runner_process_running?, true) do
      result = service.run
      assert_equal "blocked", result.status
      assert_includes result.blockers, "duplicate_runner_process"
    end
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status does not report stale heartbeat as running" do
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir)
    FileUtils.mkdir_p(dir)
    File.write(dir.join("heartbeat_position_#{position.id}.json"), JSON.generate(status: "running", pid: 99_999_999))

    assert_equal "stale_heartbeat", service.status.fetch(:status)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status shows direct venue instead of stale heartbeat venue" do
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory(venue: "nado"))
    FileUtils.mkdir_p(dir)
    File.write(dir.join("heartbeat_position_#{position.id}.json"), JSON.generate(status: "running", current_production_venue: "ethereal", updated_at: 30.minutes.ago.utc.iso8601, pid: 99_999_999))

    status = service.status

    assert_equal "stale_heartbeat", status.fetch(:status)
    assert_equal "nado", status.fetch(:current_production_venue)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status separates historical stop reason from current direct market safety" do
    position = migration_position
    dir = tmp_dir
    FileUtils.mkdir_p(dir)
    File.write(
      dir.join("latest_position_#{position.id}.jsonl"),
      JSON.generate(event: "burn_in_finished", status: "stopped", blocker_status: "stopped_active_rebalance", blockers: [ "historical readback lag" ])
    )
    service = runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory(venue: "nado"))

    status = service.status

    assert_equal "stopped_active_rebalance", status.fetch(:historical_stop_reason)
    assert_equal true, status.fetch(:current_direct_market_safe)
    assert_equal true, status.fetch(:inside_tolerance)
    assert_empty status.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status reports gates true with no process as unsafe" do
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: true)
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir)

    assert_equal "unsafe_gates_left_enabled", service.status.fetch(:status)
  ensure
    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: false)
    FileUtils.rm_rf(dir) if dir
  end

  test "status reports multiple venue exposure as unsafe" do
    position = migration_position
    dir = tmp_dir
    service = runner(position: position, log_dir: dir, preflight_factory: multiple_exposure_preflight_factory)

    status = service.status

    assert_equal "unsafe_multiple_exposure", status.fetch(:status)
    assert_match "ethereal=1.12", status.fetch(:blockers).join(" ")
    assert_match "nado=1.0", status.fetch(:blockers).join(" ")
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

  test "daily venue coverage prefers next venue before repeating" do
    position = migration_position
    runner = MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: 1,
      interval_seconds: 28_800,
      max_cycles: 1,
      live: false,
      proof_registry: CoverageProofRegistry.new
    )

    route = runner.send(:select_route)

    assert_equal "nado->extended", route.fetch(:route)
  end

  test "systemd documentation is present" do
    doc = Rails.root.join("docs/RANDOM_PRODUCTION_RUNNER.md")

    assert_predicate doc, :exist?
    assert_includes File.read(doc), "delta-neutral-random-production-6.service"
    assert_includes File.read(doc), "migration:random_production_runner"
  end

  test "status does not fabricate multiple exposure from a stale carried-forward venue read" do
    position = migration_position
    dir = tmp_dir
    factory = ->(position:, stage:) {
      detailed_preflight(
        production_venue: "ethereal",
        inside: true,
        venues: {
          "extended" => { short_eth: BigDecimal("1.997"), position_status: "error", source_status: "stale", critical_read_status: "error_carried_forward" },
          "ethereal" => { short_eth: BigDecimal("1.9666"), position_status: "ok" }
        }
      )
    }
    service = runner(position: position, log_dir: dir, preflight_factory: factory)

    status = service.status

    assert_equal "unsafe_unknown_exposure", status.fetch(:status)
    refute_equal "unsafe_multiple_exposure", status.fetch(:status)
    assert_equal [ "ethereal" ], status.fetch(:active_short_venues)
    assert_equal "unknown", status.fetch(:direct_venue_shorts).fetch("extended")
    assert_equal "1.9666", status.fetch(:direct_venue_shorts).fetch("ethereal")
    assert_equal false, status.fetch(:current_direct_market_safe)
    assert_match "venue readback could not be confirmed for extended", status.fetch(:blockers).join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status treats fresh confirmed single venue as safe and reports flat venue as zero" do
    position = migration_position
    dir = tmp_dir
    factory = ->(position:, stage:) {
      detailed_preflight(
        production_venue: "ethereal",
        inside: true,
        venues: {
          "extended" => { short_eth: BigDecimal("0"), position_status: "ok" },
          "ethereal" => { short_eth: BigDecimal("1.9666"), position_status: "ok" }
        }
      )
    }
    service = runner(position: position, log_dir: dir, preflight_factory: factory)

    status = service.status

    assert_equal true, status.fetch(:current_direct_market_safe)
    assert_equal [ "ethereal" ], status.fetch(:active_short_venues)
    assert_equal "0.0", status.fetch(:direct_venue_shorts).fetch("extended")
    refute_includes %w[unsafe_multiple_exposure unsafe_unknown_exposure active_venue_mismatch], status.fetch(:status)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "start blocks when fresh active venue differs from production venue" do
    position = migration_position
    position.hedge.update!(execution_venue: "extended")
    dir = tmp_dir
    factory = ->(position:, stage:) {
      detailed_preflight(
        production_venue: "extended",
        inside: true,
        venues: {
          "extended" => { short_eth: BigDecimal("0"), position_status: "ok" },
          "ethereal" => { short_eth: BigDecimal("1.9666"), position_status: "ok" }
        }
      )
    }
    invoked = false
    result = runner(position: position, log_dir: dir, preflight_factory: factory, runner_factory: ->(**) { invoked = true; FakeBurnInRunner.new }).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "active venue differs from production venue; use supervised adopt/sync production venue"
    assert_equal false, invoked
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "status with dead lock keeps direct market safe and surfaces clear stale lock action" do
    position = migration_position
    dir = tmp_dir
    FileUtils.mkdir_p(dir)
    File.write(dir.join("lock_position_#{position.id}.json"), JSON.generate(runner: "random_production_runner", pid: 99_999_999))
    service = runner(position: position, log_dir: dir, preflight_factory: safe_preflight_factory(venue: "nado"))

    status = service.status

    assert_equal "stale_lock", status.fetch(:status)
    assert_equal true, status.fetch(:current_direct_market_safe)
    assert_equal [ "lock points to a dead process" ], status.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  private

  def detailed_preflight(production_venue:, inside:, venues:, blockers: [], open_orders_status: "zero")
    venue_details = HedgeVenues::SUPPORTED_KEYS.to_h do |venue|
      overrides = venues.fetch(venue, { short_eth: BigDecimal("0"), position_status: "ok" })
      details = {
        short_eth: overrides[:short_eth],
        position_status: overrides.fetch(:position_status, "ok"),
        open_orders_status: overrides.fetch(:open_orders_status, open_orders_status),
        open_orders_count: overrides.fetch(:open_orders_status, open_orders_status) == "zero" ? 0 : 1
      }
      details[:source_status] = overrides[:source_status] if overrides[:source_status]
      details[:critical_read_status] = overrides[:critical_read_status] if overrides[:critical_read_status]
      [ venue, details ]
    end
    # Mirror the real preflight: active_short_venues is computed from short>epsilon for
    # every venue regardless of whether the readback was confirmed, stale, or errored.
    positive = venue_details.select { |_v, d| d[:short_eth] && d[:short_eth].positive? }.keys
    combined = venue_details.values.sum(BigDecimal("0")) { |d| d[:short_eth] || BigDecimal("0") }
    {
      preflight_source: "test_random_production_preflight",
      accepted: blockers.empty?,
      blockers: blockers,
      warnings: [],
      production_venue: production_venue,
      target: { target_short_eth: BigDecimal("2.12"), target_source: "test", target_fresh: true },
      venues: venue_details,
      active_short_venues: positive,
      combined_short_eth: combined,
      drift_eth: BigDecimal("2.12") - combined,
      inside_tolerance: inside,
      proof_report: { routes: [], completed_route_proofs: [], missing_route_proofs: [], stale_route_proofs: [] },
      readiness: { blockers: [] },
      signer: { status: "ok", payload: { ok: true } }
    }
  end

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

  def safe_preflight_factory(venue: "nado")
    ->(position:, stage:) { preflight(venue_shorts: { venue => "2.12" }, inside: true, blockers: []) }
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

  class StopDuringRunBurnInRunner
    def initialize(stop_path:, stop_requested:)
      @stop_path = stop_path
      @stop_requested = stop_requested
    end

    def run
      File.write(@stop_path, JSON.generate(status: "stop_requested"))
      status = @stop_requested.call ? "stopped" : "success"
      blockers = status == "stopped" ? [ "stop requested" ] : []
      MigrationRandomBurnInRunner::Result.new(status, blockers, [], "tmp/fake.jsonl", { orders_submitted: 0, signatures_created: 0 })
    end
  end

  class RaisingBurnInRunner
    def run
      raise SignalException, "TERM"
    end
  end

  class CoverageProofRegistry
    def report(position:)
      {
        routes: [
          { route: "nado->ethereal", from_venue: "nado", to_venue: "ethereal", status: MigrationRouteProofRegistry::STATUSES[:ready] },
          { route: "nado->extended", from_venue: "nado", to_venue: "extended", status: MigrationRouteProofRegistry::STATUSES[:ready] }
        ]
      }
    end
  end
end
