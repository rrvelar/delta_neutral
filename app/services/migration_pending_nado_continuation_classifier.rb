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
    return "stale_artifact" if registry_resolved?(event)
    return "stale_artifact" if current_direct_state_safe_for?(event)

    "real_unresolved_exchange_risk"
  end

  def registry_resolved?(event)
    return false unless proof_registry.respond_to?(:resolved_nado_target_continuation?)

    proof_registry.resolved_nado_target_continuation?(position: position, pending_event: event)
  end

  def current_direct_state_safe_for?(event)
    route_ready_or_finalized?(event) &&
      production_venue_finalized? &&
      exactly_one_active_short? &&
      active_short_venues.first == current_production_venue &&
      other_venues_flat? &&
      direct_open_orders_zero? &&
      truthy?(report_value(:inside_tolerance)) &&
      event["manual_action_required"] != true
  end

  def route_ready_or_finalized?(event)
    route = route_for(event)
    return false unless route
    return true if route_value(route, :status) == MigrationRouteProofRegistry::STATUSES[:ready]

    summary = route_value(route, :final_readback_summary) || {}
    route_value(route, :status) == MigrationRouteProofRegistry::STATUSES[:not_safe_latency] &&
      truthy?(hash_value(summary, :source_flat_after)) &&
      truthy?(hash_value(summary, :target_holds_expected_short)) &&
      truthy?(hash_value(summary, :final_inside_tolerance))
  end

  def production_venue_finalized?
    current_production_venue.present? && VENUES.include?(current_production_venue)
  end

  def exactly_one_active_short?
    active_short_venues.one?
  end

  def other_venues_flat?
    (VENUES - [ current_production_venue ]).all? do |venue|
      short = venue_short(venue)
      short && short <= FLAT_EPSILON
    end
  end

  def direct_open_orders_zero?
    VENUES.all? do |venue|
      open_order_status(venue) == "zero"
    end
  end

  def active_short_venues
    @active_short_venues ||= VENUES.select do |venue|
      short = venue_short(venue)
      short && short > FLAT_EPSILON
    end
  end

  def current_production_venue
    @current_production_venue ||= HedgeVenues.known_key(report_value(:production_venue) || position.hedge&.execution_venue)
  end

  def route_for(event)
    Array(hash_value(proof_report, :routes)).find do |entry|
      route_value(entry, :from_venue) == event["from_venue"] && route_value(entry, :to_venue) == event["to_venue"]
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
      route_status: route_for(event)&.then { |route| route_value(route, :status) },
      active_short_venues: active_short_venues,
      production_venue: current_production_venue,
      open_orders_zero: direct_open_orders_zero?,
      direct_open_orders: canonical_open_orders,
      inside_tolerance: report_value(:inside_tolerance),
      direct_blockers: Array(report_value(:blockers))
    }
  end

  def venue_short(venue)
    decimal_or_nil(venue_value(venue, :short_eth))
  end

  def open_order_status(venue)
    status = canonical_open_orders.dig(venue, :status)
    status.to_s.presence
  end

  def canonical_open_orders
    @canonical_open_orders ||= VENUES.to_h do |venue|
      raw = direct_open_order_value(venue)
      status, count, message = normalize_open_order_value(raw, venue)
      [ venue, { status: status, count: count, message: message }.compact ]
    end
  end

  def direct_open_order_value(venue)
    direct_open_orders = report_value(:direct_open_orders)
    value = hash_value(direct_open_orders, venue) if direct_open_orders
    return value unless value.nil?

    {
      status: venue_value(venue, :open_orders_status),
      count: venue_value(venue, :open_orders_count),
      message: venue_value(venue, :open_orders_message)
    }
  end

  def normalize_open_order_value(raw, venue)
    case raw
    when Hash
      status = hash_value(raw, :status) || hash_value(raw, :open_orders_status)
      count = hash_value(raw, :count) || hash_value(raw, :open_orders_count)
      message = hash_value(raw, :message) || hash_value(raw, :open_orders_message)
    else
      status = raw
      count = venue_value(venue, :open_orders_count)
      message = venue_value(venue, :open_orders_message)
    end
    status = status.to_s.presence || (count.nil? ? "unknown" : (count.to_i.zero? ? "zero" : "blocked"))
    count = count.to_i if count.present?
    [ status, count, message ]
  end

  def venue_value(venue, key)
    venues = report_value(:venues) || {}
    venue_report = hash_value(venues, venue) || {}
    hash_value(venue_report, key)
  end

  def route_value(route, key)
    hash_value(route, key)
  end

  def report_value(key)
    hash_value(direct_report, key)
  end

  def hash_value(hash, key)
    return nil unless hash.respond_to?(:[])

    hash[key] || hash[key.to_s]
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def truthy?(value)
    value == true || value.to_s == "true"
  end

  def event_time(event)
    Time.zone.parse(event["timestamp"].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
