# Manages the current user's DeFi positions.
#
# All queries are scoped to {Current.user} to prevent cross-user data access.
class PositionsController < ApplicationController
  # GET /positions
  #
  # Lists all active positions for the current user, eager-loading the
  # associated DEX and hedge records.
  #
  # @return [void]
  def index
    @positions = Current.user.positions.active.includes(:dex, :hedge, wallet: :network)
  end

  def new
    @aerodrome_import_defaults = aerodrome_import_defaults
  end

  def create
    attrs = aerodrome_position_params
    token_id = attrs[:external_id].to_s.strip
    @aerodrome_import_defaults = aerodrome_import_defaults.merge(attrs.to_h.symbolize_keys)

    if token_id.blank?
      flash.now[:alert] = "Token ID is required."
      return render :new, status: :unprocessable_entity
    end

    dex = Dex.find(attrs[:dex_id])
    if Position.active.where(dex: dex, external_id: token_id).exists?
      flash.now[:alert] = "An active Aerodrome position with token ID #{token_id} already exists."
      return render :new, status: :unprocessable_entity
    end

    position = nil
    hedge = nil
    ActiveRecord::Base.transaction do
      if ActiveModel::Type::Boolean.new.cast(attrs[:deactivate_existing_aerodrome_positions])
        Position.active.where(dex: dex).update_all(active: false, updated_at: Time.current)
      end

      position = Position.create!(
        user_id: attrs[:user_id],
        wallet_id: attrs[:wallet_id],
        dex: dex,
        source: Position::SOURCE_AERODROME_DIRECT,
        external_id: token_id,
        pool_address: attrs[:pool_address],
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: BigDecimal("0"),
        asset1_amount: BigDecimal("0"),
        asset0_price_usd: nil,
        asset1_price_usd: nil,
        active: true
      )
      hedge = position.create_hedge!(
        target: attrs[:hedge_target],
        tolerance: attrs[:hedge_tolerance],
        active: true
      )
    end

    sync_warning = nil
    begin
      PositionSyncJob.perform_now(position.id)
    rescue => e
      Rails.logger.warn("Aerodrome import sync failed for position #{position.id}: #{e.class} #{e.message}")
      sync_warning = " Position was created with hedge ##{hedge.id}, but read-only sync failed: #{e.message}"
    end

    redirect_to position_path(position), notice: "Aerodrome LP position imported.#{sync_warning}"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    flash.now[:alert] = "Import failed: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  # GET /positions/:id
  #
  # Displays a single position along with its most recent 50 P&L snapshots
  # and full rebalance history.
  #
  # @return [void]
  def show
    @position = Current.user.positions.includes(:dex, :hedge, wallet: :network).find(params[:id])
    @pnl_snapshots = @position.pnl_snapshots.order(captured_at: :desc).limit(10)
    @rebalances = @position.hedge&.short_rebalances&.order(rebalanced_at: :desc) || ShortRebalance.none
    if @position.dex.name == "aerodrome_slipstream"
      @selected_hedge_venue = HedgeVenues.normalize(params[:hedge_venue])
      @hedge_venue_options = HedgeVenues.options
      @selected_hedge_venue_adapter = HedgeVenues.build(@selected_hedge_venue)
      @latest_aerodrome_weth_rebalance = @position.hedge&.short_rebalances&.where(asset: [ "ETH", "WETH" ])&.order(rebalanced_at: :desc)&.first
      @aerodrome_hedge_proposals = @position.aerodrome_hedge_proposals.latest_first.limit(10)
      @latest_aerodrome_hedge_proposal = @aerodrome_hedge_proposals.first
      safety = AerodromeHedgeProposalSafety.new
      @aerodrome_proposal_safety_results = @aerodrome_hedge_proposals.to_h do |proposal|
        [ proposal.id, safety.evaluate(proposal, current_position: @position) ]
      end
      @aerodrome_rewards_report = aerodrome_rewards_report
      @aerodrome_fees_report = aerodrome_fees_report
      @aerodrome_production_dashboard_status = AerodromeProductionDashboardStatus.new(position: @position).report
      @aerodrome_rebalance_history_status = AerodromeRebalanceHistoryStatus.new(
        position: @position,
        dashboard_status: @aerodrome_production_dashboard_status
      ).report
      @aerodrome_auto_rebalance_status = AerodromeAutoRebalanceStatus.new(
        position: @position,
        dashboard_status: @aerodrome_production_dashboard_status
      ).report
    end
  end

  # POST /positions/:id/sync_now
  #
  # Enqueues a {PositionSyncJob} for the given position and redirects back
  # to the position detail page.
  #
  # @return [void]
  def sync_now
    @position = Current.user.positions.find(params[:id])
    PositionSyncJob.perform_later(@position.id)
    redirect_to position_path(@position), notice: "Position sync queued."
  end

  def hedge_open_preview
    run_dashboard_hedge_action("open", execute: false)
  end

  def hedge_open
    run_dashboard_hedge_action("open", execute: true)
  end

  def hedge_rebalance_preview
    run_dashboard_hedge_action("rebalance", execute: false)
  end

  def hedge_rebalance
    run_dashboard_hedge_action("rebalance", execute: true)
  end

  def hedge_close_preview
    run_dashboard_hedge_action("close", execute: false)
  end

  def hedge_close
    run_dashboard_hedge_action("close", execute: true)
  end

  private

  def run_dashboard_hedge_action(action, execute:)
    position = Current.user.positions.includes(:dex, :hedge).find(params[:id])
    report = AerodromeDashboardHedgeAction.new(
      position: position,
      action: action,
      execute: execute,
      confirmation: params[:dashboard_hedge_confirmation],
      venue: params[:hedge_venue]
    ).report
    level = report.fetch(:status) == "blocked" || report.fetch(:status) == "failed" ? :alert : :notice
    redirect_params = report.fetch(:hedge_venue) == HedgeVenues::DEFAULT ? {} : { hedge_venue: report.fetch(:hedge_venue) }
    redirect_to position_path(position, redirect_params), flash: { level => dashboard_hedge_action_message(report) }
  end

  def dashboard_hedge_action_message(report)
    label = report.fetch(:requested_action).to_s.humanize
    venue = report.fetch(:hedge_venue_name)
    if report.fetch(:blockers).present?
      "#{label} #{report.fetch(:status)} on #{venue}: #{report.fetch(:blockers).join('; ')}"
    elsif report.fetch(:errors).present?
      "#{label} #{report.fetch(:status)} on #{venue}: #{report.fetch(:errors).join('; ')}"
    else
      delta = report[:submitted_delta_eth].presence || "0"
      message = "#{label} #{report.fetch(:status)} on #{venue}. Target #{report[:target_short_eth] || 'unavailable'} ETH, delta #{delta} ETH."
      report.fetch(:warnings).present? ? "#{message} #{report.fetch(:warnings).join('; ')}" : message
    end
  end

  def aerodrome_rewards_report
    unless ENV["AERODROME_REWARDS_ENABLED"].to_s.downcase == "true"
      return {
        status: "not configured",
        gauge_status: "not configured",
        claimable_aero: nil,
        claimable_aero_usd: nil,
        depositor_address: nil,
        depositor_source: nil,
        gauge_address: nil,
        token_id: @position.external_id,
        aero_usd_price: nil,
        aero_usd_price_source: "unavailable",
        warnings: [ "AERODROME_REWARDS_ENABLED is not true" ]
      }
    end

    AerodromeRewardsCheck.new.report
  rescue => e
    Rails.logger.warn("Aerodrome rewards dashboard read failed for position #{@position.id}: #{e.class} #{e.message}")
    {
      status: "unavailable",
      gauge_status: "unavailable",
      claimable_aero: nil,
      claimable_aero_usd: nil,
      depositor_address: nil,
      depositor_source: nil,
      gauge_address: nil,
      token_id: @position.external_id,
      aero_usd_price: nil,
      aero_usd_price_source: "unavailable",
      warnings: [ e.message ]
    }
  end

  def aerodrome_fees_report
    unless ENV["AERODROME_FEES_ENABLED"].to_s.downcase == "true"
      return {
        status: "not configured",
        fee_source: "not configured",
        fee0_symbol: nil,
        fee0_amount: nil,
        fee0_usd: nil,
        fee1_symbol: nil,
        fee1_amount: nil,
        fee1_usd: nil,
        total_fees_usd: nil,
        token_id: @position.external_id,
        warnings: [ "AERODROME_FEES_ENABLED is not true" ]
      }
    end

    AerodromeFeesCheck.new.report
  rescue => e
    Rails.logger.warn("Aerodrome fees dashboard read failed for position #{@position.id}: #{e.class} #{e.message}")
    {
      status: "unavailable",
      fee_source: "unavailable",
      fee0_symbol: nil,
      fee0_amount: nil,
      fee0_usd: nil,
      fee1_symbol: nil,
      fee1_amount: nil,
      fee1_usd: nil,
      total_fees_usd: nil,
      warnings: [ e.message ]
    }
  end

  def aerodrome_position_params
    params.require(:position).permit(
      :external_id,
      :pool_address,
      :dex_id,
      :user_id,
      :wallet_id,
      :hedge_target,
      :hedge_tolerance,
      :deactivate_existing_aerodrome_positions
    )
  end

  def aerodrome_import_defaults
    aerodrome_dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    last_aerodrome = Position.where(dex: aerodrome_dex).order(created_at: :desc, id: :desc).first

    {
      external_id: "",
      pool_address: last_aerodrome&.pool_address,
      dex_id: aerodrome_dex.id,
      user_id: User.find_by(id: 1)&.id || Current.user.id,
      wallet_id: Wallet.find_by(id: 1)&.id || Current.user.wallets.order(:id).first&.id,
      hedge_target: "1.0",
      hedge_tolerance: "0.03",
      source: Position::SOURCE_AERODROME_DIRECT,
      deactivate_existing_aerodrome_positions: "1"
    }
  end
end
