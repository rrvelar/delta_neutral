class DashboardVisiblePositions
  def initialize(user:)
    @user = user
  end

  def relation
    Position
      .active
      .left_outer_joins(:wallet)
      .where("positions.user_id = :user_id OR wallets.user_id = :user_id", user_id: user.id)
      .includes(
        :dex,
        :hedge,
        :position_dashboard_snapshot,
        :position_rewards_fees_snapshot,
        :position_hedge_accounting_snapshot,
        :pnl_snapshots,
        wallet: :network
      )
      .distinct
      .order(updated_at: :desc)
  end

  private

  attr_reader :user
end
