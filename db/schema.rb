# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_27_000300) do
  create_table "aerodrome_hedge_proposals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "execution_enabled", default: false, null: false
    t.datetime "generated_at", null: false
    t.string "hedge_asset", null: false
    t.string "hedge_side", null: false
    t.boolean "hyperliquid_called", default: false, null: false
    t.decimal "lp_total_value_usd", precision: 20, scale: 8, null: false
    t.text "notes"
    t.integer "position_id", null: false
    t.datetime "reviewed_at"
    t.string "source", null: false
    t.string "status", default: "draft", null: false
    t.decimal "suggested_short_amount", precision: 30, scale: 18, null: false
    t.decimal "suggested_short_notional_usd", precision: 20, scale: 8, null: false
    t.datetime "updated_at", null: false
    t.decimal "weth_price_usd", precision: 20, scale: 8, null: false
    t.index ["generated_at"], name: "index_aerodrome_hedge_proposals_on_generated_at"
    t.index ["position_id", "status"], name: "index_aerodrome_hedge_proposals_on_position_id_and_status"
    t.index ["position_id"], name: "index_aerodrome_hedge_proposals_on_position_id"
  end

  create_table "dexes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_dexes_on_name", unique: true
  end

  create_table "hedges", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "asset0_hl_account"
    t.string "asset1_hl_account"
    t.datetime "created_at", null: false
    t.string "execution_venue", default: "hyperliquid", null: false
    t.integer "position_id", null: false
    t.decimal "target", precision: 5, scale: 4, null: false
    t.decimal "tolerance", precision: 5, scale: 4, null: false
    t.datetime "updated_at", null: false
    t.index ["position_id"], name: "index_hedges_on_position_id", unique: true
  end

  create_table "networks", force: :cascade do |t|
    t.integer "chain_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["chain_id"], name: "index_networks_on_chain_id", unique: true
    t.index ["name"], name: "index_networks_on_name", unique: true
  end

  create_table "pnl_snapshots", force: :cascade do |t|
    t.decimal "asset0_amount", precision: 30, scale: 18
    t.decimal "asset0_price_usd", precision: 20, scale: 8
    t.decimal "asset1_amount", precision: 30, scale: 18
    t.decimal "asset1_price_usd", precision: 20, scale: 8
    t.datetime "captured_at"
    t.decimal "collected_fees0", precision: 30, scale: 18
    t.decimal "collected_fees1", precision: 30, scale: 18
    t.datetime "created_at", null: false
    t.decimal "hedge_realized", precision: 20, scale: 8
    t.decimal "hedge_unrealized", precision: 20, scale: 8
    t.decimal "pool_unrealized", precision: 20, scale: 8
    t.integer "position_id", null: false
    t.decimal "uncollected_fees0", precision: 30, scale: 18
    t.decimal "uncollected_fees1", precision: 30, scale: 18
    t.datetime "updated_at", null: false
    t.index ["position_id"], name: "index_pnl_snapshots_on_position_id"
  end

  create_table "position_dashboard_snapshots", force: :cascade do |t|
    t.string "auto_readiness_status"
    t.decimal "combined_short_eth", precision: 30, scale: 18
    t.datetime "created_at", null: false
    t.decimal "drift_eth", precision: 30, scale: 18
    t.text "error_summary"
    t.boolean "ethereal_auto_enabled"
    t.decimal "ethereal_effective_leverage", precision: 20, scale: 10
    t.decimal "ethereal_notional_usd", precision: 30, scale: 12
    t.decimal "ethereal_short_eth", precision: 30, scale: 18
    t.string "ethereal_source_status"
    t.string "ethereal_status"
    t.boolean "extended_auto_enabled"
    t.integer "extended_critical_read_duration_ms"
    t.string "extended_critical_read_status"
    t.decimal "extended_effective_leverage", precision: 20, scale: 10
    t.decimal "extended_entry_price", precision: 30, scale: 12
    t.decimal "extended_leverage", precision: 20, scale: 10
    t.boolean "extended_live_enabled"
    t.string "extended_margin_mode"
    t.decimal "extended_mark_price", precision: 30, scale: 12
    t.decimal "extended_notional_usd", precision: 30, scale: 12
    t.integer "extended_optional_read_duration_ms"
    t.string "extended_optional_read_status"
    t.decimal "extended_realized_pnl_usd", precision: 30, scale: 12
    t.decimal "extended_short_eth", precision: 30, scale: 18
    t.string "extended_source_status"
    t.string "extended_status"
    t.decimal "extended_unrealized_pnl_usd", precision: 30, scale: 12
    t.datetime "extended_value_stale_as_of"
    t.boolean "inside_tolerance"
    t.string "leverage_margin_gate_status"
    t.boolean "nado_auto_enabled"
    t.decimal "nado_notional_usd", precision: 30, scale: 12
    t.decimal "nado_short_eth", precision: 30, scale: 18
    t.string "nado_source_status"
    t.string "nado_status"
    t.integer "open_orders_count_extended"
    t.string "planned_auto_action"
    t.decimal "planned_auto_order_size_eth", precision: 30, scale: 18
    t.integer "position_id", null: false
    t.string "production_venue"
    t.string "refresh_status", default: "unknown", null: false
    t.datetime "refreshed_at"
    t.string "selected_venue"
    t.datetime "signer_checked_at"
    t.string "signer_status"
    t.text "source_errors"
    t.boolean "stale", default: true, null: false
    t.decimal "target_short_eth", precision: 30, scale: 18
    t.decimal "timeout_seconds_used", precision: 10, scale: 3
    t.decimal "tolerance_abs_eth", precision: 30, scale: 18
    t.decimal "tolerance_ratio", precision: 20, scale: 10
    t.datetime "updated_at", null: false
    t.index ["position_id"], name: "index_position_dashboard_snapshots_on_position_id", unique: true
  end

  create_table "positions", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.string "asset0"
    t.decimal "asset0_amount", precision: 30, scale: 18
    t.decimal "asset0_price_usd", precision: 20, scale: 8
    t.string "asset1"
    t.decimal "asset1_amount", precision: 30, scale: 18
    t.decimal "asset1_price_usd", precision: 20, scale: 8
    t.datetime "created_at", null: false
    t.integer "dex_id", null: false
    t.decimal "entry_value_usd", precision: 20, scale: 8
    t.string "external_id"
    t.text "mellow_metadata"
    t.string "pool_address"
    t.string "source"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.integer "wallet_id", null: false
    t.index ["dex_id"], name: "index_positions_on_dex_id"
    t.index ["external_id"], name: "index_positions_on_external_id"
    t.index ["source"], name: "index_positions_on_source"
    t.index ["user_id"], name: "index_positions_on_user_id"
    t.index ["wallet_id"], name: "index_positions_on_wallet_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "hyperliquid_cross_margin", default: true, null: false
    t.integer "hyperliquid_leverage", default: 3, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_settings_on_user_id", unique: true
  end

  create_table "short_rebalances", force: :cascade do |t|
    t.string "asset"
    t.datetime "created_at", null: false
    t.string "exchange_order_id"
    t.integer "hedge_id", null: false
    t.text "message"
    t.decimal "new_short_size", precision: 20, scale: 8
    t.decimal "old_short_size", precision: 20, scale: 8
    t.string "order_side"
    t.decimal "realized_pnl", precision: 20, scale: 8
    t.datetime "rebalanced_at"
    t.string "receipt_path"
    t.boolean "reduce_only"
    t.string "status", default: "success", null: false
    t.datetime "updated_at", null: false
    t.string "venue", default: "hyperliquid", null: false
    t.index ["hedge_id"], name: "index_short_rebalances_on_hedge_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "first_name", null: false
    t.string "last_name", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "wallets", force: :cascade do |t|
    t.string "address", null: false
    t.datetime "created_at", null: false
    t.integer "network_id", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["network_id"], name: "index_wallets_on_network_id"
    t.index ["user_id"], name: "index_wallets_on_user_id"
  end

  add_foreign_key "aerodrome_hedge_proposals", "positions"
  add_foreign_key "hedges", "positions"
  add_foreign_key "pnl_snapshots", "positions"
  add_foreign_key "position_dashboard_snapshots", "positions"
  add_foreign_key "positions", "dexes"
  add_foreign_key "positions", "users"
  add_foreign_key "positions", "wallets"
  add_foreign_key "sessions", "users"
  add_foreign_key "settings", "users"
  add_foreign_key "short_rebalances", "hedges"
  add_foreign_key "wallets", "networks"
  add_foreign_key "wallets", "users"
end
