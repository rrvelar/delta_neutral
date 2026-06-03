# Manages per-user Hyperliquid trading settings (leverage and margin mode).
class SettingsController < ApplicationController
  # GET /settings/edit
  def edit
    @setting = Current.user.setting || Current.user.build_setting
    load_risk_settings
  end

  def update_risk
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
      risk_group("Global fallback limits", %w[
        AERODROME_MAX_SHORT_ETH
        AERODROME_MAX_ORDER_SIZE_ETH
        AERODROME_MAX_NOTIONAL_USD
        AERODROME_MAX_SHORT_NOTIONAL_USD
        AERODROME_MAX_TOTAL_HEDGE_ETH
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

    if key == "DEFAULT_HEDGE_EXECUTION_VENUE"
      venue = RiskSettings.default_hedge_venue
      return { text: "Not configured. Currently using supported venue fallback #{venue}.", state: "Optional, using fallback." }
    end

    fallback = fallback_for_key(key)
    return fallback if fallback

    if key == "AERODROME_MAX_TOTAL_HEDGE_ETH"
      return { text: "Not configured. This optional total hedge cap is not currently required for the selected venue.", state: "Optional and unused." }
    end

    { text: "Not configured. Live hedge is blocked until this cap or an applicable fallback is set.", state: "Required before live." }
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

    venue = HedgeVenues.normalize(@production_position.hedge.execution_venue)
    target = @production_snapshot&.target_short_eth || (@production_position.asset0_amount && @production_position.hedge.target ? @production_position.asset0_amount * @production_position.hedge.target : nil)
    return unless target

    short_cap = RiskSettings.cap_for(venue: venue, kind: :short_eth)
    suggested = (target * BigDecimal("1.25") * 10).ceil / BigDecimal("10")
    {
      position: @production_position,
      venue: venue,
      venue_name: HedgeVenues.label(venue),
      target_short_eth: target,
      cap_key: short_cap.key,
      cap_value: short_cap.raw_value,
      cap_source: short_cap.source,
      minimum_required_cap: target,
      suggested_cap: suggested,
      relevant_setting_key: "#{venue.upcase}_MAX_SHORT_ETH",
      blocked: short_cap.value.present? ? target > short_cap.value : true
    }
  end

  def format_risk_value(value, unit)
    return "not configured" if value.blank?
    return value.to_s if unit == "venue"

    "#{value} #{unit}"
  end

  def env_enabled?(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end
end
