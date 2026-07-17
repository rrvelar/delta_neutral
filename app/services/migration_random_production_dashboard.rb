class MigrationRandomProductionDashboard
  DEFAULT_TAIL_LINES = 300

  def initialize(position:, log_dir: MigrationRandomProductionRunner::LOG_DIR, preflight_factory: nil, runner_factory: nil)
    @position = position
    @log_dir = Pathname(log_dir)
    @preflight_factory = preflight_factory
    @runner_factory = runner_factory
  end

  def report(tail_lines: DEFAULT_TAIL_LINES, refresh_when_stale: true)
    status = read_json(status_path)
    @status_source = "runner status file (read-only)"
    # A stale stopped-runner status file must never override fresh authoritative
    # state: when the file is stale and no runner process is active, recompute
    # the live status (same service as migration:random_production_status) and
    # write it through to the file. Fail-closed: if the live refresh fails or is
    # not allowed here (fast polling endpoint), the stale file is kept but
    # clearly labeled so blockers read as historical.
    if status_file_stale?(status) && !runner_for_refresh.process_active?
      if refresh_when_stale
        refresh = runner_for_refresh.refresh_status_file!
        if refresh[:refreshed]
          status = read_json(status_path)
          @status_source = "live authoritative status (auto-refreshed; previous file was stale)"
        else
          @status_source = "runner status file (STALE — live refresh failed: #{refresh[:reason]}; blockers shown are historical, not current)"
        end
      else
        @status_source = "runner status file (STALE — reload the page or press Refresh Status for authoritative state; blockers shown are historical, not current)"
      end
    end
    heartbeat = read_json(heartbeat_path)
    lock = read_json(lock_path)
    control_request = read_json(control_path)
    control_result = read_json(control_result_path)
    latest_events = latest_jsonl_events(tail_lines)
    latest_event = latest_events.last
    # Authoritative current blockers come only from the live status payload the
    # runner writes each cycle. The JSONL latest_event is a previous-cycle
    # snapshot and must never be promoted to a current blocker.
    current_blockers = (Array(status["blockers"]) + Array(status["direct_preflight_blockers"]))
      .map { |blocker| blocker.to_s.strip }.reject(&:blank?).uniq
    historical_blocker = Array(latest_event&.fetch("blockers", nil)).first
    event_stale = latest_event_stale?(latest_event, status, heartbeat)
    current_venue = status["current_production_venue"] || active_venue_from_shorts(status) || heartbeat["current_production_venue"] || status.dig("latest_event", "final_production_venue") || latest_event&.fetch("final_production_venue", nil) || position.hedge&.execution_venue
    # The heartbeat is only current while the runner is actively running; once
    # stopped it is a historical snapshot from the last cycle. Showing its
    # target/combined/inside_tolerance leaks a stale target after a stop/repair
    # (e.g. 1.599863 while the position is freshly 1.465). When not running,
    # source fresh authoritative values and label them; never let the stale
    # heartbeat drive the current target or inside_tolerance display.
    runner_running = lock.present? && process_alive?(lock["pid"])
    if runner_running
      target_short = heartbeat["target_short_eth"]
      combined_short = heartbeat["combined_short_eth"]
      display_inside_tolerance = heartbeat.key?("inside_tolerance") ? heartbeat["inside_tolerance"] : status["inside_tolerance"]
      target_source = "last heartbeat (runner active)"
    else
      fresh = fresh_authoritative_target(status)
      target_short = fresh[:target_short_eth]
      combined_short = fresh[:combined_short_eth]
      display_inside_tolerance = status.key?("inside_tolerance") ? status["inside_tolerance"] : heartbeat["inside_tolerance"]
      target_source = fresh[:source]
    end

    {
      status: display_status(status: status, heartbeat: heartbeat, lock: lock),
      status_source: @status_source,
      current_direct_market_safe: status["current_direct_market_safe"],
      status_updated_at: status["updated_at"],
      heartbeat_started_at: heartbeat["started_at"],
      current_blockers: current_blockers,
      historical_blocker: historical_blocker,
      latest_event_stale: event_stale,
      mode: production_mode(heartbeat),
      policy_label: "3 migrations/day · interval #{MigrationRandomProductionRunner::DEFAULT_INTERVAL_SECONDS}s · hold check #{MigrationRandomProductionRunner::DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS}s",
      status_payload: status,
      heartbeat: heartbeat,
      lock: lock,
      lock_stale: lock.present? && !process_alive?(lock["pid"]),
      host_control_available: host_control_available?,
      host_control_mode: host_control_mode,
      control_request: control_request,
      control_result: control_result,
      bridge_status: bridge_status(control_request, control_result),
      latest_event: latest_event,
      tail_events: latest_events,
      current_production_venue: current_venue,
      active_venue_short_eth: active_venue_short(status, current_venue),
      target_short_eth: target_short,
      combined_short_eth: combined_short,
      drift_eth: drift_eth(target_short, combined_short),
      tolerance_eth: tolerance_eth(target_short),
      inside_tolerance: display_inside_tolerance,
      target_source: target_source,
      heartbeat_target_short_eth: heartbeat["target_short_eth"],
      direct_preflight_blockers: Array(status["direct_preflight_blockers"]),
      direct_open_orders: direct_open_orders(status),
      direct_venue_shorts: direct_venue_shorts(status),
      open_orders_zero: direct_open_orders_zero?(status),
      route_proofs_summary: route_proofs_summary(status),
      last_route: heartbeat["last_route"] || latest_event&.fetch("route", nil),
      last_cycle: heartbeat["last_cycle"] || latest_event&.fetch("cycle", nil),
      last_hold_check: heartbeat["last_hold_check_at"] || last_hold_check_from(latest_event),
      heartbeat_updated_at: heartbeat["updated_at"],
      next_target_venue: next_daily_coverage_target(current_venue),
      next_rotation_at: next_rotation_at(heartbeat),
      lock_pid: lock["pid"],
      gates_state: status["gates_state"] || gates_state,
      operational_warnings: operational_warnings,
      latest_blocker: historical_blocker,
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }
  rescue => e
    {
      status: "unknown",
      current_direct_market_safe: nil,
      status_updated_at: nil,
      heartbeat_started_at: nil,
      current_blockers: [ "#{e.class}: #{e.message}" ],
      historical_blocker: nil,
      latest_event_stale: false,
      mode: "unknown",
      policy_label: "3 migrations/day · interval #{MigrationRandomProductionRunner::DEFAULT_INTERVAL_SECONDS}s · hold check #{MigrationRandomProductionRunner::DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS}s",
      status_payload: {},
      heartbeat: {},
      lock: {},
      lock_stale: false,
      host_control_available: host_control_available?,
      host_control_mode: host_control_mode,
      control_request: read_json(control_path),
      control_result: read_json(control_result_path),
      bridge_status: "unknown",
      latest_event: nil,
      tail_events: [],
      current_production_venue: nil,
      active_venue_short_eth: nil,
      target_short_eth: nil,
      combined_short_eth: nil,
      drift_eth: nil,
      tolerance_eth: nil,
      inside_tolerance: nil,
      direct_preflight_blockers: [ "#{e.class}: #{e.message}" ],
      direct_open_orders: {},
      direct_venue_shorts: {},
      open_orders_zero: false,
      route_proofs_summary: {},
      last_route: nil,
      last_cycle: nil,
      last_hold_check: nil,
      heartbeat_updated_at: nil,
      next_target_venue: nil,
      next_rotation_at: nil,
      lock_pid: nil,
      gates_state: gates_state,
      latest_blocker: "#{e.class}: #{e.message}",
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }
  end

  private

  attr_reader :position, :log_dir, :preflight_factory

  # Fresh anomaly warnings, computed live (never from the status file, which can
  # be stale after a stop): Extended survivor with failed submit health or
  # quarantine, Extended auto DB override, recovery readback mismatch.
  def operational_warnings
    MigrationOperationalWarnings.for(position: position)
  rescue => e
    [ "operational warnings unavailable: #{e.class}: #{e.message}" ]
  end

  # The JSONL latest_event is a snapshot of a past cycle. It is "stale" (a
  # historical diagnostic, not current state) whenever the runner is not
  # actively running, or when the event predates the current run's start time.
  def latest_event_stale?(latest_event, status, heartbeat)
    return false if latest_event.blank?
    return true unless status["status"] == "running"

    started_at = parse_time(heartbeat["started_at"])
    event_at = parse_time(latest_event["timestamp"] || latest_event["recorded_at"])
    return false unless started_at && event_at

    event_at < started_at
  end

  def parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def display_status(status:, heartbeat:, lock:)
    return "stale lock" if lock.present? && !process_alive?(lock["pid"])
    return "unsafe_multiple_exposure" if status["status"] == "unsafe_multiple_exposure"
    return "orphan_process_running" if status["status"] == "orphan_process_running"
    return "unsafe_gates_left_enabled" if gates_enabled_payload?(status) && lock.blank?
    return "stale_heartbeat" if heartbeat["status"] == "running" && lock.blank?

    status["status"].presence || heartbeat["status"].presence || "unknown"
  end

  def host_control_available?
    MigrationRandomProductionControl.systemctl_available?
  end

  def host_control_mode
    host_control_available? ? "direct systemd" : "host bridge"
  end

  def bridge_status(request, result)
    return result["status"] == "failed" ? "failed" : "handled" if request.blank? && result.present?
    return "unknown" if request.blank?
    return "pending" if result.blank?
    return "pending" if result["request_id"].present? && result["request_id"] != request["request_id"]
    return "failed" if result["status"] == "failed"

    "handled"
  end

  def direct_open_orders(status)
    HedgeVenues::SUPPORTED_KEYS.to_h do |venue|
      details = status.dig("direct_open_orders", venue) || {}
      [ venue, { status: details["status"], count: details["count"] }.compact ]
    end
  end

  def direct_venue_shorts(status)
    HedgeVenues::SUPPORTED_KEYS.to_h { |venue| [ venue, status.dig("direct_venue_shorts", venue) ] }
  end

  def active_venue_from_shorts(status)
    shorts = status["direct_venue_shorts"]
    return nil unless shorts.is_a?(Hash)

    active = shorts.find { |_venue, value| decimal(value).positive? }
    active&.first
  end

  def direct_open_orders_zero?(status)
    return nil unless status.key?("direct_open_orders")

    HedgeVenues::SUPPORTED_KEYS.all? { |venue| status.dig("direct_open_orders", venue, "status") == "zero" }
  end

  def route_proofs_summary(status)
    proof = status["proof_report"] || status["route_proofs_summary"] || {}
    return { ready: nil, missing: nil, stale: nil, total: nil, missing_cache: true } if proof.blank?

    {
      ready: proof["ready"] || Array(proof["completed_route_proofs"]).size,
      missing: proof["missing"] || Array(proof["missing_route_proofs"]).size,
      stale: proof["stale"] || Array(proof["stale_route_proofs"]).size,
      total: proof["total"] || Array(proof["routes"]).size
    }
  end

  def production_mode(heartbeat)
    duration = heartbeat["duration_minutes"] || heartbeat.dig("config", "duration_minutes")
    return "24h canary" if duration.to_i == 1_440
    return "24/7 production" if duration.to_i.zero?

    duration.present? ? "#{duration} minute run" : "24/7 production"
  end

  def active_venue_short(status, venue)
    return nil if venue.blank?

    status.dig("direct_venue_shorts", venue.to_s)
  end

  def drift_eth(target_short, combined_short)
    return nil if target_short.blank? || combined_short.blank?

    decimal(target_short) - decimal(combined_short)
  end

  def tolerance_eth(target_short)
    return nil if target_short.blank? || position.hedge&.tolerance.blank?

    decimal(target_short) * decimal(position.hedge.tolerance)
  end

  def next_daily_coverage_target(current_venue)
    venues = %w[extended ethereal nado]
    current = HedgeVenues.normalize(current_venue)
    return nil unless venues.include?(current)

    venues[(venues.index(current) + 1) % venues.size]
  end

  def next_rotation_at(heartbeat)
    started_at = Time.zone.parse(heartbeat["started_at"].to_s)
    cycle = heartbeat["last_cycle"].to_i
    return nil unless started_at && cycle.positive?

    (started_at + (cycle * MigrationRandomProductionRunner::DEFAULT_INTERVAL_SECONDS).seconds).utc.iso8601
  rescue ArgumentError, TypeError
    nil
  end

  def dashboard_snapshot_diagnostic
    snapshot = position.position_dashboard_snapshot
    return {} unless snapshot

    {
      label: "dashboard_snapshot_diagnostic",
      refresh_status: snapshot.refresh_status,
      source_errors: snapshot.source_errors_hash,
      blockers: dashboard_snapshot_blockers(snapshot)
    }
  end

  def dashboard_snapshot_blockers(snapshot)
    blockers = []
    blockers << "critical Extended readback failed" if snapshot.extended_critical_read_status.to_s.present? && snapshot.extended_critical_read_status.to_s != "ok"
    blockers << "open orders cannot be confirmed zero" if snapshot.open_orders_count_extended.nil?
    blockers.concat(snapshot.source_errors_hash.values.map { |value| dashboard_snapshot_diagnostic_message(value) })
    blockers.compact.uniq
  end

  def dashboard_snapshot_diagnostic_message(value)
    text = value.to_s
    return "dashboard snapshot readback timed out" if text.match?(/Timeout/i)

    text
  end

  def last_hold_check_from(event)
    Array(event&.fetch("hold_rebalance_checks", nil)).filter_map { |check| check["checked_at"] }.last
  end

  def latest_jsonl_events(lines)
    BoundedJsonlTail.read(latest_path, lines: lines)
  end

  def read_json(path)
    return {} unless File.exist?(path)

    JSON.parse(File.read(path))
  rescue JSON::ParserError, SystemCallError
    {}
  end

  def process_alive?(value)
    pid = value.to_i
    return false unless pid.positive?

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  end

  def gates_state
    MigrationRandomProductionRunner::MIGRATION_GATE_KEYS.to_h { |key| [ key, OperationalSettings.enabled?(key) ] }
  end

  def gates_enabled_payload?(status)
    payload = status["gates_state"]
    return false unless payload.is_a?(Hash)

    payload.values.any? { |enabled| ActiveModel::Type::Boolean.new.cast(enabled) }
  end

  # Fresh authoritative target/combined for display when the runner is stopped.
  # Prefers the position dashboard snapshot (target = LP asset0) when it is
  # fresh; otherwise falls back to the current combined short from the status
  # file with no target. Never returns the stale heartbeat target.
  def fresh_authoritative_target(status)
    snap = position.position_dashboard_snapshot
    if snap&.refreshed_at && (Time.current - snap.refreshed_at) <= MigrationRandomProductionRunner::HEARTBEAT_STALE_AFTER_SECONDS && snap.target_short_eth.present?
      return {
        target_short_eth: snap.target_short_eth.to_s,
        combined_short_eth: (snap.combined_short_eth.presence || combined_short_from_status(status)).to_s,
        source: "live position snapshot (runner stopped)"
      }
    end
    { target_short_eth: nil, combined_short_eth: combined_short_from_status(status), source: "authoritative status; fresh target unavailable (runner stopped)" }
  rescue StandardError
    { target_short_eth: nil, combined_short_eth: combined_short_from_status(status), source: "authoritative status (runner stopped)" }
  end

  def combined_short_from_status(status)
    shorts = status["direct_venue_shorts"]
    return nil unless shorts.is_a?(Hash)

    shorts.values.sum { |v| BigDecimal(v.to_s) rescue BigDecimal(0) }.to_s("F")
  rescue StandardError
    nil
  end

  def runner_for_refresh
    @runner_for_refresh ||= if @runner_factory
      @runner_factory.call(position: position)
    else
      MigrationRandomProductionRunner.new(position: position, trap_signals: false)
    end
  end

  # Only a real stale artifact triggers the live auto-refresh: a status file
  # that exists with a parseable updated_at older than the heartbeat staleness
  # window. Missing/never-written files (runner never ran) stay as-is - the
  # freshness line already reports "not written yet" honestly.
  def status_file_stale?(status)
    return false if status.blank?

    at = Time.zone.parse(status["updated_at"].to_s)
    return false if at.nil?

    (Time.current - at) > MigrationRandomProductionRunner::HEARTBEAT_STALE_AFTER_SECONDS
  rescue ArgumentError, TypeError
    false
  end

  def status_path
    log_dir.join("status_position_#{position.id}.json")
  end

  def heartbeat_path
    log_dir.join("heartbeat_position_#{position.id}.json")
  end

  def lock_path
    log_dir.join("lock_position_#{position.id}.json")
  end

  def latest_path
    log_dir.join("latest_position_#{position.id}.jsonl")
  end

  def control_path
    log_dir.join("control_position_#{position.id}.json")
  end

  def control_result_path
    log_dir.join("control_result_position_#{position.id}.json")
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
