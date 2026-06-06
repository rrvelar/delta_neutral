class MigrationRouteOperationalPolicy
  NADO_TARGET_DISABLED_REASON = "Nado target/source-close latency not production-safe".freeze

  def initialize(env: ENV)
    @env = env
  end

  def route_enabled?(from:, to:)
    route_status(from: from, to: to).fetch(:enabled)
  end

  def route_status(from:, to:)
    from = HedgeVenues.normalize(from)
    to = HedgeVenues.normalize(to)
    route = "#{from}->#{to}"
    key = OperationalSettings.route_key_for(from, to)
    explicit = explicit_value(key)
    enabled = explicit.nil? ? default_enabled?(to) : explicit
    reason = enabled ? nil : disabled_reason(from: from, to: to)
    {
      route: route,
      from_venue: from,
      to_venue: to,
      key: key,
      enabled: enabled,
      source: explicit.nil? ? "default" : "configured",
      disabled_reason: reason,
      blocker: reason ? "#{route} disabled: #{reason}" : nil
    }.compact
  end

  private

  attr_reader :env

  def explicit_value(key)
    return nil unless key

    setting = OperationalSetting.find_by(key: key)
    return ActiveModel::Type::Boolean.new.cast(setting.value) if setting

    raw = env[key].presence
    return nil if raw.nil?

    ActiveModel::Type::Boolean.new.cast(raw)
  end

  def default_enabled?(to)
    to != "nado"
  end

  def disabled_reason(from:, to:)
    return NADO_TARGET_DISABLED_REASON if to == "nado"

    "route disabled by operational setting"
  end
end
