class CreatePositionDashboardSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :position_dashboard_snapshots do |t|
      t.references :position, null: false, foreign_key: true, index: { unique: true }
      t.datetime :refreshed_at
      t.string :refresh_status, null: false, default: "unknown"
      t.boolean :stale, null: false, default: true
      t.text :error_summary
      t.string :production_venue
      t.string :selected_venue
      t.decimal :target_short_eth, precision: 30, scale: 18
      t.decimal :tolerance_ratio, precision: 20, scale: 10
      t.decimal :tolerance_abs_eth, precision: 30, scale: 18
      t.decimal :combined_short_eth, precision: 30, scale: 18
      t.decimal :drift_eth, precision: 30, scale: 18
      t.boolean :inside_tolerance
      t.decimal :extended_short_eth, precision: 30, scale: 18
      t.decimal :ethereal_short_eth, precision: 30, scale: 18
      t.decimal :nado_short_eth, precision: 30, scale: 18
      t.string :extended_status
      t.string :ethereal_status
      t.string :nado_status
      t.decimal :extended_notional_usd, precision: 30, scale: 12
      t.decimal :ethereal_notional_usd, precision: 30, scale: 12
      t.decimal :nado_notional_usd, precision: 30, scale: 12
      t.decimal :extended_entry_price, precision: 30, scale: 12
      t.decimal :extended_mark_price, precision: 30, scale: 12
      t.decimal :extended_unrealized_pnl_usd, precision: 30, scale: 12
      t.decimal :extended_realized_pnl_usd, precision: 30, scale: 12
      t.decimal :extended_leverage, precision: 20, scale: 10
      t.decimal :extended_effective_leverage, precision: 20, scale: 10
      t.string :extended_margin_mode
      t.decimal :ethereal_effective_leverage, precision: 20, scale: 10
      t.integer :open_orders_count_extended
      t.boolean :extended_live_enabled
      t.boolean :extended_auto_enabled
      t.boolean :ethereal_auto_enabled
      t.boolean :nado_auto_enabled
      t.string :signer_status
      t.datetime :signer_checked_at
      t.string :leverage_margin_gate_status
      t.string :auto_readiness_status
      t.string :planned_auto_action
      t.decimal :planned_auto_order_size_eth, precision: 30, scale: 18
      t.string :extended_source_status
      t.string :ethereal_source_status
      t.string :nado_source_status
      t.text :source_errors

      t.timestamps
    end
  end
end
