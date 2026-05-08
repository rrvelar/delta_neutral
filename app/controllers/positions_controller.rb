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
    @position = Current.user.positions.includes(:dex, wallet: :network).find(params[:id])
    @pnl_snapshots = @position.pnl_snapshots.order(captured_at: :desc).limit(10)
    @rebalances = @position.hedge&.short_rebalances&.order(rebalanced_at: :desc) || ShortRebalance.none
    if @position.dex.name == "aerodrome_slipstream"
      @aerodrome_hedge_proposals = @position.aerodrome_hedge_proposals.latest_first.limit(10)
      @latest_aerodrome_hedge_proposal = @aerodrome_hedge_proposals.first
      safety = AerodromeHedgeProposalSafety.new
      @aerodrome_proposal_safety_results = @aerodrome_hedge_proposals.to_h do |proposal|
        [ proposal.id, safety.evaluate(proposal, current_position: @position) ]
      end
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
end
