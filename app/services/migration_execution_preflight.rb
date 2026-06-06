class MigrationExecutionPreflight
  VENUES = %w[extended ethereal nado].freeze
  FLAT_EPSILON = BigDecimal("0.001")

  def initialize(position:, from: nil, to: nil, strategy: nil, env: ENV, venue_builder: HedgeVenues,
                 signer_client: nil, fresh_target_factory: nil, proof_registry: nil, readiness_factory: nil,
                 live: false, confirmation: nil, expected_confirmation: nil, require_route_proofs: false,
                 require_random_readiness: false, require_migration_live_gate: false,
                 require_venue_live_gates: false, allow_outside_tolerance: false,
                 tolerance_multiplier: "1.0", extra_tolerance_eth: "0",
                 max_allowed_drift_eth: nil, max_allowed_drift_ratio: nil)
    @position = position
    @from = HedgeVenues.known_key(from)
    @to = HedgeVenues.known_key(to)
    @strategy = strategy.presence
    @env = env
    @venue_builder = venue_builder
    @signer_client = signer_client || ExtendedStarkSignerClient.new(env: env)
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @readiness_factory = readiness_factory
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @confirmation = confirmation
    @expected_confirmation = expected_confirmation
    @require_route_proofs = require_route_proofs
    @require_random_readiness = require_random_readiness
    @require_migration_live_gate = require_migration_live_gate
    @require_venue_live_gates = require_venue_live_gates
    @allow_outside_tolerance = allow_outside_tolerance
    @tolerance_multiplier = decimal_or_nil(tolerance_multiplier) || BigDecimal("1.0")
    @extra_tolerance_eth = decimal_or_nil(extra_tolerance_eth) || BigDecimal("0")
    @max_allowed_drift_eth = decimal_or_nil(max_allowed_drift_eth)
    @max_allowed_drift_ratio = decimal_or_nil(max_allowed_drift_ratio)
  end

  def report
    position.reload
    target = fresh_target_report
    venues = VENUES.to_h { |venue| [ venue, venue_report(venue) ] }
    combined = combined_short(venues)
    strict_tolerance = target[:target_short_eth] && position.hedge ? target[:target_short_eth] * position.hedge.tolerance : nil
    effective_tolerance = effective_tolerance(strict_tolerance)
    drift = target[:target_short_eth] && combined ? target[:target_short_eth] - combined : nil
    drift_ratio = target[:target_short_eth]&.positive? && drift ? drift.abs / target[:target_short_eth] : nil
    strict_inside = drift && strict_tolerance ? drift.abs <= strict_tolerance : nil
    effective_inside = drift && effective_tolerance ? drift.abs <= effective_tolerance : nil
    active = active_short_venues(venues)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    proof_report = proof_registry.report(position: position)
    readiness = readiness_report
    signer = signer_health
    blockers = []
    warnings = dashboard_warnings(venues)

    add_confirmation_blockers(blockers)
    add_route_policy_blockers(blockers)
    add_live_gate_blockers(blockers)
    blockers.concat(Array(target[:blockers]))
    blockers << "fresh LP target is unavailable" unless target[:target_short_eth]&.positive? && target[:target_fresh] == true
    blockers << "migration lock is already active for this position" if MigrationExecutionLock.locked?(position)
    add_route_proof_blockers(blockers, proof_report, readiness)
    add_venue_readback_blockers(blockers, venues)
    blockers << "combined hedge cannot be computed" unless combined
    add_tolerance_blockers(blockers, target: target[:target_short_eth], combined: combined, drift: drift, drift_ratio: drift_ratio, effective_tolerance: effective_tolerance, effective_inside: effective_inside)
    warnings << "strict tolerance exceeded but within migration preflight tolerance buffer" if strict_inside == false && effective_inside == true
    add_exposure_blockers(blockers, venues: venues, active: active, current: current)
    add_route_specific_blockers(blockers, venues: venues, current: current)
    blockers << "signer must be healthy" unless signer[:status] == "ok"

    diagnostics = diagnostics_payload(
      target: target,
      venues: venues,
      combined: combined,
      drift: drift,
      strict_tolerance: strict_tolerance,
      effective_tolerance: effective_tolerance,
      strict_inside: strict_inside,
      effective_inside: effective_inside,
      active: active,
      current: current,
      proof_report: proof_report,
      readiness: readiness,
      signer: signer
    )
    status = blockers.empty? ? (warnings.empty? ? "ready" : "warning") : "blocked"
    diagnostics.merge(
      preflight_source: "migration_execution_preflight",
      status: status,
      can_submit: blockers.empty?,
      accepted: blockers.empty?,
      hard_blockers: blockers.uniq,
      blockers: blockers.uniq,
      warnings: warnings.uniq,
      diagnostics: diagnostics,
      source_of_truth: source_of_truth_payload(target: target, venues: venues)
    )
  end

  private

  attr_reader :position, :from, :to, :strategy, :env, :venue_builder, :signer_client, :fresh_target_factory,
    :proof_registry, :readiness_factory, :live, :confirmation, :expected_confirmation, :require_route_proofs,
    :require_random_readiness, :require_migration_live_gate, :require_venue_live_gates, :allow_outside_tolerance,
    :tolerance_multiplier, :extra_tolerance_eth, :max_allowed_drift_eth, :max_allowed_drift_ratio

  def add_confirmation_blockers(blockers)
    return unless live && expected_confirmation

    blockers << "submitted confirmation must equal #{expected_confirmation}" unless confirmation == expected_confirmation
  end

  def add_route_policy_blockers(blockers)
    return unless from && to

    policy = MigrationRouteOperationalPolicy.new(env: env).route_status(from: from, to: to)
    blockers << "route strategy is #{policy.fetch(:strategy)} for #{from}->#{to}" unless policy.fetch(:production_execution_enabled)
  end

  def add_live_gate_blockers(blockers)
    return unless live

    blockers << "MIGRATION_LIVE_ENABLED must be true" if require_migration_live_gate && !bool_env("MIGRATION_LIVE_ENABLED")
    return unless require_venue_live_gates && from && to

    blockers << "#{HedgeVenues.label(from)} live gate must be enabled." unless venue_live_enabled?(from)
    blockers << "#{HedgeVenues.label(to)} live gate must be enabled." unless venue_live_enabled?(to)
  end

  def add_route_proof_blockers(blockers, proof_report, readiness)
    return unless require_route_proofs || require_random_readiness

    blockers << "all enabled route proofs must be READY_FOR_RANDOM" if enabled_missing_route_proofs(proof_report).present?
    blockers << "stale route proofs must be resolved" if proof_report.fetch(:stale_route_proofs).present?
    blockers << "pending target=Nado migration continuation must be completed before migration" if readiness[:pending_nado_target_continuation_blocking]
  end

  def add_venue_readback_blockers(blockers, venues)
    VENUES.each do |venue|
      report = venues.fetch(venue)
      blockers << "#{HedgeVenues.label(venue)} position readback failed: #{report[:error]}" unless report[:position_status] == "ok"
      blockers << "#{venue} short amount is unknown" if report[:short_eth].nil?
    end
    relevant_open_order_venues.each do |venue|
      report = venues.fetch(venue)
      blockers << "#{venue} open orders could not be confirmed zero" if report[:open_orders_status] == "unknown"
      blockers << "#{venue} open orders must be zero" if report[:open_orders_status] == "blocked"
    end
  end

  def add_tolerance_blockers(blockers, target:, combined:, drift:, drift_ratio:, effective_tolerance:, effective_inside:)
    blockers << "inside tolerance cannot be confirmed" unless !drift.nil? && !effective_tolerance.nil?
    return if allow_outside_tolerance

    if drift && max_allowed_drift_eth && drift.abs > max_allowed_drift_eth
      blockers << "max allowed drift exceeded: drift_eth=#{decimal_string(drift.abs)} max=#{decimal_string(max_allowed_drift_eth)}"
    end
    if drift_ratio && max_allowed_drift_ratio && drift_ratio > max_allowed_drift_ratio
      blockers << "max allowed drift ratio exceeded: drift_ratio=#{decimal_string(drift_ratio)} max=#{decimal_string(max_allowed_drift_ratio)}"
    end
    return unless effective_inside == false

    blockers << outside_tolerance_blocker(target: target, combined: combined, drift: drift, tolerance: effective_tolerance)
  end

  def add_exposure_blockers(blockers, venues:, active:, current:)
    blockers << "more than one venue has exposure" if active.size > 1
    blockers << "no venue has the production hedge" if active.empty?
    blockers << "app production venue and actual venue exposure disagree" if active.one? && active.first != current
    blockers << "current production venue has no real short" if current.present? && venues[current]&.fetch(:short_eth, nil).to_d <= FLAT_EPSILON
  end

  def add_route_specific_blockers(blockers, venues:, current:)
    return unless from && to

    source_short = venues[from]&.fetch(:short_eth, nil)
    target_short = venues[to]&.fetch(:short_eth, nil)
    blockers << "position hedge execution_venue must be #{from} before migration" unless current == from
    blockers << "source current position must exist." if source_short.nil? || source_short <= FLAT_EPSILON
    blockers << "#{HedgeVenues.label(to)} target venue must be flat before migration" if target_short && target_short > FLAT_EPSILON
    third_venues.each do |venue|
      short = venues[venue]&.fetch(:short_eth, nil)
      blockers << "#{HedgeVenues.label(venue)} third venue must be flat before migration" if short && short > FLAT_EPSILON
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
      asset0_amount: result[:asset0_amount],
      asset1_amount: result[:asset1_amount],
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

  def relevant_open_order_venues
    from && to ? [ from, to ] : VENUES
  end

  def third_venues
    VENUES - [ from, to ]
  end

  def dashboard_warnings(venues)
    snapshot = position.position_dashboard_snapshot
    return [] unless snapshot

    warnings = []
    if snapshot.refresh_status.to_s != "ok" && critical_direct_readbacks_ok?(venues)
      warnings << "dashboard snapshot refresh_status=#{snapshot.refresh_status} treated as diagnostic; direct migration preflight readbacks are authoritative"
    end
    warnings.concat(optional_source_error_warnings(snapshot, venues))
    warnings
  end

  def critical_direct_readbacks_ok?(venues)
    VENUES.all? { |venue| venues.dig(venue, :position_status) == "ok" && !venues.dig(venue, :short_eth).nil? }
  end

  def optional_source_error_warnings(snapshot, venues)
    source_errors = snapshot.respond_to?(:source_errors) ? snapshot.source_errors : nil
    messages = source_error_messages(source_errors)
    messages.filter_map do |message|
      text = message.to_s
      next unless text.match?(/optional|account state|timed_out|timeout/i)

      venue = VENUES.find { |candidate| text.downcase.include?(candidate) }
      next if venue && venues.dig(venue, :position_status) != "ok"

      "optional dashboard diagnostic ignored: #{text}"
    end
  end

  def source_error_messages(value)
    return value if value.is_a?(Array)
    return [] if value.blank?

    parsed = JSON.parse(value.to_s)
    parsed.is_a?(Array) ? parsed : [ value.to_s ]
  rescue JSON::ParserError
    [ value.to_s ]
  end

  def diagnostics_payload(target:, venues:, combined:, drift:, strict_tolerance:, effective_tolerance:, strict_inside:, effective_inside:, active:, current:, proof_report:, readiness:, signer:)
    {
      production_venue: current,
      target: target,
      venues: venues,
      combined_short_eth: combined,
      drift_eth: drift,
      tolerance_abs_eth: strict_tolerance,
      strict_inside_tolerance: strict_inside,
      inside_tolerance: effective_inside,
      strict_tolerance_eth: strict_tolerance,
      effective_tolerance_eth: effective_tolerance,
      active_short_venues: active,
      proof_report: proof_report,
      readiness: readiness,
      signer: signer,
      route: from && to ? "#{from}->#{to}" : nil,
      from_venue: from,
      to_venue: to,
      strategy: strategy
    }
  end

  def source_of_truth_payload(target:, venues:)
    {
      lp_target: target,
      source_position: from ? venues[from] : nil,
      target_position: to ? venues[to] : nil,
      third_venue_position: from && to ? third_venues.to_h { |venue| [ venue, venues[venue] ] } : nil,
      venue_positions: venues,
      open_orders: venues.transform_values { |venue| { status: venue[:open_orders_status], count: venue[:open_orders_count], message: venue[:open_orders_message] } },
      dashboard_snapshot: dashboard_snapshot_source
    }
  end

  def dashboard_snapshot_source
    snapshot = position.position_dashboard_snapshot
    return { status: "missing" } unless snapshot

    {
      id: snapshot.id,
      refresh_status: snapshot.refresh_status,
      refreshed_at: snapshot.refreshed_at&.utc&.iso8601
    }
  end

  def readiness_report
    return {} unless require_route_proofs || require_random_readiness
    return readiness_factory.call(position: position, proof_registry: proof_registry) if readiness_factory

    MigrationRandomReadiness.new(position: position, proof_registry: proof_registry).report
  end

  def signer_health
    payload = signer_client.health.with_indifferent_access
    { status: ActiveModel::Type::Boolean.new.cast(payload[:ok]) ? "ok" : "down", payload: payload.to_h.except("api_key", "private_key", "signature") }
  rescue => e
    { status: "down", payload: { reason: "#{e.class}: #{e.message}" } }
  end

  def enabled_missing_route_proofs(proof_report)
    policy = MigrationRouteOperationalPolicy.new(env: env)
    proof_report.fetch(:missing_route_proofs, []).reject do |route|
      !policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
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

  def effective_tolerance(strict_tolerance)
    return nil unless strict_tolerance

    [
      strict_tolerance,
      strict_tolerance * tolerance_multiplier,
      strict_tolerance + extra_tolerance_eth
    ].max
  end

  def outside_tolerance_blocker(target:, combined:, drift:, tolerance:)
    side = drift.positive? ? "increase_short" : "decrease_short"
    "current hedge outside tolerance: target_short_eth=#{decimal_string(target)} current_short_eth=#{decimal_string(combined)} " \
      "drift_eth=#{decimal_string(drift)} tolerance_abs_eth=#{decimal_string(tolerance)} recommended_rebalance_side=#{side} " \
      "recommended_rebalance_size_eth=#{decimal_string(drift.abs)}"
  end

  def venue_live_enabled?(venue)
    case venue
    when "extended" then bool_env("EXTENDED_LIVE_ENABLED")
    when "ethereal" then bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    when "nado" then bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED") && bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    else false
    end
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
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
