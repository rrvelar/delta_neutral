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
    @visible_positions = DashboardVisiblePositions.new(user: Current.user).call.to_a
    @positions = @visible_positions
    @total_value = @positions.sum { |position| PositionValuation.current(position).current_value_usd || 0 }
    @active_hedges = @positions.count { |p| p.hedge&.active? }
    Rails.logger.info(
      "DashboardController#index visible_positions user_id=#{Current.user.id} " \
      "email=#{Current.user.email_address} visible_count=#{@positions.size} " \
      "visible_position_ids=#{@positions.map(&:id).join(',')} active_hedge_count=#{@active_hedges}"
    )
  end
end
