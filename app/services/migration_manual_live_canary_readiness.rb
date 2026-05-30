class MigrationManualLiveCanaryReadiness
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY".freeze

  def initialize(position:, from:, to:, env: ENV, route_matrix: nil, capability_registry: nil, target_preflight: nil, fresh_target: nil)
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @env = env
    @route_matrix = route_matrix || HedgeVenueMigrationRouteMatrix.new(position: position).report
    @capability_registry = capability_registry || MigrationLiveRouteCapability.new(position: position, route_matrix: @route_matrix, env: env)
    @target_preflight = target_preflight
    @fresh_target = fresh_target
  end

  def report
    route = capability_registry.report.fetch(:routes).find { |row| row[:from_venue] == from && row[:to_venue] == to }
    blockers = readiness_blockers(route)
    target = fresh_target_report
    {
      action: "manual_live_canary_readiness",
      position_id: position.id,
      route: "#{from}->#{to}",
      from_venue: from,
      to_venue: to,
      source_venue: from,
      target_venue: to,
      current_source_short: source_short.to_s("F"),
      target_short: target[:target_short_eth]&.to_s("F"),
      target_short_eth: target[:target_short_eth]&.to_s("F"),
      fresh_target_status: target[:status],
      target_source: target[:target_source],
      exposure_source: target[:exposure_source],
      exposure_refreshed_at: target[:exposure_refreshed_at],
      exposure_stale: target[:exposure_stale],
      mode: "full",
      supported_sequences: %w[target_first],
      recommended_sequence: "target_first",
      source_first_allowed: source_first_allowed?,
      expected_temporary_risk: "target_first avoids source-close-first unhedged failure; source_first is blocked until target open preflight is proven",
      target_leg_blockers: target_leg_blockers,
      source_close_preflight_blockers: [],
      canary_already_confirmed: route&.fetch(:live_canary_confirmed, false) || false,
      live_path_implemented: route&.fetch(:live_path_implemented, false) || false,
      ready_for_supervised_canary: blockers.empty?,
      required_confirmation_phrase: CONFIRMATION,
      blockers: blockers,
      warnings: warnings,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :from, :to, :env, :route_matrix, :capability_registry

  def readiness_blockers(route)
    blockers = []
    blockers << "Route #{from}->#{to} is not known." unless route
    blockers << "Live path is not implemented for #{from}->#{to}." unless route&.fetch(:live_path_implemented, false)
    blockers << "MIGRATION_LIVE_ENABLED must be true for supervised live canary." unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be true." unless bool_env("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
    blockers << "source venue must have a real short before canary." unless source_short.positive?
    blockers.concat(Array(fresh_target_report[:blockers]))
    blockers << "fresh Mellow target is required before supervised canary." unless fresh_target_report[:status] == "ok"
    blockers << "source_first locked by default; target_first is the only recommended live sequence."
    blockers << "Nado live migration path not implemented." if [ from, to ].include?("nado")
    blockers.concat(target_leg_blockers)
    blockers.concat(manual_canary_route_blockers(route)).uniq
  end

  def source_first_blockers(sequence)
    return [] unless sequence.to_s == "source_first"
    return [] if bool_env("MIGRATION_SOURCE_FIRST_CANARY_ALLOWED") && target_leg_blockers.empty?

    [ "source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true" ]
  end

  def target_leg_blockers
    @target_leg_blockers ||= begin
      return [ "Nado live migration path not implemented." ] if to == "nado"

      preflight = @target_preflight || target_preflight_for(to)
      Array(preflight.fetch(:blockers, [])).reject { |blocker| blocker.to_s.start_with?("Current active hedge venue is") }.uniq
    rescue => e
      [ "target venue live-open preflight failed: #{e.class}: #{e.message}" ]
    end
  end

  def target_preflight_for(venue)
    case venue
    when "ethereal"
      EtherealHedgeExecutionService.new(env: env).preflight(
        position: position,
        action: "open",
        size_eth: target_short,
        current_position: nil,
        confirmation: EtherealHedgeExecutionService::CONFIRMATION,
        max_slippage: "0.01"
      )
    when "extended"
      ExtendedHedgeExecutionService.new.preflight(
        position: position,
        action: "open",
        size_eth: target_short,
        current_position: nil,
        confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
        max_slippage: "0.01"
      )
    else
      { blockers: [ "Live target preflight is not implemented for #{venue}." ] }
    end
  end

  def manual_canary_route_blockers(route)
    Array(route&.fetch(:blockers, [])).reject do |blocker|
      blocker.to_s.match?(/LIVE_CANARY_CONFIRMED receipt is required/i)
    end
  end

  def warnings
    [ "Readiness only; this command submits no orders and creates no signatures." ]
  end

  def source_short
    snapshot = position.position_dashboard_snapshot
    BigDecimal(snapshot&.public_send("#{from}_short_eth").to_s)
  rescue ArgumentError, NoMethodError
    BigDecimal("0")
  end

  def target_short
    value = fresh_target_report[:target_short_eth]
    return BigDecimal(value.to_s) if value.present?

    BigDecimal("0")
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def fresh_target_report
    @fresh_target_report ||= (@fresh_target || HedgeFreshTarget.new(position: position, env: env)).resolve(refresh_if_stale: true)
  rescue => e
    {
      status: "blocked",
      target_short_eth: nil,
      blockers: [ "fresh target resolution failed: #{e.class}: #{e.message}" ],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def source_first_allowed?
    bool_env("MIGRATION_SOURCE_FIRST_CANARY_ALLOWED") && target_leg_blockers.empty? && fresh_target_report[:status] == "ok"
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
