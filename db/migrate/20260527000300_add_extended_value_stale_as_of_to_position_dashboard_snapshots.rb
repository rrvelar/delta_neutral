class AddExtendedValueStaleAsOfToPositionDashboardSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :position_dashboard_snapshots, :extended_value_stale_as_of, :datetime
  end
end
