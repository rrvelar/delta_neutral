class MigrationRandomProductionDashboard
  DEFAULT_TAIL_LINES = 300

  def initialize(position:, log_dir: MigrationRandomProductionRunner::LOG_DIR, preflight_factory: nil)
    @position = position
    @log_dir = Pathname(log_dir)
    @preflight_factory = preflight_factory
  end

  def report(tail_lines: DEFAULT_TAIL_LINES)
    status = read_json(status_path)
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
    target_short = heartbeat["target_short_eth"]
    combined_short = heartbeat["combined_short_eth"]

    {
      status: display_status(status: status, heartbeat: heartbeat, lock: lock),
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
      inside_tolerance: heartbeat.key?("inside_tolerance") ? heartbeat["inside_tolerance"] : status["inside_tolerance"],
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
