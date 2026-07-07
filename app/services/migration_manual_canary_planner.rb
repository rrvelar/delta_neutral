class MigrationManualCanaryPlanner
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY".freeze
  SUPPORTED_LIVE_ROUTES = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze
  KNOWN_ROUTES = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze

  def initialize(position:, from:, to:, env: ENV, target_preflight: nil, fresh_target: nil, sequence: "target_first", now: -> { Time.current }, execution_preflight: nil)
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @env = env
    @target_preflight = target_preflight
    @fresh_target = fresh_target
    @sequence = sequence.to_s.presence || "target_first"
    @now = now
    @execution_preflight = execution_preflight
  end

  def report
    target = fresh_target_report
    blockers = canonical_blockers(target)
    {
      action: "manual_live_canary_readiness",
      position_id: position.id,
      route: "#{from}->#{to}",
      from_venue: from,
      to_venue: to,
      source_venue: from,
      target_venue: to,
      sequence: sequence,
      mode: "full",
      current_production_venue: production_venue,
      production_venue: production_venue,
      fresh_target_status: target[:status],
      target_short: decimal_string(target[:target_short_eth]),
      target_short_eth: decimal_string(target[:target_short_eth]),
      target_source: target[:target_source],
      exposure_source: target[:exposure_source],
      exposure_refreshed_at: target[:exposure_refreshed_at],
      exposure_stale: target[:exposure_stale],
      current_source_short: decimal_string(source_short),
      current_target_short: decimal_string(target_venue_short),
      extended_short_eth: decimal_string(venue_short("extended")),
      ethereal_short_eth: decimal_string(venue_short("ethereal")),
      nado_short_eth: decimal_string(venue_short("nado")),
      nado_flat: nado_flat?,
      open_orders_status: open_orders_status,
      route_support: route_support,
      live_path_implemented: live_path_implemented?,
      supported_sequences: supported_sequences,
      requested_sequence: sequence,
      recommended_sequence: recommended_sequence,
      source_first_supported: source_first_route?,
      source_first_allowed: source_first_allowed?(target),
      target_leg_preview: target_leg,
      source_close_preview: source_leg,
      planned_target_leg: target_leg,
      planned_source_leg: source_leg,
      planned_first_leg: sequence == "source_first" ? source_leg : target_leg,
      planned_second_leg: sequence == "source_first" ? target_leg : source_leg,
      target_leg_blockers: target_leg_blockers,
      source_close_preflight_blockers: source_close_preflight_blockers,
      source_target_auto_blockers: auto_enabled_blockers,
      live_env_gate_blockers: live_env_gate_blockers,
      migration_gate_blockers: migration_gate_blockers,
      full_migration_gate_blockers: full_migration_gate_blockers,
      required_confirmation_phrase: CONFIRMATION,
      expected_temporary_risk: temporary_risk_description,
      expected_final_combined_short: decimal_string(expected_final_combined),
      expected_final_inside_tolerance: final_inside_tolerance?,
      ready_for_supervised_canary: blockers.empty?,
      canary_already_confirmed: false,
      blockers: blockers,
      warnings: warnings,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }.merge(executor_plan_fields(target: target, blockers: blockers))
  end

  private

  attr_reader :position, :from, :to, :env, :sequence, :now, :execution_preflight

  def canonical_blockers(target)
    blockers = []
    blockers << "Route #{from}->#{to} is not known." unless route_known?
    blockers << "Live path is unavailable for #{from}->#{to}." unless live_path_implemented?
    blockers.concat(migration_gate_blockers)
    blockers.concat(full_migration_gate_blockers)
    blockers.concat(live_env_gate_blockers)
    blockers.concat(auto_enabled_blockers)
    blockers.concat(Array(execution_preflight&.fetch(:hard_blockers, nil) || execution_preflight&.fetch(:blockers, nil)))
    unless execution_preflight
      blockers << "position hedge execution_venue must be #{from} before migration" unless production_venue == from
      blockers << "source venue must have a real short before canary." unless source_short.positive?
      blockers.concat(Array(target[:blockers]))
    end
    blockers << "fresh Mellow target is required before supervised canary." unless target[:status] == "ok"
    blockers << "Nado must be flat before supervised canary." if ![ from, to ].include?("nado") && !nado_flat?
    blockers.concat(source_first_blockers(target))
    blockers.concat(target_leg_blockers)
    blockers.concat(source_close_preflight_blockers)
    blockers << "target/source open orders must be zero." unless open_orders_clear?
    blockers.uniq
  end

  def route_known?
    KNOWN_ROUTES.include?([ from, to ])
  end

  def live_path_implemented?
    SUPPORTED_LIVE_ROUTES.include?([ from, to ])
  end

  def route_support
    {
      known: route_known?,
      dry_run_ready: live_path_implemented? && source_short.positive? && fresh_target_report[:status] == "ok",
      live_path_implemented: live_path_implemented?,
      target_first_supported: live_path_implemented? && !source_first_route?,
      source_first_supported: live_path_implemented? && source_first_route?
    }
  end

  # The single source of truth for a route's intended sequence is the operational
  # route policy (e.g. nado-target routes default to source_first). The manual
  # canary must recommend the same sequence the production runner and route-proof
  # registry use, so readiness, planner, policy and the canary command agree.
  def route_policy
    @route_policy ||= MigrationRouteOperationalPolicy.new(env: env)
  end

  def recommended_sequence
    @recommended_sequence ||= begin
      strategy = route_policy.route_strategy(from: from, to: to)
      strategy.to_s.in?(%w[target_first source_first]) ? strategy : "target_first"
    end
  end

  def source_first_route?
    recommended_sequence == "source_first"
  end

  def supported_sequences
    [ recommended_sequence ]
  end

  def migration_gate_blockers
    blockers = []
    blockers << "MIGRATION_LIVE_ENABLED must be true for supervised live canary." unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be true." unless bool_env("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
    blockers
  end

  def full_migration_gate_blockers
    bool_env("MIGRATION_FULL_ALLOWED") ? [] : [ "MIGRATION_FULL_ALLOWED must be true for full supervised canary." ]
  end

  def live_env_gate_blockers
    blockers = []
    blockers << "EXTENDED_LIVE_ENABLED must be true" if [ from, to ].include?("extended") && !bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" if [ from, to ].include?("extended") && !bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" if [ from, to ].include?("ethereal") && !bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    blockers << "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true" if [ from, to ].include?("nado") && !bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    blockers << "AERODROME_NADO_LIVE_MIGRATION_ENABLED must be true" if [ from, to ].include?("nado") && !bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    blockers
  end

  def auto_enabled_blockers
    blockers = []
    blockers << "source venue auto must be disabled during migration canary: #{from}" if venue_auto_enabled?(from)
    blockers << "target venue auto must be disabled during migration canary: #{to}" if venue_auto_enabled?(to)
    blockers
  end

  def source_first_blockers(target)
    return [] unless sequence == "source_first"
    return [] if source_first_allowed?(target)

    [ "source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true" ]
  end

  def source_first_allowed?(target)
    bool_env("MIGRATION_SOURCE_FIRST_CANARY_ALLOWED") == true &&
      target[:status] == "ok" &&
      target_leg_blockers.empty?
  end

  def target_leg_blockers
    @target_leg_blockers ||= begin
      return [ "target short is unavailable" ] unless target_short.positive?

      preflight = @target_preflight || target_preflight_for(to)
      Array(preflight.fetch(:blockers, [])).reject { |blocker| blocker.to_s.start_with?("Current active hedge venue is") }.uniq
    rescue => e
      [ "target venue live-open preflight failed: #{e.class}: #{e.message}" ]
    end
  end

  def source_close_preflight_blockers
    blockers = []
    blockers << "source venue must have a real short before canary." unless source_short.positive?
    blockers << "source close preview unavailable." unless source_leg
    blockers
  end

  def target_preflight_for(venue)
    case venue
    when "ethereal"
      EtherealHedgeExecutionService.new(env: env).preflight(
        position: position,
        action: "open",
        size_eth: target_open_size,
        current_position: nil,
        confirmation: EtherealHedgeExecutionService::CONFIRMATION,
        max_slippage: max_slippage,
        migration_target_leg: true
      )
    when "extended"
      ExtendedHedgeExecutionService.new(venue: HedgeVenues::Extended.new(env: env)).preflight(
        position: position,
        action: "open",
        size_eth: target_open_size,
        current_position: nil,
        confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
        max_slippage: max_slippage,
        capability: :migration_live
      )
    when "nado"
      NadoHedgeExecutionService.new(env: env).preflight(
        position: position,
        action: "open",
        size_eth: target_open_size,
        current_position: nil,
        confirmation: env["AERODROME_NADO_HEDGE_CONFIRMATION"],
        max_slippage: max_slippage
      )
    else
      { blockers: [ "Live target preflight is unavailable for #{venue}." ] }
    end
  end

  def target_leg
    return nil unless target_open_size.positive?

    {
      venue: to,
      action: target_venue_short.positive? ? "increase_short" : "open_short",
      side: "sell",
      reduce_only: false,
      size_eth: decimal_string(target_open_size),
      expected_after_short_eth: decimal_string(target_short),
      confirmation_required: true
    }
  end

  def source_leg
    return nil unless source_short.positive?

    {
      venue: from,
      action: "close_short",
      side: "buy",
      reduce_only: true,
      size_eth: decimal_string(source_short),
      expected_after_short_eth: "0",
      confirmation_required: true
    }
  end

  def executor_plan_fields(target:, blockers:)
    {
      current_production_venue: production_venue,
      source_snapshot_id: snapshot&.id,
      source_snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      extended_short_before: decimal_string(venue_short("extended")),
      ethereal_short_before: decimal_string(venue_short("ethereal")),
      nado_short_before: decimal_string(venue_short("nado")),
      from_short_before: decimal_string(source_short),
      to_short_before: decimal_string(target_venue_short),
      target_short: decimal_string(target[:target_short_eth]),
      tolerance_abs_eth: decimal_string(tolerance_abs),
      combined_before: decimal_string(combined_short),
      combined_short_before: decimal_string(combined_short),
      drift_before: decimal_string(target_short - combined_short),
      planned_from_leg: source_leg,
      planned_to_leg: target_leg,
      migration_sequence: sequence,
      temporary_combined_after_first_leg: decimal_string(sequence == "source_first" ? combined_short - source_short : combined_short + target_open_size),
      temporary_risk_type: sequence == "source_first" ? "underhedge/unhedged" : "overhedge",
      expected_from_short_after: "0",
      expected_to_short_after: decimal_string(target_short),
      expected_combined_short_after: decimal_string(expected_final_combined),
      expected_final_drift: decimal_string(target_short - expected_final_combined),
      final_expected_inside_tolerance: final_inside_tolerance?,
      full_migration_allowed: true,
      finalize_available: false,
      required_gates: required_gates,
      live_gates: required_gates,
      dry_run: true,
      submitted: false,
      blockers: blockers,
      warnings: warnings
    }
  end

  def required_gates
    [
      "MIGRATION_LIVE_ENABLED=true for live execution",
      "MIGRATION_MANUAL_LIVE_CANARY_ENABLED=true",
      "MIGRATION_FULL_ALLOWED=true",
      "exact manual live canary confirmation phrase",
      "#{HedgeVenues.label(from)} live enabled",
      "#{HedgeVenues.label(to)} live enabled",
      "source and target auto disabled during migration",
      "open_orders_count=0 on both venues",
      "fresh Mellow target",
      "readback confirmation after each leg"
    ]
  end

  def warnings
    [
      "Canonical manual canary plan only; readiness submits no orders and creates no signatures.",
      temporary_risk_description
    ]
  end

  def temporary_risk_description
    if recommended_sequence == "source_first"
      "Source-first sequence temporarily underhedges until the target open confirms (requires MIGRATION_SOURCE_FIRST_CANARY_ALLOWED)."
    else
      "Target-first sequence temporarily overhedges until source venue reduction confirms."
    end
  end

  def fresh_target_report
    if execution_preflight
      target = execution_preflight.fetch(:target)
      return {
        status: target[:status],
        target_short_eth: target[:target_short_eth],
        target_source: target[:target_source],
        exposure_source: target[:exposure_source],
        exposure_refreshed_at: target[:exposure_refreshed_at],
        exposure_stale: target[:target_fresh] != true,
        blockers: Array(execution_preflight[:hard_blockers] || execution_preflight[:blockers]),
        orders_submitted: 0,
        signatures_created: 0
      }
    end

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

  def snapshot
    @snapshot ||= position.position_dashboard_snapshot
  end

  def production_venue
    HedgeVenues.normalize(position.hedge&.execution_venue)
  end

  def source_short
    venue_short(from)
  end

  def target_venue_short
    venue_short(to)
  end

  def target_short
    decimal(fresh_target_report[:target_short_eth])
  end

  def target_open_size
    [ target_short - target_venue_short, BigDecimal("0") ].max
  end

  def expected_final_combined
    target_short + other_venue_short
  end

  def final_inside_tolerance?
    return nil unless target_short.positive? && tolerance_abs.positive?

    (target_short - expected_final_combined).abs <= tolerance_abs
  end

  def tolerance_abs
    return target_short * BigDecimal(position.hedge.tolerance.to_s) if target_short.positive? && position.hedge

    BigDecimal("0")
  end

  def combined_short
    venue_short("extended") + venue_short("ethereal") + venue_short("nado")
  end

  def other_venue_short
    (%w[extended ethereal nado] - [ from, to ]).sum { |venue| venue_short(venue) }
  end

  def venue_short(venue)
    if execution_preflight
      return BigDecimal(execution_preflight.dig(:venues, venue, :short_eth).to_s)
    end

    BigDecimal(snapshot&.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, NoMethodError
    BigDecimal("0")
  end

  def nado_flat?
    venue_short("nado").zero?
  end

  def open_orders_status
    open_orders_clear? ? "zero" : "blocked"
  end

  def open_orders_clear?
    return false if [ from, to ].include?("extended") && !snapshot&.open_orders_count_extended.to_i.zero?

    true
  end

  def venue_auto_enabled?(venue)
    case venue
    when "extended"
      bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    when "ethereal"
      bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    when "nado"
      bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    else
      false
    end
  end

  def max_slippage
    env.fetch("MIGRATION_MAX_SLIPPAGE", env.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01"))
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_string(value)
    return nil if value.nil?

    BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError, TypeError
    nil
  end
end
