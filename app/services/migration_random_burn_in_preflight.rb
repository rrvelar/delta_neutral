class MigrationRandomBurnInPreflight
  VENUES = %w[extended ethereal nado].freeze
  FLAT_EPSILON = BigDecimal("0.001")

  def initialize(position:, env: ENV, proof_registry: nil, venue_builder: HedgeVenues, signer_client: nil,
                 fresh_target_factory: nil, readiness_factory: nil, burn_in_tolerance_multiplier: "1.0",
                 burn_in_extra_tolerance_eth: "0", burn_in_max_allowed_drift_eth: "0.15",
                 burn_in_max_allowed_drift_ratio: "0.08")
    @position = position
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @venue_builder = venue_builder
    @signer_client = signer_client || ExtendedStarkSignerClient.new(env: env)
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
    @readiness_factory = readiness_factory
    @burn_in_tolerance_multiplier = decimal_or_nil(burn_in_tolerance_multiplier) || BigDecimal("1.0")
    @burn_in_extra_tolerance_eth = decimal_or_nil(burn_in_extra_tolerance_eth) || BigDecimal("0")
    @burn_in_max_allowed_drift_eth = decimal_or_nil(burn_in_max_allowed_drift_eth) || BigDecimal("0.15")
    @burn_in_max_allowed_drift_ratio = decimal_or_nil(burn_in_max_allowed_drift_ratio) || BigDecimal("0.08")
  end

  def report
    report = MigrationExecutionPreflight.new(
      position: position,
      env: env,
      proof_registry: proof_registry,
      venue_builder: venue_builder,
      signer_client: signer_client,
      fresh_target_factory: fresh_target_factory,
      readiness_factory: readiness_factory,
      require_route_proofs: true,
      require_random_readiness: true,
      tolerance_multiplier: burn_in_tolerance_multiplier,
      extra_tolerance_eth: burn_in_extra_tolerance_eth,
      max_allowed_drift_eth: burn_in_max_allowed_drift_eth,
      max_allowed_drift_ratio: burn_in_max_allowed_drift_ratio
    ).report
    warnings = Array(report[:warnings]).map do |warning|
      warning == "strict tolerance exceeded but within migration preflight tolerance buffer" ? "strict tolerance exceeded but within burn-in tolerance buffer" : warning
    end
    blockers = Array(report[:blockers]).map { |blocker| burn_in_blocker_label(blocker) }
    report.merge(
      warnings: warnings,
      blockers: blockers,
      hard_blockers: blockers,
      burn_in_inside_tolerance: report[:inside_tolerance],
      effective_burn_in_tolerance_eth: report[:effective_tolerance_eth],
      burn_in_tolerance_multiplier: burn_in_tolerance_multiplier,
      burn_in_extra_tolerance_eth: burn_in_extra_tolerance_eth,
      burn_in_max_allowed_drift_eth: burn_in_max_allowed_drift_eth,
      burn_in_max_allowed_drift_ratio: burn_in_max_allowed_drift_ratio,
      recommended_rebalance_side: report[:drift_eth]&.positive? ? "increase_short" : "decrease_short",
      recommended_rebalance_size_eth: report[:drift_eth]&.abs
    )
  end

  private

  attr_reader :position, :env, :proof_registry, :venue_builder, :signer_client, :fresh_target_factory,
    :readiness_factory, :burn_in_tolerance_multiplier, :burn_in_extra_tolerance_eth,
    :burn_in_max_allowed_drift_eth, :burn_in_max_allowed_drift_ratio

  def burn_in_blocker_label(blocker)
    text = blocker.to_s
    return text.sub("max allowed drift exceeded", "burn-in max allowed drift exceeded") if text.start_with?("max allowed drift exceeded")
    return text.sub("max allowed drift ratio exceeded", "burn-in max allowed drift ratio exceeded") if text.start_with?("max allowed drift ratio exceeded")
    return text.sub("current hedge outside tolerance", "current hedge out_of_burn_in_tolerance") if text.start_with?("current hedge outside tolerance")

    text
  end

  def enabled_missing_route_proofs(proof_report)
    policy = MigrationRouteOperationalPolicy.new(env: env)
    proof_report.fetch(:missing_route_proofs).reject do |route|
      !policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
  end

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

  def effective_burn_in_tolerance(strict_tolerance)
    return nil unless strict_tolerance

    [
      strict_tolerance,
      strict_tolerance * burn_in_tolerance_multiplier,
      strict_tolerance + burn_in_extra_tolerance_eth
    ].max
  end

  def outside_tolerance_blocker(target:, combined:, drift:, tolerance:, status:)
    side = drift.positive? ? "increase_short" : "decrease_short"
    "current hedge #{status}: target_short_eth=#{decimal_string(target)} current_short_eth=#{decimal_string(combined)} " \
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
