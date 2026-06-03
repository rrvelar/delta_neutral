class SetupDefaults
  def initialize(env: ENV)
    @env = env
  end

  def report
    {
      supported_hedge_venues: HedgeVenues::SUPPORTED_KEYS,
      default_hedge_execution_venue: HedgeVenues.default_supported(env: env),
      risk_cap_settings: risk_cap_settings,
      env_example: "DEFAULT_HEDGE_EXECUTION_VENUE=#{HedgeVenues.default_supported(env: env)}",
      first_import_active_by_default: true,
      duplicate_import_behavior: "same user/wallet/external_id/pool updates the existing position instead of creating a duplicate",
      operator_notes: [
        "Wallet import does not activate archived positions.",
        "Dashboard shows active positions only.",
        "Positions can be activated or archived from the Positions UI.",
        "Archive only changes the app record; it does not close the on-chain LP or perps."
      ],
      risk_settings_ui: "Settings -> Risk Limits",
      restart_required_for_ui_risk_changes: false,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :env

  def risk_cap_settings
    return env_risk_cap_settings unless defined?(RiskSetting)

    RiskSettings::ALLOWED_KEYS.map do |key|
      value = RiskSettings.get(key, env: env)
      {
        key: key,
        value: value.raw_value || "not configured",
        source: value.source
      }
    end
  rescue
    env_risk_cap_settings
  end

  def env_risk_cap_settings
    RiskSettings::ALLOWED_KEYS.map do |key|
      raw = env[key]
      configured = !raw.nil? && !raw.to_s.empty?
      { key: key, value: configured ? raw : "not configured", source: configured ? "env" : "not configured" }
    end
  end
end
