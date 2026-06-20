class MigrationRandomProductionRunner
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_PRODUCTION_RANDOM_ROTATION".freeze
  LOG_DIR = Rails.root.join("storage/random_rotation_production")
  DEFAULT_INTERVAL_SECONDS = 28_800
  DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS = 300
  HEARTBEAT_STALE_AFTER_SECONDS = 600
  ACTIVE_RUNNERS = %w[
    random_production_runner
    random_burn_in
    daily_random_runner
    manual_live_canary
  ].freeze
  MIGRATION_GATE_KEYS = %w[
    MIGRATION_LIVE_ENABLED
    MIGRATION_AUTO_ENABLED
    MIGRATION_RANDOM_ROTATION_LIVE_ENABLED
  ].freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt_path, :summary)

  def initialize(position:, live: true, confirmation: nil, duration_minutes: 0, interval_seconds: DEFAULT_INTERVAL_SECONDS,
                 rebalance_hold_interval_seconds: DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS, rebalance_after_migration: true,
                 rebalance_during_hold: true, rebalance_before_next_migration: true,
                 rebalance_only_if_outside_tolerance: true, rebalance_readback_recheck_attempts: 4,
                 rebalance_readback_recheck_interval_seconds: 5, max_cycles: nil,
                 log_dir: LOG_DIR, now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) },
                 runner_factory: nil, preflight_factory: nil, pid: Process.pid, trap_signals: true,
                 env: ENV)
    @position = position
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @confirmation = confirmation.to_s
    @duration_minutes = duration_minutes.to_i
    @interval_seconds = interval_seconds.to_i
    @rebalance_hold_interval_seconds = rebalance_hold_interval_seconds.to_i
    @rebalance_after_migration = ActiveModel::Type::Boolean.new.cast(rebalance_after_migration)
    @rebalance_during_hold = ActiveModel::Type::Boolean.new.cast(rebalance_during_hold)
    @rebalance_before_next_migration = ActiveModel::Type::Boolean.new.cast(rebalance_before_next_migration)
    @rebalance_only_if_outside_tolerance = ActiveModel::Type::Boolean.new.cast(rebalance_only_if_outside_tolerance)
    @rebalance_readback_recheck_attempts = rebalance_readback_recheck_attempts.to_i
    @rebalance_readback_recheck_interval_seconds = rebalance_readback_recheck_interval_seconds.to_i
    @max_cycles = max_cycles&.to_i
    @log_dir = Pathname(log_dir)
    @now = now
    @sleeper = sleeper
    @runner_factory = runner_factory
    @preflight_factory = preflight_factory
    @pid = pid
    @trap_signals = trap_signals
    @env = env
    @started_at = @now.call
    @last_cycle = nil
    @last_route = nil
    @last_hold_check_at = nil
    @latest_event = nil
  end

  def run
    prepare_files!
    clear_stale_stop_request!
    blockers = start_blockers
    if blockers.any?
      write_status(status: "blocked", blockers: blockers)
      return result("blocked", blockers)
    end

    install_signal_traps if trap_signals
    write_lock!(runner: "random_production_runner")
    write_heartbeat(status: "running")
    burn_in_result = nil
    begin
      if stop_requested?
        write_status(status: "stopped", blockers: [ "stop requested" ])
        return result("stopped", [ "stop requested" ])
      end
      burn_in_result = build_burn_in_runner.run
      write_status(status: burn_in_result.status, blockers: burn_in_result.blockers, summary: burn_in_result.summary)
      result(burn_in_result.status, burn_in_result.blockers, burn_in_result.summary)
    ensure
      disable_runtime_gates
      write_final_event(status: burn_in_result&.status || "stopped")
      write_heartbeat(status: burn_in_result&.status || "stopped", pid_value: nil)
      clear_lock!
      write_status(status: burn_in_result&.status || "stopped", blockers: burn_in_result&.blockers || [ "stop requested" ], summary: burn_in_result&.summary)
    end
  rescue SignalException => e
    disable_runtime_gates
    clear_lock!
    write_heartbeat(status: "stopped", pid_value: nil)
    write_status(status: "stopped", blockers: [ "#{e.class}: #{e.message}" ])
    result("stopped", [ "#{e.class}: #{e.message}" ])
  rescue => e
    disable_runtime_gates
    clear_lock!
    write_heartbeat(status: "failed", pid_value: nil)
    write_status(status: "failed", blockers: [ "#{e.class}: #{e.message}" ])
    result("failed", [ "#{e.class}: #{e.message}" ])
  end

  def status
    direct = direct_report
    direct_open_orders_payload = direct_open_orders(direct)
    direct_venue_shorts_payload = direct_venue_shorts(direct)
    confirmed_active = confirmed_active_short_venues(direct)
    unknown_venues = unknown_short_venues(direct)
    process_running = lock_running?
    orphan_process = duplicate_runner_process_running?(ignore_pid: lock_payload["pid"])
    stale_lock = lock_stale?
    heartbeat_recent = heartbeat_recent?
    stale_heartbeat = heartbeat_payload["status"] == "running" && (!process_running || !heartbeat_recent) && !orphan_process
    running_healthy = process_running && heartbeat_payload["status"] == "running" && heartbeat_recent
    latest = latest_event_from_log
    current_market_safe = current_direct_market_safe?(direct, confirmed_active, unknown_venues)
    effective_status = production_status(
      direct: direct,
      confirmed_active: confirmed_active,
      unknown_venues: unknown_venues,
      running_healthy: running_healthy,
      process_running: process_running,
      orphan_process: orphan_process,
      stale_lock: stale_lock,
      stale_heartbeat: stale_heartbeat,
      heartbeat_recent: heartbeat_recent,
      latest: latest
    )
    {
      runner: "random_production_runner",
      position_id: position.id,
      status: effective_status,
      historical_stop_reason: historical_stop_reason(latest),
      current_direct_market_safe: current_market_safe,
      pid: lock_payload["pid"],
      lock: lock_payload.presence,
      lock_stale: stale_lock,
      latest_event: latest,
      last_heartbeat: heartbeat_payload.presence,
      current_production_venue: direct[:production_venue] || heartbeat_payload["current_production_venue"],
      direct_open_orders: direct_open_orders_payload,
      direct_venue_shorts: direct_venue_shorts_payload,
      active_short_venues: confirmed_active,
      unconfirmed_venue_readbacks: unknown_venues,
      inside_tolerance: direct[:inside_tolerance] == true,
      last_route: heartbeat_payload["last_route"],
      last_cycle: heartbeat_payload["last_cycle"],
      last_hold_check: heartbeat_payload["last_hold_check_at"],
      gates_state: gates_state,
      duplicate_runner_process: orphan_process,
      stale_heartbeat: stale_heartbeat,
      blockers: status_blockers(effective_status, direct, confirmed_active, unknown_venues),
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }
  end

  def stop!
    prepare_files!
    payload = {
      runner: "random_production_runner",
      position_id: position.id,
      requested_at: now.call.utc.iso8601,
      pid: pid,
      status: "stop_requested"
    }
    File.write(stop_path, JSON.pretty_generate(payload))
    payload
  end

  private

  attr_reader :position, :confirmation, :duration_minutes, :interval_seconds,
    :rebalance_hold_interval_seconds, :rebalance_after_migration, :rebalance_during_hold,
    :rebalance_before_next_migration, :rebalance_only_if_outside_tolerance,
    :rebalance_readback_recheck_attempts, :rebalance_readback_recheck_interval_seconds,
    :max_cycles, :log_dir, :now, :sleeper, :runner_factory, :preflight_factory,
    :pid, :trap_signals, :env, :started_at
  attr_accessor :last_cycle, :last_route, :last_hold_check_at, :latest_event

  def live?
    @live
  end

  def prepare_files!
    FileUtils.mkdir_p(log_dir)
  end

  def clear_stale_stop_request!
    FileUtils.rm_f(stop_path)
  end

  def start_blockers
    blockers = []
    blockers << "confirmation must equal #{CONFIRMATION}" if live? && confirmation != CONFIRMATION
    blockers << "duplicate_runner_process" if duplicate_runner_process_running?
    blockers.concat(active_lock_blockers)
    blockers.concat(restart_safety_blockers)
    blockers.uniq
  end

  def active_lock_blockers
    payload = lock_payload
    return [] if payload.blank?
    return [] if lock_stale? && restart_safety_blockers.empty?

    runner = payload["runner"].presence || "unknown"
    return [] unless ACTIVE_RUNNERS.include?(runner)

    [ "#{runner} already running for position #{position.id} with pid #{payload['pid']}" ]
  end

  def restart_safety_blockers
    report = direct_report
    confirmed = confirmed_active_short_venues(report)
    unknown = unknown_short_venues(report)
    blockers = []
    blockers << "direct preflight open orders are nonzero or unknown" unless direct_open_orders_zero?(report)
    blockers << "direct preflight venue readback could not be confirmed for #{unknown.join(', ')}; fail closed" if unknown.any?
    blockers << multiple_exposure_blocker(report) if confirmed.size > 1
    blockers << "direct preflight must show exactly one active venue exposure" if confirmed.empty? && unknown.empty?
    blockers << active_venue_mismatch_blocker if confirmed.one? && confirmed.first != production_venue(report)
    unless report[:inside_tolerance] == true || Array(report[:blockers]).all? { |blocker| rebalance_trigger_blocker?(blocker) }
      blockers.concat(Array(report[:blockers]))
    end
    blockers.uniq
  end

  def active_venue_mismatch_blocker
    "active venue differs from production venue; use supervised adopt/sync production venue"
  end

  def production_venue(report)
    HedgeVenues.normalize(report[:production_venue] || position.hedge&.execution_venue)
  end

  def build_burn_in_runner
    return runner_factory.call(event_callback: method(:record_event), stop_requested: method(:stop_requested?)) if runner_factory

    MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: duration_minutes,
      interval_seconds: interval_seconds,
      max_cycles: configured_max_cycles,
      live: live?,
      disable_after: true,
      confirmation: MigrationRandomBurnInRunner::CONFIRMATION,
      log_dir: log_dir,
      env: env,
      sleeper: sleeper,
      now: now,
      rebalance_after_migration: rebalance_after_migration,
      rebalance_during_hold: rebalance_during_hold,
      rebalance_hold_interval_seconds: rebalance_hold_interval_seconds,
      rebalance_before_next_migration: rebalance_before_next_migration,
      rebalance_only_if_outside_tolerance: rebalance_only_if_outside_tolerance,
      rebalance_readback_recheck_attempts: rebalance_readback_recheck_attempts,
      rebalance_readback_recheck_interval_seconds: rebalance_readback_recheck_interval_seconds,
      event_callback: method(:record_event),
      stop_requested: method(:stop_requested?)
    )
  end

  def configured_max_cycles
    return max_cycles if max_cycles&.positive?

    return 1_000_000 unless duration_minutes.positive? && interval_seconds.positive?

    [ (duration_minutes.minutes / interval_seconds).ceil + 1, 1 ].max
  end

  def record_event(event)
    self.latest_event = event
    self.last_cycle = event[:cycle] || event["cycle"] || last_cycle
    route = event[:route] || event["route"]
    self.last_route = route if route.present?
    hold_checks = event[:hold_rebalance_checks] || event["hold_rebalance_checks"] || []
    hold_check_at = hold_checks.filter_map { |check| check[:checked_at] || check["checked_at"] }.last
    hold_check_at ||= event[:checked_at] || event["checked_at"] if (event[:event] || event["event"]) == "hold_check"
    self.last_hold_check_at = hold_check_at if hold_check_at.present?
    write_heartbeat(status: "running")
    write_status(status: "running")
  end

  def write_heartbeat(status:, pid_value: pid)
    report = direct_report
    payload = {
      runner: "random_production_runner",
      position_id: position.id,
      pid: pid_value,
      started_at: started_at.utc.iso8601,
      updated_at: now.call.utc.iso8601,
      last_cycle: last_cycle,
      last_route: last_route,
      current_production_venue: report[:production_venue],
      target_short_eth: decimal_string(report.dig(:target, :target_short_eth)),
      combined_short_eth: decimal_string(report[:combined_short_eth]),
      inside_tolerance: report[:inside_tolerance] == true,
      open_orders_zero: direct_open_orders_zero?(report),
      gates_enabled: gates_enabled?,
      last_hold_check_at: last_hold_check_at,
      status: status
    }
    File.write(heartbeat_path, JSON.pretty_generate(payload))
  end

  def write_status(status:, blockers: [], summary: nil)
    direct = direct_report
    payload = {
      runner: "random_production_runner",
      position_id: position.id,
      pid: pid,
      updated_at: now.call.utc.iso8601,
      status: status,
      historical_stop_reason: historical_stop_reason(latest_event || latest_event_from_log),
      current_direct_market_safe: current_direct_market_safe?(direct, confirmed_active_short_venues(direct), unknown_short_venues(direct)),
      blockers: blockers,
      lock: lock_payload.presence,
      lock_stale: lock_stale?,
      latest_event: latest_event || latest_event_from_log,
      heartbeat: heartbeat_payload.presence,
      summary: summary,
      direct_preflight_blockers: Array(direct[:blockers]),
      current_production_venue: direct[:production_venue],
      direct_open_orders: direct_open_orders(direct),
      direct_venue_shorts: direct_venue_shorts(direct),
      inside_tolerance: direct[:inside_tolerance] == true,
      proof_report: proof_report_payload(direct[:proof_report]),
      route_proofs_summary: route_proofs_summary(direct[:proof_report]),
      gates_state: gates_state,
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }.compact
    File.write(status_path, JSON.pretty_generate(payload))
  end

  def write_lock!(runner:)
    payload = {
      runner: runner,
      position_id: position.id,
      pid: pid,
      started_at: started_at.utc.iso8601,
      updated_at: now.call.utc.iso8601
    }
    File.write(lock_path, JSON.pretty_generate(payload))
  end

  def clear_lock!
    FileUtils.rm_f(lock_path)
  end

  def write_final_event(status:)
    path = latest_path
    event = {
      event: "random_production_runner_finished",
      status: status,
      position_id: position.id,
      timestamp: now.call.utc.iso8601,
      migration_live_enabled_final: OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED", env: env),
      migration_auto_enabled_final: OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED", env: env),
      migration_random_rotation_live_enabled_final: OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", env: env)
    }
    File.open(path, "a") { |file| file.puts(JSON.generate(event)) }
  end

  def install_signal_traps
    %w[TERM INT].each do |signal|
      Signal.trap(signal) do
        stop!
        raise SignalException, signal
      end
    end
  rescue ArgumentError
    nil
  end

  def stop_requested?
    File.exist?(stop_path)
  end

  def disable_runtime_gates
    return unless live?

    MIGRATION_GATE_KEYS.each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "random production runner exit")
    end
  end

  def direct_report
    @direct_report = nil if latest_event
    @direct_report ||= if preflight_factory
      preflight_factory.call(position: position, stage: "random_production_runner")
    else
      MigrationRandomBurnInPreflight.new(position: position, env: env).report
    end
  end

  # Only venues whose short came from a fresh, confirmed direct readback count as live
  # exposure. A venue read that failed, is unknown, or was carried forward from a stale
  # snapshot must not be treated as live exposure (it would fabricate multiple exposure).
  def confirmed_active_short_venues(report)
    HedgeVenues::SUPPORTED_KEYS.select do |venue|
      !venue_readback_unknown?(report, venue) && decimal(report.dig(:venues, venue, :short_eth)).positive?
    end
  end

  def unknown_short_venues(report)
    HedgeVenues::SUPPORTED_KEYS.select { |venue| venue_readback_unknown?(report, venue) }
  end

  def venue_readback_unknown?(report, venue)
    details = report.dig(:venues, venue) || {}
    position_status = details[:position_status] || details["position_status"]
    return true unless position_status.nil? || position_status.to_s == "ok"
    return true if (details[:short_eth] || details["short_eth"]).nil?

    stale_venue_source?(details)
  end

  def stale_venue_source?(details)
    source_status = (details[:source_status] || details["source_status"]).to_s
    critical_status = (details[:critical_read_status] || details["critical_read_status"]).to_s
    source_status == "stale" || critical_status == "error_carried_forward"
  end

  def multiple_exposure_blocker(report)
    venues = confirmed_active_short_venues(report).map do |venue|
      "#{venue}=#{decimal_string(report.dig(:venues, venue, :short_eth))}"
    end
    "unsafe_multiple_exposure: #{venues.join(', ')}"
  end

  def direct_open_orders_zero?(report)
    HedgeVenues::SUPPORTED_KEYS.all? { |venue| report.dig(:venues, venue, :open_orders_status) == "zero" }
  end

  def direct_open_orders(report)
    HedgeVenues::SUPPORTED_KEYS.to_h do |venue|
      details = report.dig(:venues, venue) || {}
      [ venue, { status: details[:open_orders_status], count: details[:open_orders_count] }.compact ]
    end
  end

  def direct_venue_shorts(report)
    HedgeVenues::SUPPORTED_KEYS.to_h do |venue|
      value = venue_readback_unknown?(report, venue) ? "unknown" : decimal_string(report.dig(:venues, venue, :short_eth))
      [ venue, value ]
    end
  end

  def proof_report_payload(proof_report)
    return nil unless proof_report

    {
      routes: Array(proof_report[:routes]),
      completed_route_proofs: Array(proof_report[:completed_route_proofs]),
      missing_route_proofs: Array(proof_report[:missing_route_proofs]),
      stale_route_proofs: Array(proof_report[:stale_route_proofs])
    }
  end

  def route_proofs_summary(proof_report)
    return nil unless proof_report

    routes = Array(proof_report[:routes])
    completed = Array(proof_report[:completed_route_proofs])
    missing = Array(proof_report[:missing_route_proofs])
    stale = Array(proof_report[:stale_route_proofs])
    {
      ready: completed.size,
      missing: missing.size,
      stale: stale.size,
      total: routes.size
    }
  end

  def dashboard_snapshot_diagnostic
    snapshot = position.position_dashboard_snapshot
    return nil unless snapshot

    {
      label: "dashboard_snapshot_diagnostic",
      refresh_status: snapshot.refresh_status,
      source_errors: snapshot.source_errors_hash,
      accepted_for_execution: restart_safety_blockers.empty?
    }
  end

  def rebalance_trigger_blocker?(blocker)
    blocker.to_s.match?(ActiveVenueOneShotRebalance::REBALANCE_TRIGGER_BLOCKER_PATTERN)
  end

  def gates_enabled?
    MIGRATION_GATE_KEYS.all? { |key| OperationalSettings.enabled?(key, env: env) }
  end

  def gates_state
    MIGRATION_GATE_KEYS.to_h { |key| [ key, OperationalSettings.enabled?(key, env: env) ] }
  end

  def lock_running?
    payload = lock_payload
    payload.present? && process_alive?(payload["pid"])
  end

  def lock_stale?
    payload = lock_payload
    payload.present? && !process_alive?(payload["pid"])
  end

  def production_status(direct:, confirmed_active:, unknown_venues:, running_healthy:, process_running:, orphan_process:, stale_lock:, stale_heartbeat:, heartbeat_recent:, latest:)
    return "unsafe_multiple_exposure" if confirmed_active.size > 1
    return "orphan_process_running" if orphan_process
    return "running" if running_healthy
    return "unsafe_unknown_exposure" if unknown_venues.any?
    return "active_venue_mismatch" if confirmed_active.one? && confirmed_active.first != production_venue(direct)
    return "unsafe_gates_left_enabled" if gates_state.values.any? && !process_running
    return "stale_lock" if stale_lock
    return "stale_heartbeat" if stale_heartbeat
    return "stopped" if latest&.fetch("status", nil) == "stopped"
    return "success" if latest&.fetch("status", nil) == "success"
    return "blocked" if Array(direct[:blockers]).any?

    status_payload["status"].presence || "stopped"
  end

  def current_direct_market_safe?(direct, confirmed_active, unknown_venues)
    direct_open_orders_zero?(direct) &&
      unknown_venues.empty? &&
      confirmed_active.one? &&
      confirmed_active.first == production_venue(direct) &&
      direct[:inside_tolerance] == true &&
      Array(direct[:blockers]).empty?
  end

  def historical_stop_reason(latest)
    latest&.fetch("blocker_status", nil) ||
      latest&.fetch("status", nil) ||
      status_payload["status"]
  end

  def heartbeat_recent?
    timestamp = Time.zone.parse(heartbeat_payload["updated_at"].to_s)
    timestamp && (now.call - timestamp) <= HEARTBEAT_STALE_AFTER_SECONDS
  rescue ArgumentError, TypeError
    false
  end

  def status_blockers(status, direct, confirmed_active, unknown_venues)
    case status
    when "unsafe_multiple_exposure"
      [ multiple_exposure_blocker(direct) ]
    when "unsafe_unknown_exposure"
      [ "venue readback could not be confirmed for #{unknown_venues.join(', ')}; failing closed (stale snapshot is diagnostic only)" ]
    when "active_venue_mismatch"
      [ active_venue_mismatch_blocker ]
    when "orphan_process_running"
      [ "runner process exists but lock is missing" ]
    when "unsafe_gates_left_enabled"
      [ "migration gates are enabled but no runner process is alive" ]
    when "stale_lock"
      [ "lock points to a dead process" ]
    when "stale_heartbeat"
      [ "heartbeat says running but process/lock are absent" ]
    else
      Array(direct[:blockers])
    end
  end

  def duplicate_runner_process_running?(ignore_pid: nil)
    runner_process_lines(ignore_pid: ignore_pid).any?
  end

  def runner_process_lines(ignore_pid: nil)
    output = `ps -eo pid=,command= 2>/dev/null`
    output.lines.select do |line|
      current_pid, command = line.strip.split(/\s+/, 2)
      current_pid.to_i != Process.pid &&
        current_pid.to_i != ignore_pid.to_i &&
        command.to_s.match?(/migration:(random_production_runner|random_burn_in|random_rotation_daily_runner)/)
    end
  rescue
    []
  end

  def process_alive?(value)
    process_pid = value.to_i
    return false unless process_pid.positive?

    Process.kill(0, process_pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def lock_payload
    read_json(lock_path)
  end

  def heartbeat_payload
    read_json(heartbeat_path)
  end

  def status_payload
    read_json(status_path)
  end

  def latest_event_from_log
    BoundedJsonlTail.read(latest_path, lines: 20).reverse.find(&:present?)
  end

  def read_json(path)
    return {} unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError
    {}
  end

  def result(status, blockers, summary = nil)
    Result.new(status, blockers, [], latest_path.to_s, summary || status_payload.symbolize_keys)
  end

  def latest_path
    log_dir.join("latest_position_#{position.id}.jsonl")
  end

  def heartbeat_path
    log_dir.join("heartbeat_position_#{position.id}.json")
  end

  def status_path
    log_dir.join("status_position_#{position.id}.json")
  end

  def lock_path
    log_dir.join("lock_position_#{position.id}.json")
  end

  def stop_path
    log_dir.join("stop_position_#{position.id}.json")
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_string(value)
    value.nil? ? nil : decimal(value).to_s("F")
  end
end
