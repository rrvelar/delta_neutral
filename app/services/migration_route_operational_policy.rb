class MigrationRouteOperationalPolicy
  TEMPORARY_DISABLED_REASON = "temporarily disabled pending latency fix/proof".freeze
  MANUAL_ONLY_REASON = "manual-only pending latency proof".freeze
  CHANGE_CONFIRMATION = "I_UNDERSTAND_THIS_CHANGES_ROUTE_POLICY".freeze
  RESTORE_CONFIRMATION = "I_UNDERSTAND_THIS_RESTORES_ROUTE_POLICIES".freeze
  DEFAULT_STRATEGIES = {
    "extended->ethereal" => "target_first",
    "ethereal->extended" => "target_first",
    "nado->extended" => "target_first",
    "nado->ethereal" => "target_first",
    "extended->nado" => "source_first",
    "ethereal->nado" => "source_first"
  }.freeze
  Result = Data.define(:ok, :errors, :settings, :payload)

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

  def report
    routes = OperationalSettings::ROUTE_KEYS_BY_ROUTE.keys.map do |route|
      from, to = route.split("->")
      route_status(from: from, to: to)
    end
    disabled = routes.reject { |route| route.fetch(:production_execution_enabled) }
    {
      route_policy_health: health_for(routes),
      routes: routes,
      disabled_routes: disabled.map { |route| route.fetch(:route) },
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    }
  end

  def restore_defaults!(confirmation:, updated_by: nil)
    return result(false, [ "confirmation must equal #{RESTORE_CONFIRMATION}" ], []) unless confirmation.to_s == RESTORE_CONFIRMATION

    applied = []
    ActiveRecord::Base.transaction do
      DEFAULT_STRATEGIES.each do |route, strategy|
        from, to = route.split("->")
        applied << OperationalSettings.set!(
          key: OperationalSettings.route_key_for(from, to),
          enabled: true,
          updated_by: updated_by,
          reason: "restore default migration route policy"
        )
        applied << OperationalSettings.set!(
          key: OperationalSettings.route_strategy_key_for(from, to),
          enabled: strategy,
          updated_by: updated_by,
          reason: "restore default migration route strategy"
        )
      end
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, errors, applied.select(&:ok).map(&:setting))
  end

  def set_route!(from:, to:, enabled:, strategy:, confirmation:, updated_by: nil)
    return result(false, [ "confirmation must equal #{CHANGE_CONFIRMATION}" ], []) unless confirmation.to_s == CHANGE_CONFIRMATION

    from = HedgeVenues.normalize(from)
    to = HedgeVenues.normalize(to)
    route_key = OperationalSettings.route_key_for(from, to)
    strategy_key = OperationalSettings.route_strategy_key_for(from, to)
    return result(false, [ "unknown migration route" ], []) unless route_key && strategy_key

    strategy = strategy.to_s.presence || default_strategy(to)
    return result(false, [ "invalid route strategy" ], []) unless OperationalSettings::ROUTE_STRATEGIES.include?(strategy)

    applied = []
    ActiveRecord::Base.transaction do
      applied << OperationalSettings.set!(
        key: route_key,
        enabled: enabled,
        updated_by: updated_by,
        reason: "set migration route policy"
      )
      applied << OperationalSettings.set!(
        key: strategy_key,
        enabled: strategy,
        updated_by: updated_by,
        reason: "set migration route strategy"
      )
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, errors, applied.select(&:ok).map(&:setting))
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

  def health_for(routes)
    return "all_disabled" if routes.all? { |route| !route.fetch(:production_execution_enabled) }
    return "partial_disabled" if routes.any? { |route| !route.fetch(:production_execution_enabled) }

    "ok"
  end

  def result(ok, errors, settings)
    Result.new(
      ok,
      errors,
      settings,
      report.merge(settings: settings.map { |setting| { key: setting.key, value: setting.value } })
    )
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
