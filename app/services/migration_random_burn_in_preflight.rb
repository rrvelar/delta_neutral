class MigrationRandomBurnInPreflight
  VENUES = %w[extended ethereal nado].freeze
  FLAT_EPSILON = BigDecimal("0.001")

  def initialize(position:, env: ENV, proof_registry: nil, venue_builder: HedgeVenues, signer_client: nil,
                 fresh_target_factory: nil, readiness_factory: nil)
    @position = position
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @venue_builder = venue_builder
    @signer_client = signer_client || ExtendedStarkSignerClient.new(env: env)
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
    @readiness_factory = readiness_factory
  end

  def report
    position.reload
    target = fresh_target_report
    venue_reports = VENUES.to_h { |venue| [ venue, venue_report(venue) ] }
    combined = combined_short(venue_reports)
    tolerance = target[:target_short_eth] && position.hedge ? target[:target_short_eth] * position.hedge.tolerance : nil
    drift = target[:target_short_eth] && combined ? target[:target_short_eth] - combined : nil
    active = active_short_venues(venue_reports)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    proof_report = proof_registry.report(position: position)
    readiness = readiness_report
    signer = signer_health
    blockers = []
    warnings = []

    blockers.concat(Array(target[:blockers]))
    blockers << "fresh LP target is unavailable" unless target[:target_short_eth]&.positive? && target[:target_fresh] == true
    blockers << "all route proofs must be READY_FOR_RANDOM" unless proof_report.fetch(:missing_route_proofs).empty?
    blockers << "stale route proofs must be resolved" if proof_report.fetch(:stale_route_proofs).present?
    blockers << "pending target=Nado migration continuation must be completed before burn-in" if readiness[:pending_nado_target_continuation_blocking]
    blockers << "migration lock is already active for this position" if MigrationExecutionLock.locked?(position)
    VENUES.each do |venue|
      report = venue_reports.fetch(venue)
      blockers << "#{HedgeVenues.label(venue)} position readback failed: #{report[:error]}" unless report[:position_status] == "ok"
      blockers << "#{venue} short amount is unknown" if report[:short_eth].nil?
      blockers << "#{venue} open orders could not be confirmed zero" unless report[:open_orders_status] == "zero"
    end
    blockers << "combined hedge cannot be computed" unless combined
    blockers << outside_tolerance_blocker(target: target[:target_short_eth], combined: combined, drift: drift, tolerance: tolerance) if drift && tolerance && drift.abs > tolerance
    blockers << "inside tolerance cannot be confirmed" unless drift && tolerance
    blockers << "more than one venue has exposure" if active.size > 1
    blockers << "no venue has the production hedge" if active.empty?
    blockers << "app production venue and actual venue exposure disagree" if active.one? && active.first != current
    blockers << "current production venue has no real short" if current.present? && venue_reports[current]&.fetch(:short_eth, nil).to_d <= FLAT_EPSILON
    blockers << "signer must be healthy" unless signer[:status] == "ok"

    {
      preflight_source: "dedicated_burn_in_preflight",
      accepted: blockers.empty?,
      blockers: blockers.uniq,
      warnings: warnings,
      production_venue: current,
      target: target,
      venues: venue_reports,
      combined_short_eth: combined,
      drift_eth: drift,
      tolerance_abs_eth: tolerance,
      inside_tolerance: drift && tolerance ? drift.abs <= tolerance : nil,
      active_short_venues: active,
      proof_report: proof_report,
      readiness: readiness,
      signer: signer
    }
  end

  private

  attr_reader :position, :env, :proof_registry, :venue_builder, :signer_client, :fresh_target_factory, :readiness_factory

  def fresh_target_report
    result = fresh_target_factory.call(position).resolve(refresh_if_stale: true)
    {
      status: result[:status],
      target_short_eth: decimal_or_nil(result[:target_short_eth]),
      target_source: result[:target_source],
      target_fresh: result[:target_fresh] == true,
      exposure_source: result[:exposure_source],
      exposure_refreshed_at: result[:exposure_refreshed_at],
      blockers: Array(result[:blockers]),
      orders_submitted: result[:orders_submitted].to_i,
      signatures_created: result[:signatures_created].to_i
    }
  rescue => e
    {
      status: "blocked",
      target_short_eth: nil,
      target_source: nil,
      target_fresh: false,
      exposure_source: nil,
      exposure_refreshed_at: nil,
      blockers: [ "fresh LP target refresh failed: #{e.class}: #{e.message}" ],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def venue_report(venue)
    adapter = venue_builder.build(venue, env: env)
    position_row = adapter.read_position(symbol: "ETH")
    short = short_size(position_row)
    open_orders = open_orders_report(adapter)
    {
      short_eth: short,
      position_status: "ok",
      open_orders_count: open_orders[:count],
      open_orders_status: open_orders[:status],
      open_orders_message: open_orders[:message]
    }
  rescue => e
    {
      short_eth: nil,
      position_status: "error",
      error: "#{e.class}: #{e.message}",
      open_orders_count: nil,
      open_orders_status: "unknown",
      open_orders_message: nil
    }
  end

  def open_orders_report(adapter)
    return { status: "unsupported", count: nil, message: "account_state unavailable" } unless adapter.respond_to?(:account_state)

    state = adapter.account_state || {}
    count = state[:open_orders_count] || state["open_orders_count"]
    return { status: "unknown", count: nil, message: state[:open_orders_unavailable_reason] || state["open_orders_unavailable_reason"] } if count.nil?
    return { status: "blocked", count: count.to_i, message: "open orders non-zero" } unless count.to_i.zero?

    { status: "zero", count: 0, message: nil }
  rescue => e
    { status: "unknown", count: nil, message: "#{e.class}: #{e.message}" }
  end

  def readiness_report
    return readiness_factory.call(position: position, proof_registry: proof_registry) if readiness_factory

    MigrationRandomReadiness.new(position: position, proof_registry: proof_registry).report
  end

  def signer_health
    payload = signer_client.health.with_indifferent_access
    { status: ActiveModel::Type::Boolean.new.cast(payload[:ok]) ? "ok" : "down", payload: payload.to_h.except("api_key", "private_key", "signature") }
  rescue => e
    { status: "down", payload: { reason: "#{e.class}: #{e.message}" } }
  end

  def combined_short(reports)
    values = reports.values.map { |report| report[:short_eth] }
    return nil unless values.all?

    values.sum(BigDecimal("0"))
  end

  def active_short_venues(reports)
    reports.select { |_venue, report| report[:short_eth] && report[:short_eth] > FLAT_EPSILON }.keys
  end

  def short_size(row)
    return BigDecimal("0") unless row

    source = row.to_h.with_indifferent_access
    short = decimal_or_nil(source[:short_size])
    return short if short

    size = decimal_or_nil(source[:size])
    size&.negative? ? size.abs : BigDecimal("0")
  end

  def outside_tolerance_blocker(target:, combined:, drift:, tolerance:)
    side = drift.positive? ? "increase_short" : "decrease_short"
    "current hedge outside tolerance: target_short_eth=#{decimal_string(target)} current_short_eth=#{decimal_string(combined)} " \
      "drift_eth=#{decimal_string(drift)} tolerance_abs_eth=#{decimal_string(tolerance)} recommended_rebalance_side=#{side} " \
      "recommended_rebalance_size_eth=#{decimal_string(drift.abs)}"
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def decimal_string(value)
    value&.to_s("F")
  end
end
