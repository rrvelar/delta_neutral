class AerodromeAutoRebalanceStatus
  RECURRING_CONFIG = Rails.root.join("config", "recurring.yml")

  def initialize(position:, dashboard_status: {})
    @position = position
    @dashboard_status = dashboard_status || {}
    @warnings = []
  end

  def report
    hedge = active_hedge
    last_rebalance = hedge&.short_rebalances&.order(rebalanced_at: :desc, id: :desc)&.first
    target = target_short(hedge)
    current_short = decimal_from_status(:current_short_eth)
    drift = decimal_from_status(:drift_eth)
    tolerance = target && hedge ? target * hedge.tolerance : nil
    inside_tolerance = drift && tolerance ? drift.abs <= tolerance : nil
    rebalance_needed = drift && tolerance ? drift.abs > tolerance : false
    blockers = status_blockers(hedge: hedge, rebalance_needed: rebalance_needed)

    {
      database_write: false,
      external_api: false,
      position: @position,
      hedge: hedge,
      scheduler: scheduler_status,
      current_target_hedge_eth: target&.to_s("F"),
      current_hyperliquid_eth_short: current_short&.to_s("F"),
      current_drift_eth: drift&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      inside_tolerance: inside_tolerance,
      rebalance_needed: rebalance_needed,
      last_short_rebalance: last_rebalance,
      last_rebalance_time: last_rebalance&.rebalanced_at,
      last_rebalance_status: last_rebalance&.status,
      estimated_lower_eth_price_threshold: estimated_thresholds(target: target, current_short: current_short, tolerance: tolerance)[:lower],
      estimated_upper_eth_price_threshold: estimated_thresholds(target: target, current_short: current_short, tolerance: tolerance)[:upper],
      threshold_confidence: "low",
      auto_rebalance_status: auto_rebalance_status(blockers: blockers, hedge: hedge),
      env_gates: env_gates,
      blockers: blockers,
      warnings: @warnings
    }
  end

  private

  def active_hedge
    Hedge.where(position_id: @position.id, active: true).order(id: :desc).first
  end

  def target_short(hedge)
    return nil unless hedge && weth_amount

    weth_amount * hedge.target
  end

  def weth_amount
    if %w[ETH WETH].include?(@position.asset0.to_s.upcase)
      @position.asset0_amount
    elsif %w[ETH WETH].include?(@position.asset1.to_s.upcase)
      @position.asset1_amount
    end
  end

  def eth_price
    if %w[ETH WETH].include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif %w[ETH WETH].include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
    end
  end

  def decimal_from_status(key)
    raw = @dashboard_status[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def scheduler_status
    config = YAML.safe_load_file(RECURRING_CONFIG, aliases: true)
    env_config = config[Rails.env] || config["default"] || {}
    {
      position_sync_schedule: schedule_for(env_config, "PositionSyncJob"),
      hedge_sync_schedule: schedule_for(env_config, "HedgeSyncJob")
    }
  rescue => e
    @warnings << "recurring schedule unavailable: #{e.class}: #{e.message}"
    {
      position_sync_schedule: nil,
      hedge_sync_schedule: nil
    }
  end

  def schedule_for(config, class_name)
    config.values.find { |entry| entry.is_a?(Hash) && entry["class"] == class_name }&.fetch("schedule", nil)
  end

  def estimated_thresholds(target:, current_short:, tolerance:)
    return { lower: nil, upper: nil } unless target&.positive? && current_short && tolerance && eth_price&.positive?

    lower_target = current_short + tolerance
    upper_target = current_short - tolerance
    {
      lower: approximate_price_for_target(target, lower_target)&.to_s("F"),
      upper: approximate_price_for_target(target, upper_target)&.to_s("F")
    }
  end

  def approximate_price_for_target(current_target, threshold_target)
    return nil unless threshold_target&.positive?

    eth_price * (current_target / threshold_target)
  end

  def status_blockers(hedge:, rebalance_needed:)
    blockers = []
    blockers << "No active hedge configured for this position" unless hedge
    blockers << "current Hyperliquid ETH short unavailable" if decimal_from_status(:current_short_eth).nil?
    blockers << "current target hedge unavailable" if hedge && target_short(hedge).nil?
    blockers << "rebalance needed but AERODROME_HEDGE_ENABLED is not true" if rebalance_needed && !bool_env("AERODROME_HEDGE_ENABLED")
    blockers << "rebalance needed but AERODROME_HEDGE_PAUSED is true" if rebalance_needed && bool_env("AERODROME_HEDGE_PAUSED", default: true)
    blockers << "rebalance needed but AERODROME_LIVE_APPROVED is not true" if rebalance_needed && !bool_env("AERODROME_LIVE_APPROVED")
    blockers << "rebalance needed but HYPERLIQUID_TESTNET is true" if rebalance_needed && bool_env("HYPERLIQUID_TESTNET", default: true)
    blockers
  end

  def auto_rebalance_status(blockers:, hedge:)
    return "blocked" if blockers.any?
    return "paused" if !hedge || !bool_env("AERODROME_HEDGE_ENABLED") || bool_env("AERODROME_HEDGE_PAUSED", default: true)

    "active"
  end

  def env_gates
    {
      "AERODROME_HEDGE_ENABLED" => ENV.fetch("AERODROME_HEDGE_ENABLED", nil),
      "AERODROME_HEDGE_PAUSED" => ENV.fetch("AERODROME_HEDGE_PAUSED", nil),
      "AERODROME_LIVE_APPROVED" => ENV.fetch("AERODROME_LIVE_APPROVED", nil),
      "HYPERLIQUID_TESTNET" => ENV.fetch("HYPERLIQUID_TESTNET", nil),
      "AERODROME_MAX_SHORT_ETH" => ENV.fetch("AERODROME_MAX_SHORT_ETH", nil),
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => ENV.fetch("AERODROME_MAX_SHORT_NOTIONAL_USD", nil)
    }
  end

  def bool_env(key, default: false)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
  end
end
