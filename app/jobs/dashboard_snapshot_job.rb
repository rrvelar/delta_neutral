class DashboardSnapshotJob < ApplicationJob
  queue_as :default

  def perform(position_id)
    position = Position.includes(:dex, :hedge, wallet: :network).find(position_id)
    DashboardSnapshotRefresh.new(position: position).refresh
  end
end
