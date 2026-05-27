class DashboardVisiblePositions
  def self.call(user:)
    new(user: user).call
  end

  def initialize(positional_user = nil, user: nil)
    @user = user || positional_user
  end

  def call
    relation
  end

  def relation
    raise ArgumentError, "user is required" unless user

    visible_relation
  end

  private

  attr_reader :user

  def visible_relation
    Position
      .active
      .left_outer_joins(:wallet)
      .where("positions.user_id = :user_id OR wallets.user_id = :user_id", user_id: user.id)
      .includes(
        :wallet,
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
end
