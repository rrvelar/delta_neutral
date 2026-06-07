class MigrationPendingNadoContinuationClassifier
  VENUES = %w[extended ethereal nado].freeze
  FLAT_EPSILON = BigDecimal("0.001")

  def initialize(position:, proof_registry:, proof_report:, direct_report:, canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR)
    @position = position
    @proof_registry = proof_registry
    @proof_report = proof_report
    @direct_report = direct_report
    @canary_dir = Pathname(canary_dir)
  end

  def report
    event = latest_pending_event
    return empty_report unless event

    pending = pending_payload(event)
    classification = classify(event)
    blocking = classification == "real_unresolved_exchange_risk"
    {
      pending_nado_target_continuation: blocking ? pending : nil,
      pending_nado_target_continuation_blocking: blocking,
      stale_pending_continuation_ignored: !blocking,
      pending_continuation_classification: classification,
      pending_continuation_diagnostics: diagnostics(event)
    }
  end

  private

  attr_reader :position, :proof_registry, :proof_report, :direct_report, :canary_dir

  def empty_report
    {
      pending_nado_target_continuation: nil,
      pending_nado_target_continuation_blocking: false,
      stale_pending_continuation_ignored: false,
      pending_continuation_classification: "none",
      pending_continuation_diagnostics: {}
    }
  end

  def classify(event)
    return "stale_artifact" if proof_registry.resolved_nado_target_continuation?(position: position, pending_event: event)
    return "stale_artifact" if current_direct_state_safe_for?(event)

    "real_unresolved_exchange_risk"
  end

  def current_direct_state_safe_for?(event)
    route_ready_or_finalized?(event) &&
      production_venue_finalized? &&
      exactly_one_active_short? &&
      active_short_venues.first == current_production_venue &&
      other_venues_flat? &&
      direct_open_orders_zero? &&
      direct_report[:inside_tolerance] == true &&
      event["manual_action_required"] != true
  end

  def route_ready_or_finalized?(event)
    route = route_for(event)
    return false unless route
    return true if route[:status] == MigrationRouteProofRegistry::STATUSES[:ready]

    summary = route[:final_readback_summary] || {}
    route[:status] == MigrationRouteProofRegistry::STATUSES[:not_safe_latency] &&
      summary[:source_flat_after] == true &&
      summary[:target_holds_expected_short] == true &&
      summary[:final_inside_tolerance] == true
  end

  def production_venue_finalized?
    current_production_venue.present? && VENUES.include?(current_production_venue)
  end

  def exactly_one_active_short?
    active_short_venues.one?
  end

  def other_venues_flat?
    (VENUES - [ current_production_venue ]).all? do |venue|
      short = direct_report.dig(:venues, venue, :short_eth)
      short && short <= FLAT_EPSILON
    end
  end

  def direct_open_orders_zero?
    VENUES.all? do |venue|
      direct_report.dig(:venues, venue, :open_orders_status) == "zero"
    end
  end

  def active_short_venues
    @active_short_venues ||= VENUES.select do |venue|
      short = direct_report.dig(:venues, venue, :short_eth)
      short && short > FLAT_EPSILON
    end
  end

  def current_production_venue
    @current_production_venue ||= HedgeVenues.known_key(direct_report[:production_venue] || position.hedge&.execution_venue)
  end

  def route_for(event)
    proof_report.fetch(:routes).find do |entry|
      entry[:from_venue] == event["from_venue"] && entry[:to_venue] == event["to_venue"]
    end
  end

  def latest_pending_event
    pending_events.max_by { |event| event_time(event) || Time.zone.at(0) }
  end

  def pending_events
    Dir.glob(canary_dir.join("*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map do |line|
        JSON.parse(line).merge("receipt_path" => path)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end.select { |event| pending_nado_target_event?(event) }
  end

  def pending_nado_target_event?(event)
    event["position_id"].to_s == position.id.to_s &&
      event["to_venue"] == "nado" &&
      event["final_status"].to_s == "TARGET_ACCEPTED_AWAITING_CONTINUATION" &&
      event["continuation_pending"] == true
  end

  def pending_payload(event)
    {
      route: "#{event['from_venue']}->#{event['to_venue']}",
      from_venue: event["from_venue"],
      to_venue: event["to_venue"],
      pending_migration_id: event["pending_migration_id"],
      nado_target_digest: event["nado_target_digest"] || Array(event["exchange_order_ids"]).first,
      status: event["final_status"],
      continuation_command: event["continuation_command"] || "bin/rails migration:continue_target_first_after_nado_confirmed position_id=#{position.id} from=#{event['from_venue']} to=#{event['to_venue']} dry_run=true",
      receipt_path: event["receipt_path"]
    }
  end

  def diagnostics(event)
    {
      route: "#{event['from_venue']}->#{event['to_venue']}",
      route_status: route_for(event)&.fetch(:status, nil),
      active_short_venues: active_short_venues,
      production_venue: current_production_venue,
      open_orders_zero: direct_open_orders_zero?,
      inside_tolerance: direct_report[:inside_tolerance],
      direct_blockers: Array(direct_report[:blockers])
    }
  end

  def event_time(event)
    Time.zone.parse(event["timestamp"].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
