class CreatePositionRewardsFeesSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :position_rewards_fees_snapshots do |t|
      t.references :position, null: false, foreign_key: true, index: { unique: true }
      t.datetime :refreshed_at
      t.string :refresh_status, null: false, default: "unknown"
      t.decimal :aero_rewards_amount, precision: 30, scale: 18
      t.decimal :aero_rewards_usd, precision: 30, scale: 12
      t.decimal :aero_usd_price, precision: 30, scale: 18
      t.string :aero_price_source
      t.string :rewards_source
      t.string :rewards_value_state
      t.string :rewards_confidence
      t.text :rewards_stop_reason
      t.decimal :lp_fee_weth_amount, precision: 30, scale: 18
      t.decimal :lp_fee_weth_usd, precision: 30, scale: 12
      t.decimal :lp_fee_usdc_amount, precision: 30, scale: 18
      t.decimal :lp_fee_usdc_usd, precision: 30, scale: 12
      t.decimal :lp_fee_total_usd, precision: 30, scale: 12
      t.string :fee_source
      t.string :fee_value_state
      t.text :fee_stop_reason
      t.text :source_errors
      t.text :warnings
      t.integer :orders_submitted, null: false, default: 0
      t.integer :signatures_created, null: false, default: 0
      t.timestamps
    end
  end
end
