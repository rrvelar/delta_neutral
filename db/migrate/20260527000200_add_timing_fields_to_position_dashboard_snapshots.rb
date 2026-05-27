class AddTimingFieldsToPositionDashboardSnapshots < ActiveRecord::Migration[8.1]
  def change
    add_column :position_dashboard_snapshots, :extended_critical_read_duration_ms, :integer
    add_column :position_dashboard_snapshots, :extended_critical_read_status, :string
    add_column :position_dashboard_snapshots, :extended_optional_read_duration_ms, :integer
    add_column :position_dashboard_snapshots, :extended_optional_read_status, :string
    add_column :position_dashboard_snapshots, :timeout_seconds_used, :decimal, precision: 10, scale: 3
  end
end
