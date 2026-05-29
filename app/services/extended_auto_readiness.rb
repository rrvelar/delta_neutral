class ExtendedAutoReadiness
  def initialize(env: ENV, extended_venue: HedgeVenues::Extended.new(env: env), ethereal_service: EtherealHedgeExecutionService.new(env: env),
                 nado_venue: HedgeVenues::Nado.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), now: -> { Time.current }, fresh_target_factory: nil, anti_churn_policy: nil)
    @env = env
    @extended_venue = extended_venue
    @ethereal_service = ethereal_service
    @nado_venue = nado_venue
    @signer_client = signer_client
    @now = now
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
    @anti_churn_policy = anti_churn_policy || ExtendedAutoAntiChurnPolicy.new(env: env, now: now)
  end

  def report(position:)
    state = read_state(position)
    plan = auto_plan(state)
    blockers = readiness_blockers(position: position, state: state)
    {
      venue: "extended",
      action: "auto_readiness",
      timestamp: @now.call.utc.iso8601,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      execution_venue: position.hedge&.execution_venue,
      target_short_eth: decimal_string(state[:target_short]),
      target_source: state.dig(:fresh_target, :target_source),
      exposure_source: state.dig(:fresh_target, :exposure_source),
      exposure_refreshed_at: state.dig(:fresh_target, :exposure_refreshed_at),
      exposure_stale: state.dig(:fresh_target, :exposure_stale),
      extended_current_short_eth: decimal_string(state[:extended_short]),
      drift_eth: decimal_string(state[:drift]),
      tolerance_eth: decimal_string(state[:tolerance]),
      within_tolerance: state[:drift] && state[:tolerance] ? state[:drift].abs <= state[:tolerance] : nil,
      drift_outside_tolerance: plan[:drift_outside_tolerance],
      planned_auto_action: plan[:planned_auto_action],
      action_suppressed_reason: plan[:action_suppressed_reason],
      min_rebalance_size_eth: plan[:min_rebalance_size_eth],
      min_rebalance_notional_usd: plan[:min_rebalance_notional_usd],
      rebalance_cooldown_seconds: plan[:rebalance_cooldown_seconds],
      cooldown_remaining_seconds: plan[:cooldown_remaining_seconds],
      consecutive_outside_tolerance_required: plan[:consecutive_outside_tolerance_required],
      consecutive_outside_tolerance_count: plan[:consecutive_outside_tolerance_count],
      strong_drift_bypass_multiplier: plan[:strong_drift_bypass_multiplier],
      strong_drift_bypass_used: plan[:strong_drift_bypass_used],
      planned_auto_order_size_eth: decimal_string(plan[:planned_auto_order_size]),
      auto_max_rebalance_size_eth: decimal_string(plan[:auto_max_rebalance_size]),
      partial_auto_rebalance: plan[:partial_auto_rebalance],
      auto_can_act: blockers.empty? && plan[:planned_auto_action] != "no_op" && plan[:action_suppressed_reason].blank?,
      ethereal_short_eth: decimal_string(state[:ethereal_short]),
      ethereal_flat: state[:ethereal_flat],
      nado_short_eth: decimal_string(state[:nado_short]),
      nado_flat: state[:nado_flat],
      extended_live_enabled: bool_env("EXTENDED_LIVE_ENABLED"),
      extended_auto_rebalance_enabled: bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_rebalance_enabled: bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      open_orders_count: state.dig(:account_state, :open_orders_count),
      leverage_margin_gate: state.dig(:account_state, :margin_gate),
      signer_health: sanitize_sensitive(state[:signer_health]),
      continuous_auto_ready: blockers.empty?,
      blockers: blockers,
      warnings: warnings
    }.compact
  end

  private

  def read_state(position)
    extended_position = @extended_venue.read_position(symbol: "ETH")
    ethereal_position = @ethereal_service.read_position
    nado_position = @nado_venue.read_position(symbol: "ETH")
    account_state = @extended_venue.account_state
    fresh_target = @fresh_target_factory.call(position).resolve(refresh_if_stale: true)
    target = fresh_target[:target_short_eth]
    extended_short = short_size(extended_position)
    tolerance = target && position.hedge ? target * position.hedge.tolerance : nil
    {
      position: position,
      target_short: target,
      fresh_target: fresh_target,
      extended_position: extended_position,
      ethereal_position: ethereal_position,
      nado_position: nado_position,
      extended_short: extended_short,
      ethereal_short: short_size(ethereal_position),
      nado_short: short_size(nado_position),
      ethereal_flat: short_size(ethereal_position).zero?,
      nado_flat: short_size(nado_position).zero?,
      account_state: account_state,
      signer_health: @signer_client.health.with_indifferent_access,
      tolerance: tolerance,
      drift: target ? target - extended_short : nil
    }
  end

  def readiness_blockers(position:, state:)
    blockers = []
    blockers << "Position hedge execution_venue must be extended for Extended continuous auto" unless position.hedge&.execution_venue == "extended"
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be true" unless bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be false before Extended continuous auto" if bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    blockers << "Ethereal must be flat before Extended continuous auto" unless state[:ethereal_flat]
    blockers << "Nado must be flat before Extended continuous auto" unless state[:nado_flat]
    blockers << "Extended continuous auto requires open_orders_count=0" unless state.dig(:account_state, :open_orders_count).to_i.zero?
    blockers << "Extended account balance/collateral unavailable" if state.dig(:account_state, :account_value_usd).blank? && state.dig(:account_state, :collateral_usd).blank?
    blockers << "Extended market metadata unavailable" unless state.dig(:account_state, :market_metadata_available)
    blockers.concat(Array(state.dig(:account_state, :margin_gate, :blockers)))
    blockers.concat(signer_health_blockers(state[:signer_health]))
    blockers << "target short could not be computed" unless state[:target_short]
    blockers.concat(Array(state.dig(:fresh_target, :blockers)))
    blockers << state.dig(:plan, :action_suppressed_reason) if state.dig(:plan, :action_suppressed_reason).present?
    blockers.uniq
  end

  def auto_plan(state)
    drift = state[:drift]
    tolerance = state[:tolerance]
    cap = auto_cap
    action = if !drift || !tolerance
      "blocked"
    elsif drift.abs <= tolerance
      "no_op"
    elsif drift.positive?
      "increase_short"
    else
      "decrease_short"
    end
    raw_size = %w[increase_short decrease_short].include?(action) ? drift.abs : nil
    partial = raw_size && raw_size > cap && auto_partial_allowed?
    order_size = partial ? cap : raw_size
    anti_churn = @anti_churn_policy.evaluate(
      position: state[:position],
      hedge: state[:position].hedge,
      action: action,
      drift: drift,
      tolerance: tolerance,
      order_size: raw_size,
      mark_price: mark_price(state),
      readonly: true
    )
    state[:plan] = anti_churn
    {
      planned_auto_action: action,
      action_suppressed_reason: anti_churn[:action_suppressed_reason],
      min_rebalance_size_eth: anti_churn[:min_rebalance_size_eth],
      min_rebalance_notional_usd: anti_churn[:min_rebalance_notional_usd],
      rebalance_cooldown_seconds: anti_churn[:rebalance_cooldown_seconds],
      cooldown_remaining_seconds: anti_churn[:cooldown_remaining_seconds],
      consecutive_outside_tolerance_required: anti_churn[:consecutive_outside_tolerance_required],
      consecutive_outside_tolerance_count: anti_churn[:consecutive_outside_tolerance_count],
      strong_drift_bypass_multiplier: anti_churn[:strong_drift_bypass_multiplier],
      strong_drift_bypass_used: anti_churn[:strong_drift_bypass_used],
      planned_auto_order_size: order_size,
      auto_max_rebalance_size: cap,
      partial_auto_rebalance: partial == true,
      drift_outside_tolerance: %w[increase_short decrease_short].include?(action)
    }
  end

  def signer_health_blockers(health)
    blockers = []
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless ActiveModel::Type::Boolean.new.cast(health[:ok]) && Array.wrap(health[:supported_exchanges]).include?("Extended") && Array.wrap(health[:supported_actions]).include?("sign_extended_order")
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    blockers
  end

  def mark_price(state)
    decimal_or_nil(state.dig(:extended_position, :mark_price)) ||
      decimal_or_nil(state.dig(:account_state, :market_metadata, :mark_price)) ||
      decimal_or_nil(state.dig(:account_state, :read_only_diagnostics, :mark_price))
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def target_short(position)
    fresh_target = @fresh_target_factory.call(position).resolve(refresh_if_stale: true)
    fresh_target[:target_short_eth]
  end

  def short_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?

    size = BigDecimal(position.fetch(:size, 0).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, KeyError
    BigDecimal("0")
  end

  def warnings
    if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
      [ "Extended continuous auto is enabled and remains guarded by readback, signer, leverage/margin, and venue-conflict checks." ]
    else
      [ "Extended continuous auto remains disabled until EXTENDED_AUTO_REBALANCE_ENABLED is explicitly enabled outside the repo." ]
    end
  end

  def auto_cap
    BigDecimal((@env["EXTENDED_AUTO_MAX_REBALANCE_SIZE_ETH"].presence || "0.10").to_s)
  rescue ArgumentError
    BigDecimal("0.10")
  end

  def auto_partial_allowed?
    ActiveModel::Type::Boolean.new.cast(@env.fetch("EXTENDED_AUTO_ALLOW_PARTIAL_REBALANCE", "true"))
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature/i) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end
end
