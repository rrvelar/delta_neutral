class MigrationRouteOperationalPolicy
  TEMPORARY_DISABLED_REASON = "temporarily disabled pending latency fix/proof".freeze
  MANUAL_ONLY_REASON = "manual-only pending latency proof".freeze

  def initialize(env: ENV)
    @env = env
  end

  def route_enabled?(from:, to:)
    route_status(from: from, to: to).fetch(:production_execution_enabled)
  end

  def route_strategy(from:, to:)
    route_status(from: from, to: to).fetch(:strategy)
  end

  def route_status(from:, to:)
    from = HedgeVenues.normalize(from)
    to = HedgeVenues.normalize(to)
    route = "#{from}->#{to}"
    key = OperationalSettings.route_key_for(from, to)
    strategy_key = OperationalSettings.route_strategy_key_for(from, to)
    legacy_enabled = explicit_boolean(key)
    strategy = explicit_strategy(strategy_key) || default_strategy(to)
    strategy = "disabled" if legacy_enabled == false
    production_enabled = strategy.in?(%w[target_first source_first])
    reason = production_enabled ? nil : disabled_reason(strategy)
    {
      route: route,
      from_venue: from,
      to_venue: to,
      key: key,
      strategy_key: strategy_key,
      strategy: strategy,
      migration_sequence: strategy.in?(%w[target_first source_first]) ? strategy : nil,
      enabled: production_enabled,
      production_execution_enabled: production_enabled,
      source: explicit_strategy(strategy_key).nil? && legacy_enabled.nil? ? "default" : "configured",
      disabled_reason: reason,
      temporary_quarantine: !production_enabled || nado_target_pending_latency_proof?(to),
      proof_required: to == "nado" ? "successful fast live latency proof" : nil,
      blocker: reason ? "#{route} unavailable for production random: #{reason}" : nil
    }.compact
  end

  private

  attr_reader :env

  def explicit_boolean(key)
    return nil unless key

    setting = OperationalSetting.find_by(key: key)
    return ActiveModel::Type::Boolean.new.cast(setting.value) if setting

    raw = env[key].presence
    return nil if raw.nil?

    ActiveModel::Type::Boolean.new.cast(raw)
  end

  def explicit_strategy(key)
    return nil unless key

    setting = OperationalSetting.find_by(key: key)
    raw = setting&.value.presence || env[key].presence
    return nil if raw.blank?

    value = raw.to_s
    return value if OperationalSettings::ROUTE_STRATEGIES.include?(value)

    nil
  end

  def default_strategy(to)
    to == "nado" ? "source_first" : "target_first"
  end

  def disabled_reason(strategy)
    return MANUAL_ONLY_REASON if strategy == "manual_only"
    return TEMPORARY_DISABLED_REASON if strategy == "disabled_pending_latency_proof"

    "route disabled by operational setting"
  end

  def nado_target_pending_latency_proof?(to)
    to == "nado"
  end
end
