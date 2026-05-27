class DashboardSnapshotJob < ApplicationJob
  queue_as :default

  def perform(position_id)
    position = Position.includes(:dex, :hedge, wallet: :network).find(position_id)
    DashboardSnapshotRefresh.new(position: position).refresh
    RewardsFeesSnapshotRefresh.new(position: position).refresh if position.dex.name == "aerodrome_slipstream"
    HedgeAccountingSnapshotRefresh.new(position: position).refresh if position.dex.name == "aerodrome_slipstream"
  end
end
