class CreatePositionHedgeAccountingSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :position_hedge_accounting_snapshots do |t|
      t.references :position, null: false, foreign_key: true, index: { unique: true }
      t.datetime :refreshed_at
      t.string :refresh_status, null: false, default: "unknown"
      t.string :venue
      t.decimal :current_short_eth, precision: 30, scale: 18
      t.decimal :entry_price, precision: 30, scale: 12
      t.decimal :mark_price, precision: 30, scale: 12
      t.decimal :notional_usd, precision: 30, scale: 12
      t.decimal :unrealized_pnl_usd, precision: 30, scale: 12
      t.decimal :realized_pnl_usd, precision: 30, scale: 12
      t.decimal :trading_fees_usd, precision: 30, scale: 12
      t.decimal :funding_usd, precision: 30, scale: 12
      t.decimal :borrow_interest_usd, precision: 30, scale: 12
      t.decimal :rebates_credits_usd, precision: 30, scale: 12
      t.decimal :net_hedge_pnl_usd, precision: 30, scale: 12
      t.text :unavailable_components
      t.text :source_errors
      t.integer :orders_submitted, null: false, default: 0
      t.integer :signatures_created, null: false, default: 0
      t.timestamps
    end
  end
end
