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
    blockers = Array(status["blockers"]).presence || Array(latest_event&.fetch("blockers", nil))

    {
      status: display_status(status: status, heartbeat: heartbeat, lock: lock),
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
      current_production_venue: heartbeat["current_production_venue"] || status.dig("latest_event", "final_production_venue") || latest_event&.fetch("final_production_venue", nil) || position.hedge&.execution_venue,
      target_short_eth: heartbeat["target_short_eth"],
      combined_short_eth: heartbeat["combined_short_eth"],
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
      lock_pid: lock["pid"],
      gates_state: status["gates_state"] || gates_state,
      latest_blocker: blockers.first,
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }
  rescue => e
    {
      status: "unknown",
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
      target_short_eth: nil,
      combined_short_eth: nil,
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
      lock_pid: nil,
      gates_state: gates_state,
      latest_blocker: "#{e.class}: #{e.message}",
      dashboard_snapshot_diagnostic: dashboard_snapshot_diagnostic
    }
  end

  private

  attr_reader :position, :log_dir, :preflight_factory

  def display_status(status:, heartbeat:, lock:)
    return "stale lock" if lock.present? && !process_alive?(lock["pid"])

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

  def direct_open_orders_zero?(status)
    return nil unless status.key?("direct_open_orders")

    HedgeVenues::SUPPORTED_KEYS.all? { |venue| status.dig("direct_open_orders", venue, "status") == "zero" }
  end

  def route_proofs_summary(status)
    proof = status["proof_report"] || status["route_proofs_summary"] || {}
    {
      ready: proof["ready"] || Array(proof["completed_route_proofs"]).size,
      missing: proof["missing"] || Array(proof["missing_route_proofs"]).size,
      stale: proof["stale"] || Array(proof["stale_route_proofs"]).size,
      total: proof["total"] || Array(proof["routes"]).size
    }
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
