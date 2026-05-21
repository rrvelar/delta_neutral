class AerodromeProductionRiskLimits
  HARD_MAX_SHORT_ETH_ENV = "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH"
  HARD_MAX_SHORT_NOTIONAL_USD_ENV = "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD"
  HARD_EMERGENCY_CLOSE_MAX_ETH_ENV = "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH"

  def self.production_hard_max_short_eth
    decimal_env(HARD_MAX_SHORT_ETH_ENV)
  end

  def self.production_hard_max_short_notional_usd
    decimal_env(HARD_MAX_SHORT_NOTIONAL_USD_ENV)
  end

  def self.production_hard_emergency_close_max_eth
    decimal_env(HARD_EMERGENCY_CLOSE_MAX_ETH_ENV)
  end

  def self.hard_ceiling_errors
    errors = []
    errors << "#{HARD_MAX_SHORT_ETH_ENV} must be configured and positive" unless production_hard_max_short_eth&.positive?
    errors << "#{HARD_MAX_SHORT_NOTIONAL_USD_ENV} must be configured and positive" unless production_hard_max_short_notional_usd&.positive?
    errors << "#{HARD_EMERGENCY_CLOSE_MAX_ETH_ENV} must be configured and positive" unless production_hard_emergency_close_max_eth&.positive?
    errors
  end

  def self.runtime_cap_errors(max_short_eth:, max_short_notional_usd:, emergency_close_max_eth:)
    errors = hard_ceiling_errors
    hard_eth = production_hard_max_short_eth
    hard_notional = production_hard_max_short_notional_usd
    hard_emergency = production_hard_emergency_close_max_eth

    unless max_short_eth && hard_eth && max_short_eth <= hard_eth
      errors << "AERODROME_MAX_SHORT_ETH must be configured and <= #{HARD_MAX_SHORT_ETH_ENV}#{formatted_limit(hard_eth)}"
    end
    unless max_short_notional_usd && hard_notional && max_short_notional_usd <= hard_notional
      errors << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= #{HARD_MAX_SHORT_NOTIONAL_USD_ENV}#{formatted_limit(hard_notional)}"
    end
    unless emergency_close_max_eth && max_short_eth && emergency_close_max_eth >= max_short_eth
      errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH"
    end
    unless emergency_close_max_eth && hard_emergency && emergency_close_max_eth <= hard_emergency
      errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and <= #{HARD_EMERGENCY_CLOSE_MAX_ETH_ENV}#{formatted_limit(hard_emergency)}"
    end

    errors
  end

  def self.to_h
    {
      hard_max_short_eth: production_hard_max_short_eth&.to_s("F"),
      hard_max_short_notional_usd: production_hard_max_short_notional_usd&.to_s("F"),
      hard_emergency_close_max_eth: production_hard_emergency_close_max_eth&.to_s("F"),
      errors: hard_ceiling_errors
    }
  end

  def self.decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end
  private_class_method :decimal_env

  def self.formatted_limit(limit)
    limit ? " (#{limit.to_s('F')})" : ""
  end
  private_class_method :formatted_limit
end
