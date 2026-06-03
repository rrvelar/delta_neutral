require "bigdecimal"

class RiskSettings
  INCREASE_CONFIRMATION = "I_UNDERSTAND_THIS_INCREASES_HEDGE_RISK".freeze
  DECREASE_CONFIRMATION = "I_UNDERSTAND_THIS_CHANGES_HEDGE_RISK_LIMITS".freeze
  HARD_INCREASE_CONFIRMATION = "I_UNDERSTAND_THIS_RAISES_PRODUCTION_HARD_RISK_LIMITS".freeze
  ABSURD_CAP_ETH = BigDecimal("100")
  ABSURD_NOTIONAL_USD = BigDecimal("10000000")
  ABSURD_ORDER_ETH = BigDecimal("25")

  DEFAULT_KEYS = %w[DEFAULT_HEDGE_EXECUTION_VENUE].freeze
  GLOBAL_CAP_KEYS = %w[
    AERODROME_MAX_SHORT_ETH
    AERODROME_MAX_ORDER_SIZE_ETH
    AERODROME_MAX_NOTIONAL_USD
    AERODROME_MAX_SHORT_NOTIONAL_USD
    AERODROME_MAX_TOTAL_HEDGE_ETH
    AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH
  ].freeze
  HARD_CAP_KEYS = %w[
    AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH
    AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD
    AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH
    AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD
    AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH
  ].freeze
  VENUE_CAP_KEYS = HedgeVenues::SUPPORTED_KEYS.flat_map do |venue|
    prefix = venue.upcase
    [
      "#{prefix}_MAX_SHORT_ETH",
      "#{prefix}_MAX_ORDER_SIZE_ETH",
      "#{prefix}_MAX_NOTIONAL_USD"
    ]
  end.freeze
  ALLOWED_KEYS = (DEFAULT_KEYS + GLOBAL_CAP_KEYS + HARD_CAP_KEYS + VENUE_CAP_KEYS).freeze

  Result = Data.define(:ok, :setting, :errors, :audit)
  Value = Data.define(:key, :value, :source, :raw_value) do
    def configured?
      value.present?
    end
  end

  def self.allowed_key?(key)
    ALLOWED_KEYS.include?(key.to_s)
  end

  def self.numeric_key?(key)
    allowed_key?(key) && key.to_s != "DEFAULT_HEDGE_EXECUTION_VENUE"
  end

  def self.hard_key?(key)
    HARD_CAP_KEYS.include?(key.to_s)
  end

  def self.valid_value?(key, value)
    if key.to_s == "DEFAULT_HEDGE_EXECUTION_VENUE"
      HedgeVenues.supported?(value)
    else
      decimal = decimal(value)
      decimal.present? && decimal.positive?
    end
  end

  def self.get(key, env: ENV)
    setting = RiskSetting.find_by(key: key)
    return Value.new(key, decimal_if_numeric(key, setting.value), "DB setting", setting.value) if setting

    raw = env[key].presence
    return Value.new(key, decimal_if_numeric(key, raw), "env", raw) if raw.present?

    Value.new(key, nil, "not configured", nil)
  end

  def self.cap_for(venue:, kind:, env: ENV)
    keys = cap_keys(venue: venue, kind: kind)
    keys.each do |key|
      value = get(key, env: env)
      return value if value.configured?
    end

    Value.new(keys.first, nil, "not configured", nil)
  end

  def self.list(env: ENV)
    ALLOWED_KEYS.map { |key| get(key, env: env) }
  end

  def self.default_hedge_venue(env: ENV)
    configured = get("DEFAULT_HEDGE_EXECUTION_VENUE", env: env).raw_value
    HedgeVenues.supported?(configured) ? HedgeVenues.normalize(configured) : HedgeVenues.default_supported(env: env)
  end

  def self.set!(key:, value:, updated_by: nil, reason: nil, confirmation: nil, allow_mixed_recommendation_confirmation: false)
    key = key.to_s
    return Result.new(false, nil, [ "invalid risk setting key" ], nil) unless allowed_key?(key)
    return Result.new(false, nil, [ "invalid risk setting value" ], nil) unless valid_value?(key, value)

    current = RiskSetting.find_by(key: key)
    old_value = current&.value
    errors = confirmation_errors(
      key: key,
      old_value: old_value,
      new_value: value.to_s,
      confirmation: confirmation,
      allow_mixed_recommendation_confirmation: allow_mixed_recommendation_confirmation
    )
    errors.concat(hard_ceiling_validation_errors(key, value.to_s))
    return Result.new(false, current, errors, nil) if errors.present?

    audit = nil
    setting = nil
    ActiveRecord::Base.transaction do
      setting = current || RiskSetting.new(key: key)
      setting.assign_attributes(value: value.to_s, updated_by: updated_by, reason: reason)
      setting.save!
      audit = RiskSettingAudit.create!(key: key, old_value: old_value, new_value: value.to_s, updated_by: updated_by, reason: reason)
    end
    Result.new(true, setting, [], audit)
  end

  def self.cap_keys(venue:, kind:)
    prefix = HedgeVenues.normalize(venue).upcase
    case kind.to_sym
    when :short_eth
      [ "#{prefix}_MAX_SHORT_ETH", "AERODROME_MAX_SHORT_ETH" ]
    when :order_size_eth
      [ "#{prefix}_MAX_ORDER_SIZE_ETH", "AERODROME_MAX_ORDER_SIZE_ETH" ]
    when :notional_usd
      [ "#{prefix}_MAX_NOTIONAL_USD", "AERODROME_MAX_NOTIONAL_USD", "AERODROME_MAX_SHORT_NOTIONAL_USD" ]
    when :total_hedge_eth
      [ "AERODROME_MAX_TOTAL_HEDGE_ETH", "AERODROME_MAX_SHORT_ETH" ]
    else
      []
    end
  end

  def self.hard_ceiling_for(kind:, env: ENV)
    key = hard_key_for(kind)
    get(key, env: env)
  end

  def self.hard_key_for(kind)
    case kind.to_sym
    when :short_eth
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH"
    when :order_size_eth
      "AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH"
    when :notional_usd
      "AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD"
    when :short_notional_usd
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD"
    when :emergency_close_eth
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH"
    end
  end

  def self.runtime_kind_for_key(key)
    key = key.to_s
    return :emergency_close_eth if key == "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
    return :order_size_eth if key.end_with?("MAX_ORDER_SIZE_ETH")
    return :short_notional_usd if key == "AERODROME_MAX_SHORT_NOTIONAL_USD"
    return :notional_usd if key.end_with?("MAX_NOTIONAL_USD")
    :short_eth if key.end_with?("MAX_SHORT_ETH") || key == "AERODROME_MAX_TOTAL_HEDGE_ETH"
  end

  def self.confirmation_errors(key:, old_value:, new_value:, confirmation:, allow_mixed_recommendation_confirmation: false)
    return [] unless numeric_key?(key)

    old_decimal = decimal(old_value)
    new_decimal = decimal(new_value)
    return [ "invalid risk setting value" ] unless new_decimal&.positive?

    increased = old_decimal.nil? || new_decimal > old_decimal
    required = if hard_key?(key) && increased
      HARD_INCREASE_CONFIRMATION
    elsif increased
      INCREASE_CONFIRMATION
    else
      DECREASE_CONFIRMATION
    end
    valid_confirmation = confirmation.to_s == required ||
      (increased && !hard_key?(key) && confirmation.to_s == HARD_INCREASE_CONFIRMATION) ||
      (!increased && allow_mixed_recommendation_confirmation && [ INCREASE_CONFIRMATION, HARD_INCREASE_CONFIRMATION ].include?(confirmation.to_s))
    errors = []
    errors << "confirmation must equal #{required}" unless valid_confirmation
    errors << "advanced override required for unusually high cap" if absurd_cap?(key, new_decimal) && confirmation.to_s != INCREASE_CONFIRMATION
    errors
  end

  def self.hard_ceiling_validation_errors(key, value)
    return [] if hard_key?(key)
    return [] unless numeric_key?(key)

    decimal = decimal(value)
    return [] unless decimal

    errors = []
    kind = runtime_kind_for_key(key)
    hard = hard_ceiling_for(kind: kind) if kind
    if hard&.value.present? && decimal > hard.value
      errors << "Cannot set #{human_label(key)} to #{decimal.to_s('F')} #{unit_for(key)} because #{human_label(hard.key).downcase} is #{hard.value.to_s('F')} #{unit_for(hard.key)}. Raise the production hard ceiling first or reduce the LP size."
    end

    if key == "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      max_short = get("AERODROME_MAX_SHORT_ETH")
      if max_short.value.present? && decimal < max_short.value
        errors << "Cannot set Emergency close max ETH below AERODROME_MAX_SHORT_ETH. Emergency close limit must be at least the maximum hedge size."
      end
    end
    errors
  end

  def self.human_label(key)
    case key.to_s
    when "AERODROME_MAX_SHORT_ETH" then "Global max short size"
    when "ETHEREAL_MAX_SHORT_ETH" then "Ethereal max short size"
    when "NADO_MAX_SHORT_ETH" then "Nado max short size"
    when "EXTENDED_MAX_SHORT_ETH" then "Extended max short size"
    when "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" then "Production hard max short size"
    when "AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH" then "Production hard max order size"
    when "AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD" then "Production hard max notional"
    when "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" then "Production hard max short notional"
    when "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" then "Production hard emergency close max"
    when "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" then "Emergency close max ETH"
    else key.to_s.humanize
    end
  end

  def self.unit_for(key)
    key.to_s.end_with?("USD") ? "USD" : "ETH"
  end

  def self.absurd_cap?(key, value)
    return value > ABSURD_NOTIONAL_USD if key.end_with?("NOTIONAL_USD")
    return value > ABSURD_ORDER_ETH if key.end_with?("ORDER_SIZE_ETH")

    value > ABSURD_CAP_ETH
  end

  def self.decimal(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def self.decimal_if_numeric(key, value)
    numeric_key?(key) ? decimal(value) : value
  end
end
