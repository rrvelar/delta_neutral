# Renders the main dashboard for the authenticated user.
#
# Aggregates portfolio-level data: active positions, total USD value,
# active hedge count, and the 10 most recent hedge rebalances.
class DashboardController < ApplicationController
  # GET /dashboard
  #
  # Loads summary data for the current user's portfolio.
  #
  # @return [void]
  def index
    @positions = Current.user.positions.active.includes(:dex, :hedge, :pnl_snapshots, wallet: :network)
    @total_value = @positions.sum { |position| PositionValuation.current(position).current_value_usd || 0 }
    @active_hedges = @positions.count { |p| p.hedge&.active? }
  end
end
