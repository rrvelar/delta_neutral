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
      @latest_aerodrome_weth_rebalance = @position.hedge&.short_rebalances&.where(asset: [ "ETH", "WETH" ])&.order(rebalanced_at: :desc)&.first
      @aerodrome_hedge_proposals = @position.aerodrome_hedge_proposals.latest_first.limit(10)
      @latest_aerodrome_hedge_proposal = @aerodrome_hedge_proposals.first
      safety = AerodromeHedgeProposalSafety.new
      @aerodrome_proposal_safety_results = @aerodrome_hedge_proposals.to_h do |proposal|
        [ proposal.id, safety.evaluate(proposal, current_position: @position) ]
      end
      @aerodrome_rewards_report = aerodrome_rewards_report
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

  private

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
      warnings: [ e.message ]
    }
  end
end
