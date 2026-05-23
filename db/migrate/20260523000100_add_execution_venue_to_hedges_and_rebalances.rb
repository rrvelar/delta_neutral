class AddExecutionVenueToHedgesAndRebalances < ActiveRecord::Migration[8.1]
  def change
    add_column :hedges, :execution_venue, :string, null: false, default: "hyperliquid"
    add_column :short_rebalances, :venue, :string, null: false, default: "hyperliquid"
    add_column :short_rebalances, :order_side, :string
    add_column :short_rebalances, :reduce_only, :boolean
    add_column :short_rebalances, :exchange_order_id, :string
    add_column :short_rebalances, :receipt_path, :string
  end
end
