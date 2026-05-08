class CreateAerodromeHedgeProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :aerodrome_hedge_proposals do |t|
      t.references :position, null: false, foreign_key: true
      t.string :status, null: false, default: "draft"
      t.string :hedge_asset, null: false
      t.string :hedge_side, null: false
      t.decimal :suggested_short_amount, precision: 30, scale: 18, null: false
      t.decimal :suggested_short_notional_usd, precision: 20, scale: 8, null: false
      t.decimal :lp_total_value_usd, precision: 20, scale: 8, null: false
      t.decimal :weth_price_usd, precision: 20, scale: 8, null: false
      t.string :source, null: false
      t.boolean :execution_enabled, null: false, default: false
      t.boolean :hyperliquid_called, null: false, default: false
      t.datetime :generated_at, null: false
      t.datetime :reviewed_at
      t.text :notes

      t.timestamps
    end

    add_index :aerodrome_hedge_proposals, [ :position_id, :status ]
    add_index :aerodrome_hedge_proposals, :generated_at
  end
end
