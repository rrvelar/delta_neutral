class AddExtendedCarriedForwardShortEthToPositionDashboardSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :position_dashboard_snapshots, :extended_carried_forward_short_eth, :decimal, precision: 30, scale: 18
  end
end
