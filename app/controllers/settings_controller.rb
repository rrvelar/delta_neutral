# Manages per-user Hyperliquid trading settings (leverage and margin mode).
class SettingsController < ApplicationController
  # GET /settings/edit
  def edit
    @setting = Current.user.setting || Current.user.build_setting
    load_risk_settings
  end

  def update_risk
    if params[:apply_recommended].present?
      return apply_recommended_risk_limits
    elsif params[:save_changed].present?
      return save_changed_risk_settings
    end

    key = params[:key].presence || params[:risk_key].presence
    result = RiskSettings.set!(
      key: key,
      value: params[:value].presence || params.dig(:risk_values, key),
      updated_by: Current.user,
      reason: params[:reason].presence || params.dig(:risk_reasons, key),
      confirmation: params[:confirmation]
    )
    if result.ok
      redirect_to edit_settings_path(anchor: "risk-settings"), notice: "Risk setting #{result.setting.key} updated from #{result.audit.old_value || 'not configured'} to #{result.setting.value}. No orders or signatures were created."
    else
      @setting = Current.user.setting || Current.user.build_setting
      load_risk_settings
      @risk_setting_errors = result.errors
      render :edit, status: :unprocessable_entity
    end
  end

  # PATCH /settings
  def update
    @setting = Current.user.setting || Current.user.build_setting

    if @setting.update(setting_params)
      redirect_to edit_settings_path, notice: "Settings saved."
    else
      load_risk_settings
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def apply_recommended_risk_limits
    position = Current.user.positions.find(params[:position_id])
    result = RiskLimitRecommendation.new(position: position, venue: params[:venue]).apply!(
      updated_by: Current.user,
      reason: params[:reason],
      confirmation: params[:confirmation]
    )
    if result.ok
      redirect_to edit_settings_path(anchor: "risk-settings"), notice: "Recommended risk limits applied. No orders or signatures were created."
    else
      render_risk_error(result.errors)
    end
  end

  def save_changed_risk_settings
    errors = []
    applied = []
    values = params[:risk_values] || {}
    reasons = params[:risk_reasons] || {}
    values.each do |key, value|
      next if value.blank?

      current = RiskSettings.get(key)
      next if current.raw_value.to_s == value.to_s

      result = RiskSettings.set!(
        key: key,
        value: value,
        updated_by: Current.user,
        reason: reasons[key],
        confirmation: params[:confirmation]
      )
      result.ok ? applied << key : errors.concat(result.errors)
    end

    if errors.present?
      render_risk_error(errors.uniq)
    else
      redirect_to edit_settings_path(anchor: "risk-settings"), notice: "#{applied.size} risk setting#{'s' unless applied.one?} updated. No orders or signatures were created."
    end
  end

  def render_risk_error(errors)
    @setting = Current.user.setting || Current.user.build_setting
    load_risk_settings
    @risk_setting_errors = errors
    render :edit, status: :unprocessable_entity
  end

  def load_risk_settings
    @production_position = DashboardVisiblePositions.new(user: Current.user).call.find { |position| position.hedge&.active? }
    @production_snapshot = @production_position&.position_dashboard_snapshot
    @risk_settings = RiskSettings.list
    @risk_settings_by_key = @risk_settings.index_by(&:key)
    @risk_setting_groups = risk_setting_groups
    @risk_recommendation = risk_recommendation
    @venue_runtime_summary = {
      production_venue: @production_position&.hedge ? HedgeVenues.label(@production_position.hedge.execution_venue) : "Unknown",
      extended_live_enabled: env_enabled?("EXTENDED_LIVE_ENABLED"),
      extended_auto_enabled: env_enabled?("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_enabled: env_enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_enabled: env_enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
      signer_status: @production_snapshot&.signer_status.presence || "unknown"
    }
  end

  def setting_params
    params.require(:setting).permit(:hyperliquid_leverage, :hyperliquid_cross_margin)
  end

  def risk_setting_groups
    [
      risk_group("Default venue", %w[DEFAULT_HEDGE_EXECUTION_VENUE]),
      risk_group("Production hard ceilings", RiskSettings::HARD_CAP_KEYS),
      risk_group("Global fallback limits", %w[
        AERODROME_MAX_SHORT_ETH
        AERODROME_MAX_ORDER_SIZE_ETH
        AERODROME_MAX_NOTIONAL_USD
        AERODROME_MAX_SHORT_NOTIONAL_USD
        AERODROME_MAX_TOTAL_HEDGE_ETH
        AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH
      ]),
      risk_group("Ethereal limits", %w[ETHEREAL_MAX_SHORT_ETH ETHEREAL_MAX_ORDER_SIZE_ETH ETHEREAL_MAX_NOTIONAL_USD]),
      risk_group("Nado limits", %w[NADO_MAX_SHORT_ETH NADO_MAX_ORDER_SIZE_ETH NADO_MAX_NOTIONAL_USD]),
      risk_group("Extended limits", %w[EXTENDED_MAX_SHORT_ETH EXTENDED_MAX_ORDER_SIZE_ETH EXTENDED_MAX_NOTIONAL_USD])
    ]
  end

  def risk_group(title, keys)
    { title: title, rows: keys.map { |key| risk_row(key) } }
  end

  def risk_row(key)
    setting = @risk_settings_by_key.fetch(key)
    meta = risk_metadata(key)
    effective = effective_risk_value(key)
    {
      key: key,
      label: meta.fetch(:label),
      description: meta.fetch(:description),
      unit: meta.fetch(:unit),
      helper: meta.fetch(:helper),
      current: current_setting_text(setting, meta.fetch(:unit)),
      source: setting.source,
      effective: effective.fetch(:text),
      state: effective.fetch(:state),
      raw_value: setting.raw_value
    }
  end

  def risk_metadata(key)
    venue = key.split("_").first.to_s.downcase
    case key
    when "DEFAULT_HEDGE_EXECUTION_VENUE"
      {
        label: "Default hedge venue",
        description: "Which supported venue is selected by default for new positions.",
        unit: "venue",
        helper: "Allowed values: nado, ethereal, extended."
      }
    when "AERODROME_MAX_SHORT_ETH"
      {
        label: "Global max short size, ETH",
        description: "Maximum total hedge short size allowed for a position if no venue-specific cap is set.",
        unit: "ETH",
        helper: "Enter a positive decimal ETH amount, e.g. 2.2."
      }
    when "AERODROME_MAX_ORDER_SIZE_ETH"
      {
        label: "Global max order size, ETH",
        description: "Maximum single hedge order size if no venue-specific order cap is set.",
        unit: "ETH",
        helper: "Enter a positive decimal ETH amount, e.g. 0.5."
      }
    when "AERODROME_MAX_NOTIONAL_USD", "AERODROME_MAX_SHORT_NOTIONAL_USD"
      {
        label: key == "AERODROME_MAX_NOTIONAL_USD" ? "Global max notional, USD" : "Global max short notional, USD",
        description: "Maximum hedge notional allowed when no venue-specific notional cap is set.",
        unit: "USD",
        helper: "Enter a positive USD amount, e.g. 5000."
      }
    when "AERODROME_MAX_TOTAL_HEDGE_ETH"
      {
        label: "Global max total hedge, ETH",
        description: "Optional portfolio-level hedge cap used by total hedge checks when enabled.",
        unit: "ETH",
        helper: "Enter a positive decimal ETH amount, e.g. 5."
      }
    when "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      {
        label: "Emergency close max size, ETH",
        description: "Maximum ETH short the emergency close tool is allowed to close. It must be at least the max hedge size.",
        unit: "ETH",
        helper: "Enter a positive decimal ETH amount at least as large as the max short cap."
      }
    when *RiskSettings::HARD_CAP_KEYS
      {
        label: RiskSettings.human_label(key),
        description: hard_ceiling_description(key),
        unit: RiskSettings.unit_for(key),
        helper: "Hard ceiling increases require #{RiskSettings::HARD_INCREASE_CONFIRMATION}."
      }
    else
      venue_label = HedgeVenues.label(venue)
      cap_type = key.include?("ORDER_SIZE") ? "max order size" : (key.include?("NOTIONAL") ? "max notional" : "max short size")
      unit = key.include?("NOTIONAL") ? "USD" : "ETH"
      {
        label: "#{venue_label} #{cap_type}, #{unit}",
        description: "#{cap_type.humanize} allowed on #{venue_label}. Venue-specific values override global Aerodrome fallbacks.",
        unit: unit,
        helper: unit == "USD" ? "Enter a positive USD amount, e.g. 5000." : "Enter a positive decimal ETH amount, e.g. 2.2."
      }
    end
  end

  def effective_risk_value(key)
    setting = @risk_settings_by_key.fetch(key)
    return { text: "Effective value: #{format_risk_value(setting.raw_value, risk_metadata(key).fetch(:unit))}.", state: "Configured directly." } if setting.raw_value.present?

    if RiskSettings.hard_key?(key)
      return { text: "Missing hard ceiling. Live hedge remains blocked until this production ceiling is set.", state: "Production hard ceiling." }
    elsif key == "DEFAULT_HEDGE_EXECUTION_VENUE"
      venue = RiskSettings.default_hedge_venue
      return { text: "Not configured. Currently using supported venue fallback #{venue}.", state: "Optional, using fallback." }
    end

    fallback = fallback_for_key(key)
    return fallback if fallback

    if key == "AERODROME_MAX_TOTAL_HEDGE_ETH"
      return { text: "Not configured. This optional total hedge cap is not currently required for the selected venue.", state: "Optional and unused." }
    end

    { text: "Not configured. Live hedge is blocked until this cap or an applicable fallback is set.", state: runtime_validity_state(key) }
  end

  def fallback_for_key(key)
    venue, kind = venue_and_kind_for_key(key)
    return unless venue && kind

    cap = RiskSettings.cap_for(venue: venue, kind: kind)
    return if cap.key == key || cap.raw_value.blank?

    unit = key.include?("NOTIONAL") ? "USD" : "ETH"
    { text: "Not configured. Currently using fallback #{cap.key}=#{format_risk_value(cap.raw_value, unit)}.", state: "Optional, using fallback." }
  end

  def venue_and_kind_for_key(key)
    return unless key.match?(/\A(ETHEREAL|NADO|EXTENDED)_/)

    venue = key.split("_").first.downcase
    kind = if key.include?("ORDER_SIZE")
      :order_size_eth
    elsif key.include?("NOTIONAL")
      :notional_usd
    else
      :short_eth
    end
    [ venue, kind ]
  end

  def current_setting_text(setting, unit)
    return "#{format_risk_value(setting.raw_value, unit)} from #{setting.source}" if setting.raw_value.present?

    "Not configured"
  end

  def risk_recommendation
    return unless @production_position&.hedge

    RiskLimitRecommendation.new(position: @production_position, venue: @production_position.hedge.execution_venue).report
  end

  def format_risk_value(value, unit)
    return "not configured" if value.blank?
    return value.to_s if unit == "venue"

    "#{value} #{unit}"
  end

  def hard_ceiling_description(key)
    case key
    when "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH"
      "Absolute maximum total hedge short allowed by this deployment. Runtime max short caps cannot exceed this value."
    when "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH"
      "Absolute maximum emergency close size. Emergency close runtime cap cannot exceed this value."
    else
      "Absolute production safety ceiling. Runtime caps in the matching category cannot exceed this value."
    end
  end

  def runtime_validity_state(key)
    value = @risk_settings_by_key.fetch(key).value
    errors = RiskSettings.hard_ceiling_validation_errors(key, value&.to_s)
    errors.present? ? "Invalid: above hard ceiling." : "Required before live."
  end

  def env_enabled?(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end
end
