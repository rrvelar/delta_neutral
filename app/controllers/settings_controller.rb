# Manages per-user Hyperliquid trading settings (leverage and margin mode).
class SettingsController < ApplicationController
  # GET /settings/edit
  def edit
    @setting = Current.user.setting || Current.user.build_setting
    @production_position = DashboardVisiblePositions.new(user: Current.user).call.find { |position| position.hedge&.active? }
    @production_snapshot = @production_position&.position_dashboard_snapshot
    @venue_runtime_summary = {
      production_venue: @production_position&.hedge ? HedgeVenues.label(@production_position.hedge.execution_venue) : "Unknown",
      extended_live_enabled: env_enabled?("EXTENDED_LIVE_ENABLED"),
      extended_auto_enabled: env_enabled?("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_enabled: env_enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_enabled: env_enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
      signer_status: @production_snapshot&.signer_status.presence || "unknown"
    }
  end

  # PATCH /settings
  def update
    @setting = Current.user.setting || Current.user.build_setting

    if @setting.update(setting_params)
      redirect_to edit_settings_path, notice: "Settings saved."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def setting_params
    params.require(:setting).permit(:hyperliquid_leverage, :hyperliquid_cross_margin)
  end

  def env_enabled?(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end
end
