class OperationalSettings
  ENABLE_CONFIRMATIONS = {
    "ethereal" => "I_UNDERSTAND_THIS_ENABLES_LIVE_ETHEREAL_AUTO",
    "nado" => "I_UNDERSTAND_THIS_ENABLES_LIVE_NADO_AUTO",
    "extended" => "I_UNDERSTAND_THIS_ENABLES_LIVE_EXTENDED_AUTO"
  }.freeze
  DISABLE_CONFIRMATIONS = {
    "ethereal" => "I_UNDERSTAND_THIS_DISABLES_ETHEREAL_AUTO",
    "nado" => "I_UNDERSTAND_THIS_DISABLES_NADO_AUTO",
    "extended" => "I_UNDERSTAND_THIS_DISABLES_EXTENDED_AUTO"
  }.freeze
  DISABLE_ALL_CONFIRMATION = "I_UNDERSTAND_THIS_DISABLES_ALL_AUTO".freeze

  AUTO_KEYS_BY_VENUE = {
    "ethereal" => "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED",
    "nado" => "AERODROME_NADO_AUTO_REBALANCE_ENABLED",
    "extended" => "EXTENDED_AUTO_REBALANCE_ENABLED"
  }.freeze
  MIGRATION_KEYS = %w[
    MIGRATION_AUTO_ENABLED
    MIGRATION_LIVE_ENABLED
    MIGRATION_MANUAL_LIVE_CANARY_ENABLED
    MIGRATION_FULL_ALLOWED
    MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED
    MIGRATION_TARGET_FIRST_TARGET_REVERT_ENABLED
    EXTENDED_VENUE_QUARANTINED
    EXTENDED_VENUE_PROBATION
    MIGRATION_RANDOM_ROTATION_LIVE_ENABLED
    AERODROME_NADO_LIVE_MIGRATION_ENABLED
    AERODROME_NADO_HEDGE_LIVE_ENABLED
  ].freeze
  ROUTE_KEYS_BY_ROUTE = {
    "extended->nado" => "MIGRATION_ROUTE_EXTENDED_TO_NADO_ENABLED",
    "ethereal->nado" => "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED",
    "nado->extended" => "MIGRATION_ROUTE_NADO_TO_EXTENDED_ENABLED",
    "nado->ethereal" => "MIGRATION_ROUTE_NADO_TO_ETHEREAL_ENABLED",
    "extended->ethereal" => "MIGRATION_ROUTE_EXTENDED_TO_ETHEREAL_ENABLED",
    "ethereal->extended" => "MIGRATION_ROUTE_ETHEREAL_TO_EXTENDED_ENABLED"
  }.freeze
  ROUTE_KEYS = ROUTE_KEYS_BY_ROUTE.values.freeze
  ROUTE_STRATEGY_KEYS_BY_ROUTE = {
    "extended->nado" => "MIGRATION_ROUTE_EXTENDED_TO_NADO_STRATEGY",
    "ethereal->nado" => "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY",
    "nado->extended" => "MIGRATION_ROUTE_NADO_TO_EXTENDED_STRATEGY",
    "nado->ethereal" => "MIGRATION_ROUTE_NADO_TO_ETHEREAL_STRATEGY",
    "extended->ethereal" => "MIGRATION_ROUTE_EXTENDED_TO_ETHEREAL_STRATEGY",
    "ethereal->extended" => "MIGRATION_ROUTE_ETHEREAL_TO_EXTENDED_STRATEGY"
  }.freeze
  ROUTE_STRATEGY_KEYS = ROUTE_STRATEGY_KEYS_BY_ROUTE.values.freeze
  ROUTE_STRATEGIES = %w[target_first source_first manual_only disabled disabled_pending_latency_proof].freeze
  RUNTIME_GATE_KEYS = (AUTO_KEYS_BY_VENUE.values + MIGRATION_KEYS).freeze
  ROUTE_POLICY_KEYS = (ROUTE_KEYS + ROUTE_STRATEGY_KEYS).freeze
  BOOLEAN_KEYS = (RUNTIME_GATE_KEYS + ROUTE_KEYS).freeze
  ALLOWED_KEYS = (BOOLEAN_KEYS + ROUTE_STRATEGY_KEYS).freeze

  Result = Data.define(:ok, :setting, :errors, :audit)
  Value = Data.define(:key, :enabled, :source, :raw_value)

  def self.allowed_key?(key)
    ALLOWED_KEYS.include?(key.to_s)
  end

  def self.valid_value?(value)
    %w[true false].include?(normalize_value(value))
  end

  def self.valid_value_for_key?(key, value)
    if ROUTE_STRATEGY_KEYS.include?(key.to_s)
      ROUTE_STRATEGIES.include?(value.to_s)
    else
      valid_value?(value)
    end
  end

  def self.get(key, env: ENV)
    key = key.to_s
    setting = OperationalSetting.find_by(key: key)
    return Value.new(key, truthy?(setting.value), "DB setting", setting.value) if setting

    raw = env[key].presence
    return Value.new(key, truthy?(raw), "env", raw) if raw.present?

    Value.new(key, false, "default false", nil)
  end

  def self.enabled?(key, env: ENV)
    return ActiveModel::Type::Boolean.new.cast(env[key]) unless allowed_key?(key)

    get(key, env: env).enabled
  end

  def self.set!(key:, enabled:, updated_by: nil, reason: nil)
    key = key.to_s
    return Result.new(false, nil, [ "invalid operational setting key" ], nil) unless allowed_key?(key)
    value = ROUTE_STRATEGY_KEYS.include?(key) ? enabled.to_s : normalize_value(enabled)
    return Result.new(false, nil, [ "invalid operational setting value" ], nil) unless valid_value_for_key?(key, value)

    current = OperationalSetting.find_by(key: key)
    old_value = current&.value
    setting = nil
    audit = nil
    ActiveRecord::Base.transaction do
      setting = current || OperationalSetting.new(key: key)
      setting.assign_attributes(value: value, updated_by: updated_by, reason: reason)
      setting.save!
      audit = OperationalSettingAudit.create!(
        key: key,
        old_value: old_value,
        new_value: value,
        updated_by: updated_by,
        reason: reason
      )
    end
    Result.new(true, setting, [], audit)
  end

  def self.list(env: ENV)
    ALLOWED_KEYS.map { |key| get(key, env: env) }
  end

  def self.auto_key_for(venue)
    AUTO_KEYS_BY_VENUE[HedgeVenues.normalize(venue)]
  end

  def self.route_key_for(from, to)
    ROUTE_KEYS_BY_ROUTE["#{HedgeVenues.normalize(from)}->#{HedgeVenues.normalize(to)}"]
  end

  def self.route_strategy_key_for(from, to)
    ROUTE_STRATEGY_KEYS_BY_ROUTE["#{HedgeVenues.normalize(from)}->#{HedgeVenues.normalize(to)}"]
  end

  def self.enable_confirmation_for(venue)
    ENABLE_CONFIRMATIONS.fetch(HedgeVenues.normalize(venue))
  end

  def self.disable_confirmation_for(venue)
    DISABLE_CONFIRMATIONS.fetch(HedgeVenues.normalize(venue))
  end

  def self.truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def self.normalize_value(value)
    ActiveModel::Type::Boolean.new.cast(value).to_s
  end
  private_class_method :truthy?, :normalize_value
end
