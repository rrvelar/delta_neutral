require "test_helper"
class PositionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "should get index" do
    get positions_path
    assert_response :success
  end

  test "should get show" do
    position = positions(:eth_usdc)
    with_env(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ) do
      get position_path(position)
    end
    assert_response :success
  end

  test "index displays Aerodrome monitor-only position safely" do
    position = create_aerodrome_position

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get positions_path
    end

    assert_response :success
    assert_select "td", text: /Aerodrome Slipstream/
    assert_select "span", text: "Monitor-only"
    assert_select "span", text: "No orders"
    assert_select "span", text: "Hyperliquid not called"
    assert_match position.external_id, response.body
    assert_match "1.250000", response.body
    assert_match "$3,000.00", response.body
  end

  test "index includes active Mellow Extended position owned through current user's wallet" do
    position = create_wallet_owned_mellow_extended_position(user: users(:two), wallet_user: users(:one))

    get positions_path

    assert_response :success
    assert_match "WETH/USDC", response.body
    assert_match "Mellow", response.body
    assert_match "Production hedge", response.body
    assert_match "Extended", response.body
    assert_match "In tolerance", response.body
    assert_match position.external_id, response.body
    assert_match position_path(position, hedge_venue: "extended"), response.body
    assert_no_match "No active positions found.", response.body
  end

  test "index links to Aerodrome LP import form" do
    get positions_path

    assert_response :success
    assert_select "a", text: "Import Aerodrome LP Position"
  end

  test "new page renders Aerodrome LP import form" do
    create_aerodrome_position(pool_address: "0xlastpool", active: false)

    get new_position_path

    assert_response :success
    assert_match "Import Aerodrome LP Position", response.body
    assert_select "input[name='position[external_id]']"
    assert_select "input[name='position[pool_address]'][value='0xlastpool']"
    assert_select "input[name='position[hedge_target]'][value='1.0']"
    assert_select "input[name='position[hedge_tolerance]'][value='0.03']"
    assert_select "input[name='position[deactivate_existing_aerodrome_positions]']"
  end

  test "create imports Aerodrome position and hedge with valid token id" do
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = base_wallet

    HyperliquidService.stub(:new, hyperliquid_write_guard) do
      PositionSyncJob.stub(:perform_now, ->(_) { }) do
        assert_difference "Position.count", 1 do
          assert_difference "Hedge.count", 1 do
            post positions_path, params: {
              position: import_params(dex: dex, wallet: wallet, external_id: "70184676")
            }
          end
        end
      end
    end

    position = Position.order(:id).last
    assert_redirected_to position_path(position)
    assert_equal "70184676", position.external_id
    assert_equal Position::SOURCE_AERODROME_DIRECT, position.source
    assert_equal "WETH", position.asset0
    assert_equal "USDC", position.asset1
    assert_predicate position, :active?
    assert_equal BigDecimal("1.0"), position.hedge.target
    assert_equal BigDecimal("0.03"), position.hedge.tolerance
    assert_predicate position.hedge, :active?
  end

  test "create keeps record and shows warning when read-only sync fails" do
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = base_wallet

    PositionSyncJob.stub(:perform_now, ->(_) { raise "RPC unavailable" }) do
      assert_difference "Position.count", 1 do
        post positions_path, params: {
          position: import_params(dex: dex, wallet: wallet, external_id: "70184677")
        }
      end
    end

    position = Position.order(:id).last
    assert_redirected_to position_path(position)
    assert_match "read-only sync failed: RPC unavailable", flash[:notice]
  end

  test "duplicate active Aerodrome token id is blocked" do
    existing = create_aerodrome_position(external_id: "70184676")

    assert_no_difference "Position.count" do
      post positions_path, params: {
        position: import_params(dex: existing.dex, wallet: existing.wallet, external_id: "70184676")
      }
    end

    assert_response :unprocessable_entity
    assert_match "already exists", response.body
  end

  test "create deactivates old active Aerodrome positions only when selected" do
    old_position = create_aerodrome_position(external_id: "old-active")
    dex = old_position.dex
    wallet = old_position.wallet

    PositionSyncJob.stub(:perform_now, ->(_) { }) do
      post positions_path, params: {
        position: import_params(
          dex: dex,
          wallet: wallet,
          external_id: "new-without-deactivate",
          deactivate_existing: "0"
        )
      }
    end

    assert_predicate old_position.reload, :active?

    PositionSyncJob.stub(:perform_now, ->(_) { }) do
      post positions_path, params: {
        position: import_params(
          dex: dex,
          wallet: wallet,
          external_id: "new-with-deactivate",
          deactivate_existing: "1"
        )
      }
    end

    assert_not old_position.reload.active?
  end

  test "show displays Aerodrome monitor-only details and hedge preview" do
    position = create_aerodrome_position

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Position Control Center", response.body
    assert_match "Portfolio Snapshot", response.body
    assert_match "Selected Venue: Hyperliquid", response.body
    assert_match "Live Gated", response.body
    assert_match "Auto Unknown", response.body
    assert_match "Aerodrome Slipstream", response.body
    assert_match "Token ID", response.body
    assert_match "315985", response.body
    assert_match "Refresh Read-only Data", response.body
    assert_match "Generate Manual Hedge Proposal", response.body
    assert_match "Hedge Control Center", response.body
    assert_match "1.250000", response.body
    assert_match "$3,000.00", response.body
    assert_match "Current Hyperliquid ETH short", response.body
    assert_match "Action Preview", response.body
    assert_match "Auto-Rebalance Status", response.body
    assert_match "Recent Rebalance History", response.body
    assert_match "Open Hedge", response.body
    assert_match "Preview actions do not create orders.", response.body
    assert_no_match "HEDGE DISABLED", response.body
    assert_no_match "NOT LIVE HEDGE-READY", response.body
    assert_no_match "Manual proposal only - No orders - No Hyperliquid", response.body
    assert_no_match "Sync Now", response.body
    assert_no_match "Create Hedge", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "show displays read-only Aerodrome hedge status and pnl baseline" do
    position = create_aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2500"))
    hedge = Hedge.create!(position: position, target: BigDecimal("0.5"), tolerance: BigDecimal("0.05"), active: true)
    rebalance = hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: BigDecimal("0.4"),
      new_short_size: BigDecimal("0.625"),
      realized_pnl: BigDecimal("0"),
      status: ShortRebalance::STATUS_SUCCESS,
      message: "testnet rebalance complete",
      rebalanced_at: Time.zone.local(2026, 5, 9, 12, 0, 0)
    )

    with_env(
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Portfolio Snapshot", response.body
    assert_match "Hedge Control Center", response.body
    assert_match "Target hedge ETH", response.body
    assert_match "0.625000", response.body
    assert_match "Current Hyperliquid ETH short", response.body
    assert_match "Live Gated", response.body
    assert_match "Auto Unknown", response.body
    assert_match "Initial render uses cached values; diagnostics load separately.", response.body
    assert_match "Recent Rebalance History", response.body
    assert_match rebalance.id.to_s, response.body
    assert_match "0.400000", response.body
    assert_match "success", response.body
    assert_match "testnet rebalance complete", response.body
    assert_match "PnL Summary", response.body
    assert_match "Entry value", response.body
    assert_match "$2,500.00", response.body
    assert_match "Current pooled value", response.body
    assert_match "$3,000.00", response.body
    assert_match "Pool delta from entry", response.body
    assert_match "$500.00", response.body
    assert_match "Rewards and Fee Readback Details", response.body
    assert_match "Auto-Rebalance Status", response.body
    assert_match "Position sync", response.body
    assert_match "every minute", response.body
    assert_match "Hedge sync", response.body
    assert_match "every 5 minutes", response.body
    assert_match "Rebalance needed now", response.body
    assert_match "Unknown / snapshot not refreshed", response.body
    assert_no_match "Hedge: None", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "hedge open preview redirects with dry-run summary without real Hyperliquid writes" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, HyperliquidReadMock.new([ nil ])) do
        post hedge_open_preview_position_path(position)
      end
    end

    assert_redirected_to position_path(position)
    assert_match "Open preview", flash[:notice]
    assert_match "Target 1.25 ETH", flash[:notice]
  end

  test "show defaults dashboard hedge venue to Hyperliquid and renders selector" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_select "select[name='hedge_venue']"
    assert_select "option[selected='selected']", text: "Hyperliquid"
    assert_match "Ethereal", response.body
    assert_match "Nado", response.body
    assert_match "Extended", response.body
  end

  test "show selected Extended venue renders gated manual venue state" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_select "option[selected='selected']", text: "Extended"
    assert_match "Extended production venue", response.body
    assert_match "Detailed live preflight loads separately.", response.body
    assert_match "Initial render uses cached values; diagnostics load separately.", response.body
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Open Hedge", response.body
  end

  test "show selected Extended venue renders flat readback and open order count" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)
    stub_extended_read_only_flat

    with_env(extended_dashboard_env) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position, hedge_venue: "extended")
      end
    end

    assert_response :success
    assert_match "Extended production venue", response.body
    assert_match "Auto: Auto Unknown", response.body
    assert_match "Signer: Unknown", response.body
    assert_match "Required: 1x isolated-equivalent", response.body
    assert_match "Migration tools", response.body
    assert_match "Current Extended ETH-PERP position", response.body
    assert_match "not loaded", response.body
    assert_match "Open orders", response.body
    assert_match "Auto readiness", response.body
    assert_match "Extended readiness", response.body
  end

  test "show extended production venue uses dashboard snapshot for current exposure" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    hedge.short_rebalances.create!(asset: "ETH", venue: "extended", old_short_size: "0.7", new_short_size: "1.25", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 2.minutes.ago)
    hedge.short_rebalances.create!(asset: "ETH", venue: "ethereal", old_short_size: "1.25", new_short_size: "9.9", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 1.minute.ago)
    hedge.short_rebalances.create!(asset: "ETH", venue: "nado", old_short_size: "0.1", new_short_size: "4.2", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 1.minute.ago)
    create_dashboard_snapshot(position, extended_short_eth: "1.25", ethereal_short_eth: "0", nado_short_eth: "0")

    get position_path(position)

    assert_response :success
    assert_match "Production venue", response.body
    assert_match "Extended", response.body
    assert_match "Current Extended ETH short", response.body
    assert_match "1.250000", response.body
    assert_match "snapshot as of", response.body
    assert_match "Ethereal", response.body
    assert_match(/Ethereal<\/p>\s*<p[^>]*>0\.000000 ETH/, response.body)
    assert_match(/Nado<\/p>\s*<p[^>]*>0\.000000 ETH/, response.body)
    assert_match(/Combined short<\/p><p class="text-white">1\.250000 ETH/, response.body)
    assert_match "flat", response.body
    assert_match "Migration complete: production venue Extended.", response.body
  end

  test "show extended production venue keeps cached snapshot values consistent" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    hedge.short_rebalances.create!(asset: "ETH", venue: "extended", old_short_size: "0.8", new_short_size: "1.25", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 2.minutes.ago)
    hedge.short_rebalances.create!(asset: "ETH", venue: "ethereal", old_short_size: "1.25", new_short_size: "0", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 1.minute.ago)
    hedge.short_rebalances.create!(asset: "ETH", venue: "nado", old_short_size: "0.1", new_short_size: "0", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 1.minute.ago)
    create_dashboard_snapshot(position, extended_short_eth: "1.25", ethereal_short_eth: "0", nado_short_eth: "0", extended_auto_enabled: true)

    with_env("EXTENDED_AUTO_REBALANCE_ENABLED" => "true") do
      get position_path(position)
    end

    assert_response :success
    assert_match "Current Extended ETH short", response.body
    assert_operator response.body.scan("1.250000").size, :>=, 2
    assert_match "Auto Active", response.body
    assert_no_match "Auto Paused", response.body
    assert_operator response.body.scan("Live preflight is loaded separately.").size, :<=, 1
    assert_match "Emergency / manual close tools", response.body
    assert_no_match "Close Hedge</p>\n                    <p class=\"mt-1 text-xs text-gray-500\">Relevant now", response.body
    assert_no_match "Production venue is not switched until finalize succeeds", response.body
  end

  test "show maps Extended snapshot market and pnl fields into main dashboard" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    hedge.short_rebalances.create!(asset: "ETH", venue: "extended", old_short_size: "1.20", new_short_size: "1.25", status: ShortRebalance::STATUS_SUCCESS, message: "auto success", rebalanced_at: 1.minute.ago)
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_auto_enabled: true,
      extended_attrs: {
        notional_usd: "2625",
        entry_price: "2000",
        mark_price: "2100",
        unrealized_pnl_usd: "-125",
        leverage: "1",
        effective_leverage: "1.0",
        margin_mode: "isolated",
        open_orders_count: 0
      }
    )

    with_env("EXTENDED_AUTO_REBALANCE_ENABLED" => "true") do
      get position_path(position)
    end

    assert_response :success
    assert_match "$2,625.00", response.body
    assert_match "$2,000.00", response.body
    assert_match "$2,100.00", response.body
    assert_match "-$125.00", response.body
    assert_match "Partial hedge PnL", response.body
    assert_match "Partial, excluding unavailable realized PnL, fees, and funding", response.body
    assert_match "Isolated 1.0x", response.body
    assert_match "1.0x", response.body
    assert_match "Open orders", response.body
    assert_match ">0<", response.body
    assert_match "Preflight diagnostics separate", response.body
    assert_no_match "1 blocker", response.body
    assert_match "Last selected-venue success", response.body
    assert_match "auto success", response.body
    assert_no_match "Expected final", response.body
  end

  test "show treats Extended one times leverage as isolated equivalent when gate is confirmed" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_auto_enabled: true,
      source_errors: { extended_optional: "Timeout::Error: execution expired" },
      extended_attrs: {
        notional_usd: "2625",
        entry_price: "2000",
        mark_price: "2100",
        unrealized_pnl_usd: "2.47",
        leverage: "1",
        open_orders_count: 0,
        leverage_margin_gate_status: "pass"
      }
    )

    with_env("EXTENDED_AUTO_REBALANCE_ENABLED" => "true", "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true") do
      get position_path(position)
    end

    assert_response :success
    assert_match "1x isolated-equivalent", response.body
    assert_match "mode not directly exposed by API; dedicated account confirmed", response.body
    assert_no_match "Unknown Margin", response.body
    assert_no_match(/Effective leverage.*Unavailable/m, response.body)
    assert_match "$2.47", response.body
    assert_match "Auto Active", response.body
    assert_match "In tolerance", response.body
    assert_no_match "Timeout::Error", response.body
  end

  test "show marks dashboard snapshot stale using configured threshold" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: 3.minutes.ago
    )

    with_env("POSITION_DASHBOARD_SNAPSHOT_STALE_AFTER_SECONDS" => "120") do
      get position_path(position)
    end

    assert_response :success
    assert_match "Snapshot stale as of", response.body
    assert_match "1.250000", response.body
  end

  test "show renders migration control center from dashboard snapshot" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_auto_enabled: true,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    hedge.short_rebalances.create!(
      venue: "ethereal",
      asset: "WETH",
      old_short_size: "1.0",
      new_short_size: "1.1",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: 1.minute.ago
    )

    get position_path(position, hedge_venue: "extended")

    assert_response :success
    assert_match "Migration Control Center", response.body
    assert_match "Migration complete: production venue Extended.", response.body
    assert_match "Extended → Ethereal", response.body
    assert_match "Production venue", response.body
    assert_match "Preview from", response.body
    assert_match "Preview to", response.body
    assert_match "Sequence", response.body
    assert_match "Target-first", response.body
    assert_match "Source-first", response.body
    assert_match "Preview does not switch the production hedge venue", response.body
    assert_match "Preview migration", response.body
    assert_match "Run manual migration", response.body
    assert_match "Finalize migration", response.body
    assert_match "Cancel / clear migration state", response.body
    assert_match "Route Proof Matrix", response.body
    assert_match "Daily venue rotation readiness", response.body
    assert_match "Random Rotation Planner", response.body
    assert_match "Run virtual random rotation decision", response.body
    assert_match "Dry-run eligible targets", response.body
    assert_match "Live eligible routes", response.body
    assert_match "Selected route live", response.body
    assert_match "Virtual current venue", response.body
    assert_match "Virtual dry-run state only. Production hedge venue was not changed.", response.body
    assert_match "Last Daily Dry-run", response.body
    assert_match "Decision-only. No migration executed.", response.body
    assert_match "Extended → Nado", response.body
    assert_match "Nado → Ethereal", response.body
    assert_match "Run dry-run route proof", response.body
  end

  test "show renders latest daily random rotation dry run receipt" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_random_rotation_daily")).write(
      action: "daily_random_rotation_dry_run",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      status: "RANDOM_ROUTE_SELECTED",
      selected_route: { from_venue: "extended", to_venue: "nado" },
      selected_target_venue: "nado",
      virtual_current_venue_before: "extended",
      virtual_current_venue_after: "nado",
      daily_enabled: true,
      would_migrate: false,
      orders_submitted: 0,
      signatures_created: 0
    )

    get position_path(position, hedge_venue: "extended")

    assert_response :success
    assert_match "Last Daily Dry-run", response.body
    assert_match "Extended-&gt;Nado", response.body
    assert_match "Virtual before / after", response.body
    assert_match "RANDOM_ROUTE_SELECTED", response.body
    assert_match "0 / 0", response.body
  end

  test "show omits Nado open orders unavailable reason when readback succeeded" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    matrix = Struct.new(:report).new(
      {
        routes: [
          {
            from_venue: "extended",
            to_venue: "nado",
            preview_available: true,
            live_available: false,
            route_status: "READY_FOR_DRY_RUN",
            supported_modes: %w[full stepwise],
            supported_sequences: %w[target_first source_first],
            blockers: [],
            last_proof_time: nil,
            nado_readiness: {
              nado_flat: true,
              nado_current_short_eth: "0.0",
              nado_open_orders_count: 0,
              nado_open_short_preview_available: true,
              nado_reduce_only_close_preview_available: true,
              nado_reduce_only_close_preview_proof_mode: "synthetic"
            }
          }
        ]
      }
    )

    HedgeVenueMigrationRouteMatrix.stub(:new, matrix) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Nado: flat; open orders 0.", response.body
    assert_match "Nado previews: open yes, close proven (synthetic).", response.body
    assert_no_match "Nado open orders endpoint is unavailable or not configured.", response.body
  end

  test "show renders production health summary from snapshots and history" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_auto_enabled: true,
      refreshed_at: Time.current,
      extended_attrs: { leverage: "1", open_orders_count: 0 }
    )
    position.create_position_rewards_fees_snapshot!(refreshed_at: Time.current, refresh_status: "ok")
    position.create_position_hedge_accounting_snapshot!(refreshed_at: Time.current, refresh_status: "ok", venue: "extended")
    hedge.short_rebalances.create!(
      venue: "extended",
      asset: "WETH",
      old_short_size: "1.20",
      new_short_size: "1.25",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: 1.minute.ago
    )

    get position_path(position, hedge_venue: "extended")

    assert_response :success
    assert_match "Production Health", response.body
    assert_match "Extended hedge bot status", response.body
    assert_match "Snapshot-backed health", response.body
    assert_match "Last success", response.body
    assert_match "pending 0", response.body
  end

  test "migration preview action writes dry run receipt and keeps production venue selected" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    receipt_path = Rails.root.join("storage/hedge_migration_checks/#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0

    post migration_preview_position_path(position), params: {
      from_venue: "extended",
      to_venue: "ethereal",
      migration_mode: "preview",
      migration_sequence: "source_first",
      max_step_size_eth: "0.01"
    }

    assert_response :redirect
    assert_includes response.location, position_path(position)
    assert_includes response.location, "hedge_venue=extended"
    assert_includes response.location, "preview_to_venue=ethereal"
    assert_includes response.location, "preview_migration_sequence=source_first"
    assert_no_changes -> { hedge.reload.execution_venue } do
      get position_path(position, hedge_venue: "extended", preview_from_venue: "extended", preview_to_venue: "ethereal")
    end

    lines = File.readlines(receipt_path).drop(before_lines)
    assert_operator lines.size, :>, 0
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find do |item|
      item["position_id"] == position.id &&
        item["action"] == "migration_preview" &&
        item["from_venue"] == "extended" &&
        item["to_venue"] == "ethereal" &&
        item["migration_sequence"] == "source_first"
    end
    assert receipt, "expected migration_preview receipt for position #{position.id}"
    assert_equal "preview_ready", receipt.fetch("final_status")
    assert_equal true, receipt.fetch("dry_run")
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("orders_placed")
    assert_equal 0, receipt.fetch("signatures_created")
    assert_equal "extended", receipt.fetch("production_venue")
    assert_equal "extended", receipt.fetch("from_venue")
    assert_equal "ethereal", receipt.fetch("to_venue")
    assert_equal "source_first", receipt.fetch("migration_sequence")
    assert_equal "underhedge/unhedged", receipt.fetch("temporary_risk_type")
    assert receipt.key?("temporary_combined_after_first_leg")
    assert receipt.fetch("planned_target_leg").fetch("size_eth")
    assert receipt.fetch("planned_source_leg").fetch("size_eth")
    assert receipt.fetch("expected_final_combined")
    assert_equal receipt_path.to_s, receipt.fetch("receipt_path")
    assert_no_match HedgeVenueMigrationExecutor::CONFIRMATION, receipt.to_json
  end

  test "migration preview action is read only and blocks stale snapshot" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: 10.minutes.ago
    )

    post migration_preview_position_path(position), params: { from_venue: "extended", to_venue: "ethereal", migration_mode: "full" }

    assert_response :redirect
    assert_includes response.location, position_path(position)
    assert_includes response.location, "hedge_venue=extended"
    assert_includes response.location, "preview_to_venue=ethereal"
    assert_match "snapshot is stale", flash[:alert]
  end

  test "migration route proof action writes dry run proof receipts" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    receipt_path = Rails.root.join("storage/hedge_migration_route_proofs/#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0

    post migration_route_proof_position_path(position)

    assert_response :redirect
    assert_match "Dry-run route proof wrote", flash[:notice]
    lines = File.readlines(receipt_path).drop(before_lines)
    assert_operator lines.size, :>, 0
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "migration_route_proof" }
    assert receipt
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  end

  test "migration random rotation decision action writes read only receipt" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    receipt_path = Rails.root.join("storage/hedge_migration_random_rotation/#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0

    post migration_random_rotation_decision_position_path(position)

    assert_response :redirect
    assert_match "Random rotation decision recorded", flash[:notice]
    lines = File.readlines(receipt_path).drop(before_lines)
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "random_rotation_decision" }
    assert receipt
    assert_equal "random_rotation", receipt.fetch("strategy")
    assert_equal false, receipt.fetch("would_migrate")
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  end

  test "migration run is fail closed without env gate" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )

    post migration_run_position_path(position), params: {
      from_venue: "extended",
      to_venue: "ethereal",
      migration_mode: "full",
      migration_confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: "1"
    }

    assert_response :redirect
    assert_includes response.location, position_path(position)
    assert_includes response.location, "hedge_venue=extended"
    assert_includes response.location, "preview_to_venue=ethereal"
    assert_match "MIGRATION_LIVE_ENABLED must be true", flash[:alert]
  end

  test "show renders rewards fees and accounting snapshots without live diagnostics" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_attrs: {
        notional_usd: "2625",
        entry_price: "2000",
        mark_price: "2100",
        unrealized_pnl_usd: "-125",
        leverage: "1",
        open_orders_count: 0
      }
    )
    position.create_position_rewards_fees_snapshot!(
      refreshed_at: 2.minutes.ago,
      refresh_status: "ok",
      aero_rewards_amount: "25.476",
      aero_rewards_usd: "11.12",
      aero_usd_price: "0.4365",
      aero_price_source: "coingecko",
      rewards_source: "mellow_ui_parity_eth_call",
      rewards_value_state: "estimated",
      lp_fee_weth_amount: "0.01",
      lp_fee_weth_usd: "20.5",
      lp_fee_usdc_amount: "3.25",
      lp_fee_usdc_usd: "3.25",
      lp_fee_total_usd: "23.75",
      fee_source: "mellow_strategy",
      fee_value_state: "estimated"
    )
    position.create_position_hedge_accounting_snapshot!(
      refreshed_at: 2.minutes.ago,
      refresh_status: "ok",
      venue: "extended",
      current_short_eth: "1.25",
      entry_price: "2000",
      mark_price: "2100",
      notional_usd: "2625",
      unrealized_pnl_usd: "-125",
      realized_pnl_usd: "0",
      net_hedge_pnl_usd: "-125",
      unavailable_components: %w[trading_fees_usd funding_pnl_usd borrow_interest_usd].to_json
    )

    blocked_reader = ->(*) { raise "live diagnostics should not run on initial show" }
    AerodromeRewardsCheck.stub(:new, blocked_reader) do
      AerodromeFeesCheck.stub(:new, blocked_reader) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "25.476000", response.body
    assert_match "$11.12", response.body
    assert_match "$23.75", response.body
    assert_match "-$125.00", response.body
    assert_match "Fees / funding / borrow", response.body
    assert_no_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
  end

  test "show does not report in tolerance when selected current short is unknown" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")

    get position_path(position)

    assert_response :success
    assert_match "Unknown / snapshot not refreshed", response.body
    assert_no_match "In tolerance", response.body
  end

  test "show separates old failed rows from latest selected venue successes" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    hedge.short_rebalances.create!(asset: "ETH", venue: "extended", old_short_size: "0", new_short_size: "0.5", status: ShortRebalance::STATUS_FAILED, message: "old failure", rebalanced_at: 2.hours.ago)
    hedge.short_rebalances.create!(asset: "ETH", venue: "extended", old_short_size: "0.5", new_short_size: "1.25", status: ShortRebalance::STATUS_SUCCESS, message: "latest success", rebalanced_at: 1.minute.ago)

    get position_path(position)

    assert_response :success
    assert_match "latest success", response.body
    assert_match "Failed / needs attention", response.body
    assert_match "old failure", response.body
    assert_operator response.body.index("latest success"), :<, response.body.index("old failure")
  end

  test "show selected Extended venue renders when auto readiness is slow" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    stub_extended_read_only_flat
    slow_readiness = Class.new do
      def report(position:)
        sleep 0.1
        { continuous_auto_ready: true }
      end
    end.new

    with_env(extended_dashboard_env.merge("POSITIONS_DASHBOARD_SECTION_TIMEOUT_SECONDS" => "0.01")) do
      ExtendedAutoReadiness.stub(:new, slow_readiness) do
        get position_path(position, hedge_venue: "extended")
      end
    end

    assert_response :success
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Auto readiness", response.body
  end

  test "show selected Extended venue does not call slow diagnostics during initial render" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    blocked_reader = ->(*) { raise "diagnostic reader should not run on initial show" }

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AerodromeRewardsCheck.stub(:new, blocked_reader) do
      AerodromeFeesCheck.stub(:new, blocked_reader) do
        ExtendedAutoReadiness.stub(:new, blocked_reader) do
          get position_path(position, hedge_venue: "extended")
        end
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :success
    assert_operator elapsed, :<, 0.5
    assert_match "Initial render uses cached values; diagnostics load separately.", response.body
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
  end

  test "show renders when rewards and fees diagnostics are slow" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)
    slow_report = Class.new do
      def report
        sleep 0.1
        { status: "PASS" }
      end
    end.new

    with_env(
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_FEES_ENABLED" => "true",
      "POSITIONS_DASHBOARD_SECTION_TIMEOUT_SECONDS" => "0.01"
    ) do
      AerodromeRewardsCheck.stub(:new, ->(**) { slow_report }) do
        AerodromeFeesCheck.stub(:new, ->(**) { slow_report }) do
          get position_path(position)
        end
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_no_match(/\{:\w+=>/, response.body)
  end

  test "diagnostic endpoint renders fail-soft when Extended readiness is slow" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    slow_readiness = Class.new do
      def report(position:)
        sleep 0.1
        { continuous_auto_ready: true }
      end
    end.new

    with_env("POSITIONS_DASHBOARD_DIAGNOSTIC_TIMEOUT_SECONDS" => "0.01") do
      ExtendedAutoReadiness.stub(:new, slow_readiness) do
        get extended_diagnostics_position_path(position, hedge_venue: "extended")
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "unavailable", body.fetch("status")
    assert_match "timed out", body.fetch("warnings").join("; ")
  end

  test "extended live dashboard action is blocked and does not submit or sign" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      post hedge_open_position_path(position), params: { hedge_venue: "extended", dashboard_hedge_confirmation: "anything" }
    end

    assert_redirected_to position_path(position, hedge_venue: "extended")
    assert_match "Open blocked on Extended", flash[:alert]
    assert_match "Extended live disabled", flash[:alert]
    assert_no_match "Extended submit endpoint integration not implemented", flash[:alert]
  end

  test "show selected Ethereal venue renders cross margin live gated mode and disabled live actions" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position, hedge_venue: "ethereal")
    end

    assert_response :success
    assert_select "option[selected='selected']", text: "Ethereal"
    assert_match "Ethereal uses cross margin only", response.body
    assert_operator response.body.scan("ETHEREAL_LINKED_SIGNER_ADDRESS is required").size, :<=, 1
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Open Hedge", response.body
  end

  test "show selected Ethereal venue uses Ethereal preflight without stale Hyperliquid blockers" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "nado")

    with_env(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "false",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
      "ETHEREAL_SUBACCOUNT_ID" => "022f3030-69bb-4599-83e9-00ab5d109c19",
      "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "ETHEREAL_ONCHAIN_ID" => "2",
      "ETHEREAL_LOT_SIZE" => "0.0001",
      "ETHEREAL_TICK_SIZE" => "0.1"
    ) do
      stub_request(:get, "https://ethereal.example/v1/subaccount/022f3030-69bb-4599-83e9-00ab5d109c19")
        .to_return(status: 200, body: { name: "0x7072696d61727900000000000000000000000000000000000000000000000000" }.to_json)
      stub_request(:get, "https://ethereal.example/v1/rpc/config")
        .to_return(status: 200, body: { domain: {} }.to_json)
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position, hedge_venue: "ethereal")
      end
    end

    assert_response :success
    assert_match "Ethereal uses cross margin only", response.body
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Current active hedge venue is Nado; opening Ethereal would create a second hedge unless migration is intended.", response.body
    assert_no_match "Ethereal live submit adapter is not wired in delta_neutral", response.body
    assert_no_match "Hyperliquid conflicting hedge check is not wired", response.body
    assert_no_match "AERODROME_HEDGE_PAUSED must be false", response.body
    assert_match "Open Hedge", response.body
  end

  test "show selected Ethereal venue enables confirmation input when live gates pass except confirmation" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")

    with_env(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
      "ETHEREAL_SUBACCOUNT_ID" => "0x7072696d61727900000000000000000000000000000000000000000000000000",
      "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "ETHEREAL_ONCHAIN_ID" => "2",
      "ETHEREAL_LOT_SIZE" => "0.0001",
      "ETHEREAL_TICK_SIZE" => "0.1",
      "EXECUTION_SIGNER_URL" => "http://signer.example"
    ) do
      stub_ethereal_readback(position: position, active_position: nil)
      stub_request(:get, "https://ethereal.example/v1/rpc/config")
        .to_return(status: 200, body: { domain: {} }.to_json)
      stub_request(:get, "http://signer.example/health")
        .to_return(status: 200, body: { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ] }.to_json)
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position, hedge_venue: "ethereal")
      end
    end

    assert_response :success
    assert_no_match "Live submit is disabled for Ethereal; previews do not create orders.", response.body
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Open Hedge", response.body
  end

  test "show selected Ethereal venue keeps confirmation input disabled when live flag false" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    hedge.short_rebalances.create!(
      asset: "ETH",
      venue: "ethereal",
      old_short_size: "0",
      new_short_size: "0.5607",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )

    with_env(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "false",
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
      "ETHEREAL_SUBACCOUNT_ID" => "0x7072696d61727900000000000000000000000000000000000000000000000000",
      "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "ETHEREAL_ONCHAIN_ID" => "2",
      "ETHEREAL_LOT_SIZE" => "0.0001",
      "ETHEREAL_TICK_SIZE" => "0.1",
      "EXECUTION_SIGNER_URL" => "http://signer.example"
    ) do
      stub_ethereal_readback(position: position, active_position: nil)
      stub_request(:get, "https://ethereal.example/v1/rpc/config")
        .to_return(status: 200, body: { domain: {} }.to_json)
      stub_request(:get, "http://signer.example/health")
        .to_return(status: 200, body: { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ] }.to_json)
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position, hedge_venue: "ethereal")
      end
    end

    assert_response :success
    assert_match "Live submit is disabled for Ethereal; previews do not create orders.", response.body
    assert_match "Open Hedge", response.body
  end

  test "show selected Ethereal venue renders current short when readback values are strings" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    hedge.short_rebalances.create!(
      asset: "ETH",
      venue: "ethereal",
      old_short_size: "0",
      new_short_size: "0.5607",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )

    with_env(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "false",
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
      "ETHEREAL_SUBACCOUNT_ID" => "0x7072696d61727900000000000000000000000000000000000000000000000000",
      "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "ETHEREAL_ONCHAIN_ID" => "2",
      "ETHEREAL_LOT_SIZE" => "0.0001",
      "ETHEREAL_TICK_SIZE" => "0.1",
      "EXECUTION_SIGNER_URL" => "http://signer.example"
    ) do
      stub_ethereal_readback(
        position: position,
        active_position: {
          id: "ethereal-pos-1",
          size: "-0.5607",
          side: 1,
          cost: "-1178.87175",
          unrealizedPnl: "1.25"
        }
      )
      stub_request(:get, "https://ethereal.example/v1/product/market-price?productIds=2")
        .to_return(status: 200, body: { data: [ { productId: 2, oraclePrice: "2102.5" } ] }.to_json)
      stub_request(:get, "https://ethereal.example/v1/rpc/config")
        .to_return(status: 200, body: { domain: {} }.to_json)
      stub_request(:get, "http://signer.example/health")
        .to_return(status: 200, body: { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ] }.to_json)
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position, hedge_venue: "ethereal")
      end
    end

    assert_response :success
    assert_match "Current Ethereal ETH-PERP position", response.body
    assert_match "Current Ethereal ETH short", response.body
    assert_match "0.560700", response.body
    assert_no_match "current Ethereal position is long", response.body
    assert_no_match "{:", response.body
    assert_no_match "=&gt;", response.body
  end

  test "show selected Nado venue renders live gated mode and disabled live actions" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position, hedge_venue: "nado")
    end

    assert_response :success
    assert_select "option[selected='selected']", text: "Nado"
    assert_match "Nado Hedge Actions", response.body
    assert_no_match AerodromeLiveEmergencyClose::CONFIRMATION, response.body
    assert_match "Live preflight is loaded separately.", response.body
    assert_match "Live submit is disabled for Nado; previews do not create orders.", response.body
    assert_match "Nado Hedge Actions", response.body
  end

  test "hedge venue selection persists to hedge" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    patch hedge_venue_position_path(position), params: { hedge_venue: "nado" }

    assert_redirected_to position_path(position, hedge_venue: "nado")
    assert_equal "nado", hedge.reload.execution_venue
  end

  test "ethereal preview does not call Hyperliquid writes and redirects with dry-run mode" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        post hedge_open_preview_position_path(position), params: { hedge_venue: "ethereal" }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "ethereal")
    assert_match "Open preview on Ethereal", flash[:notice]
  end

  test "ethereal preview on inactive position shows informational warning" do
    position = create_aerodrome_position(active: false)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        post hedge_open_preview_position_path(position), params: { hedge_venue: "ethereal" }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "ethereal")
    assert_match "Open preview on Ethereal", flash[:notice]
    assert_match "Position is inactive; preview is informational only.", flash[:notice]
  end

  test "nado live post is server-side blocked and does not call Hyperliquid writes" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        post hedge_open_position_path(position), params: {
          hedge_venue: "nado",
          dashboard_hedge_confirmation: AerodromeDashboardHedgeAction::CONFIRMATION
        }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "nado")
    assert_match "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true", flash[:alert]
    assert_match "Nado signer service is not configured", flash[:alert]
  end

  test "hedge open live is blocked without typed confirmation" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, HyperliquidReadMock.new([ nil ])) do
        post hedge_open_position_path(position), params: { dashboard_hedge_confirmation: "wrong" }
      end
    end

    assert_redirected_to position_path(position)
    assert_match "submitted confirmation must equal #{AerodromeDashboardHedgeAction::CONFIRMATION}", flash[:alert]
  end

  test "hedge close preview is available and does not call emergency close" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_dashboard_env do
      HyperliquidService.stub(:new, HyperliquidReadMock.new([ { asset: "ETH", size: BigDecimal("-0.5"), mark_price: BigDecimal("2300") } ])) do
        post hedge_close_preview_position_path(position)
      end
    end

    assert_redirected_to position_path(position)
    assert_match "Close preview", flash[:notice]
    assert_match "delta -0.5 ETH", flash[:notice]
  end

  test "show renders rebalance history block with no hedge empty state" do
    position = create_aerodrome_position

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Recent Rebalance History", response.body
    assert_match "No Hyperliquid rebalance history yet.", response.body
    assert_match "Refresh Read-only Data", response.body
  end

  test "show renders rebalance history empty state when hedge has no records" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Recent Rebalance History", response.body
    assert_match "No Hyperliquid rebalance history yet.", response.body
  end

  test "show renders recent rebalance records for current position hedge only" do
    position = create_aerodrome_position(external_id: "history-current")
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)
    other_position = create_aerodrome_position(external_id: "history-other", pool_address: "0xother")
    other_hedge = Hedge.create!(position: other_position, target: "1.0", tolerance: "0.05", active: true)

    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0.0",
      new_short_size: "0.3973",
      realized_pnl: "1.23",
      status: ShortRebalance::STATUS_SUCCESS,
      message: nil,
      rebalanced_at: Time.zone.local(2026, 5, 11, 6, 15, 31)
    )
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0.3973",
      new_short_size: "0.5000",
      realized_pnl: "-2.50",
      status: ShortRebalance::STATUS_FAILED,
      message: "order rejected",
      rebalanced_at: Time.zone.local(2026, 5, 11, 6, 20, 31)
    )
    other_hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "9.0",
      new_short_size: "9.5",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      message: "other position record",
      rebalanced_at: Time.zone.local(2026, 5, 11, 7, 0, 0)
    )

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Recent Rebalance History", response.body
    assert_match "2 selected-venue rows", response.body
    assert_match "0.397300", response.body
    assert_match "order rejected", response.body
    assert_match "bg-green-950", response.body
    assert_match "bg-red-950", response.body
    assert_no_match "other position record", response.body
    assert_no_match "9.500000", response.body
  end

  test "show renders read-only AERO rewards section without adding rewards to total pnl" do
    position = create_aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2500"))

    with_env("AERODROME_REWARDS_ENABLED" => "false", "AERODROME_VOTER_ADDRESS" => nil) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_match "Open rewards/fees diagnostics", response.body
    assert_match "unavailable", response.body
    assert_match "$500.00", response.body
    assert_no_match "Claim rewards", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "show displays mocked read-only AERO rewards when enabled" do
    position = create_aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2500"))
    report = {
      status: "PASS",
      gauge_status: "detected",
      token_id: position.external_id,
      staked: true,
      claimable_aero: "14.14",
      aero_usd_price: "0.5",
      aero_usd_price_source: "manual",
      claimable_aero_usd: "7.07",
      depositor_address: "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6",
      depositor_source: "env",
      gauge_address: "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28",
      warnings: []
    }

    with_env("AERODROME_REWARDS_ENABLED" => "true") do
      AerodromeRewardsCheck.stub(:new, ->(**) {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
          get position_path(position)
        end
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_no_match "14.140000", response.body
    assert_no_match "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6", response.body
    assert_match "$500.00", response.body
    assert_match "Total PnL Excluding Rewards / Fees", response.body
    assert_match "Rewards / fees diagnostics", response.body
    assert_match "Not loaded during initial render", response.body
    assert_no_match "Claim rewards", response.body
  end

  test "show displays Mellow pro rata pnl instead of direct lp valuation" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      entry_value_usd: BigDecimal("2611.87311081"),
      asset0_amount: BigDecimal("1.16492319796791"),
      asset1_amount: BigDecimal("240.9127633559829"),
      asset0_price_usd: BigDecimal("0"),
      asset1_price_usd: BigDecimal("0.77208"),
      mellow_metadata: JSON.generate(
        "submitted_wallet" => position.wallet.address,
        "share_token" => "0xshare",
        "strategy_token_id" => "71261528",
        "strategy_pool_address" => position.pool_address,
        "user_share_percent" => "1.23",
        "user_weth_exposure" => "1.16492319796791",
        "user_usdc_exposure" => "240.9127633559829",
        "user_total_value_usd" => "2611.873110814818",
        "last_probe_at" => "2026-05-23T00:00:00Z",
        "last_probe_confidence" => "high",
        "hedge_ready" => true
      )
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Mellow pro-rata current value", response.body
    assert_match "Mellow entry value", response.body
    assert_match "Mellow pro-rata delta from entry", response.body
    assert_match "Mellow WETH pro-rata exposure", response.body
    assert_match "Observed strategy token ID", response.body
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_match "Open rewards/fees diagnostics", response.body
    assert_match "$2,611.87", response.body
    assert_no_match "$186.00", response.body
    assert_no_match "-$2,422", response.body
  end

  test "show displays Mellow rewards and LP fee estimates without parsing synthetic id as direct NFT" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      entry_value_usd: BigDecimal("2600"),
      mellow_metadata: JSON.generate(
        "strategy_token_id" => "71261528",
        "user_share_percent" => "1.25",
        "user_weth_exposure" => "1.0",
        "user_usdc_exposure" => "500",
        "user_total_value_usd" => "2700",
        "last_probe_confidence" => "high",
        "hedge_ready" => true
      )
    )
    rewards_report = {
      status: "PASS",
      gauge_status: "detected",
      token_id: "mellow:71261528",
      token_source: "mellow_strategy_observed_token",
      strategy_level_estimate: true,
      pro_rata_share: "0.0125",
      reward_label: "Mellow pro-rata AERO rewards estimate",
      staked: true,
      claimable_aero: "1.25",
      aero_usd_price: "0.5",
      aero_usd_price_source: "manual",
      claimable_aero_usd: "0.625",
      depositor_address: "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6",
      depositor_source: "env",
      gauge_address: "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28",
      warnings: [ "Mellow rewards/fees are read-only pro-rata estimates from the observed strategy token; claiming/collecting is not implemented." ]
    }
    fees_report = {
      status: "PASS",
      fee_source: AerodromeFeesService::MELLOW_SOURCE,
      token_id: "mellow:71261528",
      strategy_level_estimate: true,
      fee_label: "Mellow pro-rata LP fee estimate",
      fee0_symbol: "WETH",
      fee0_amount: "0.2",
      fee0_usd: "400.0",
      fee1_symbol: "USDC",
      fee1_amount: "2.0",
      fee1_usd: "2.0",
      total_fees_usd: "402.0",
      warnings: []
    }

    with_env("AERODROME_REWARDS_ENABLED" => "true", "AERODROME_FEES_ENABLED" => "true") do
      AerodromeRewardsCheck.stub(:new, ->(**) {
        Object.new.tap { |object| object.define_singleton_method(:report) { rewards_report } }
      }) do
        AerodromeFeesCheck.stub(:new, ->(**) {
          Object.new.tap { |object| object.define_singleton_method(:report) { fees_report } }
        }) do
          get position_path(position)
        end
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_match "Open rewards/fees diagnostics", response.body
    assert_no_match "mellow_strategy_observed_token", response.body
    assert_no_match "invalid value for Integer", response.body
  end

  test "show uses Nado readback for current hedge status and pnl when hedge venue is nado" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      entry_value_usd: BigDecimal("2029"),
      asset0_amount: BigDecimal("0.936162"),
      asset1_amount: BigDecimal("100"),
      mellow_metadata: JSON.generate(
        "submitted_wallet" => position.wallet.address,
        "share_token" => "0xshare",
        "strategy_token_id" => "71261528",
        "strategy_pool_address" => position.pool_address,
        "user_share_percent" => "1.23",
        "user_weth_exposure" => "0.936162",
        "user_usdc_exposure" => "100",
        "user_total_value_usd" => "2029",
        "last_probe_confidence" => "high",
        "hedge_ready" => true
      )
    )
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.001", active: true, execution_venue: "nado")
    hedge.short_rebalances.create!(
      asset: "ETH",
      venue: "nado",
      old_short_size: "0.8",
      new_short_size: "0.936",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )
    nado_position = {
      venue: "Nado",
      symbol: "ETH-PERP",
      product_id: 4,
      side: "short",
      size: BigDecimal("-0.936"),
      short_size: BigDecimal("0.936"),
      margin_mode: "isolated",
      entry_price: BigDecimal("2061"),
      mark_price: BigDecimal("2050"),
      notional_usd: BigDecimal("1918.8"),
      isolated_margin_usd: BigDecimal("1909"),
      status: "ok"
    }
    adapter = NadoDashboardAdapterMock.new(nado_position)
    original_build = HedgeVenues.method(:build)

    HedgeVenues.stub(:build, ->(name, **kwargs) { name.to_s == "nado" ? adapter : original_build.call(name, **kwargs) }) do
      NadoHedgeExecutionService.stub(:new, ->(**) { NadoPreflightMock.new }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Current Nado ETH short", response.body
    assert_match "0.936000", response.body
    assert_match "within tolerance / no-op", response.body
    assert_match "Initial render uses cached values", response.body
    assert_no_match "Current Hyperliquid ETH position", response.body
  end

  test "show displays unavailable Mellow pnl when pro rata value is not usable" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      entry_value_usd: BigDecimal("2611.87311081"),
      asset0_price_usd: BigDecimal("0"),
      asset1_price_usd: BigDecimal("0.372"),
      mellow_metadata: JSON.generate(
        "hedge_ready" => false,
        "last_probe_confidence" => "low",
        "user_total_value_usd" => "2611.873110814818"
      )
    )

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Mellow pro-rata current value", response.body
    assert_match "Mellow pro-rata value is stale or unavailable.", response.body
    assert_match "Unavailable", response.body
    assert_no_match "-$2,422", response.body
  end

  test "show displays mocked read-only Aerodrome LP fees and combined estimate" do
    position = create_aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2500"))
    rewards_report = {
      status: "PASS",
      gauge_status: "detected",
      token_id: position.external_id,
      staked: true,
      claimable_aero: "14.14",
      aero_usd_price: "0.5",
      aero_usd_price_source: "manual",
      claimable_aero_usd: "7.07",
      depositor_address: "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6",
      depositor_source: "env",
      gauge_address: "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28",
      warnings: []
    }
    fees_report = {
      status: "PASS",
      fee_source: AerodromeFeesService::SOURCE,
      token_id: position.external_id,
      fee0_symbol: "WETH",
      fee0_amount: "0.01",
      fee0_usd: "20.0",
      fee1_symbol: "USDC",
      fee1_amount: "3.5",
      fee1_usd: "3.5",
      total_fees_usd: "23.5",
      warnings: []
    }

    with_env("AERODROME_REWARDS_ENABLED" => "true", "AERODROME_FEES_ENABLED" => "true") do
      AerodromeRewardsCheck.stub(:new, ->(**) {
        Object.new.tap { |object| object.define_singleton_method(:report) { rewards_report } }
      }) do
        AerodromeFeesCheck.stub(:new, ->(**) {
          Object.new.tap { |object| object.define_singleton_method(:report) { fees_report } }
        }) do
          HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
            get position_path(position)
          end
        end
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_no_match "0.010000 WETH", response.body
    assert_match "Total PnL Excluding Rewards / Fees", response.body
    assert_match "Rewards / fees diagnostics", response.body
    assert_match "Open rewards/fees diagnostics", response.body
    assert_no_match "Collect fees", response.body
    assert_no_match "Claim rewards", response.body
  end

  test "show displays Aerodrome LP fees unavailable without fake zero" do
    position = create_aerodrome_position
    fees_report = {
      status: "WARN",
      fee_source: "unavailable",
      token_id: position.external_id,
      fee0_symbol: nil,
      fee0_amount: nil,
      fee0_usd: nil,
      fee1_symbol: nil,
      fee1_amount: nil,
      fee1_usd: nil,
      total_fees_usd: nil,
      warnings: [ "fee read for staked Slipstream NFT is not verified" ]
    }

    with_env("AERODROME_FEES_ENABLED" => "true") do
      AerodromeFeesCheck.stub(:new, ->(**) {
        Object.new.tap { |object| object.define_singleton_method(:report) { fees_report } }
      }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_match "unavailable", response.body
    assert_match "Unavailable values are not treated as zero", response.body
    assert_no_match "Aerodrome fee read not implemented yet.", response.body
  end

  test "show renders unavailable AERO rewards when check raises" do
    position = create_aerodrome_position

    with_env("AERODROME_REWARDS_ENABLED" => "true") do
      AerodromeRewardsCheck.stub(:new, ->(**) { raise AerodromeRewardsService::RpcError, "RPC unavailable" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Rewards/fees diagnostics are not loaded on initial render.", response.body
    assert_match "unavailable", response.body
  end

  test "show displays latest manual proposal as local manual-only record" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    with_env(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Manual Hedge Proposal", response.body
    assert_match "Manual Proposal History", response.body
    assert_match "Manual proposal only", response.body
    assert_match "No orders", response.body
    assert_match "No Hyperliquid", response.body
    assert_match "Execution disabled", response.body
    assert_match "Not a live hedge", response.body
    assert_match "Local record only", response.body
    assert_match "Review does not place orders", response.body
    assert_match "Safety status", response.body
    assert_match "PASSED", response.body
    assert_match "Checked Limits", response.body
    assert_match "Current", response.body
    assert_match "None", response.body
    assert_match "disabled / manual review only", response.body
    assert_match "not called", response.body
    assert_match "Mark Reviewed", response.body
    assert_match "Reject", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "show displays proposal history table for Aerodrome position" do
    position = create_aerodrome_position
    older = position.aerodrome_hedge_proposals.create!(
      status: "rejected",
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.0"),
      suggested_short_notional_usd: BigDecimal("2000"),
      lp_total_value_usd: BigDecimal("2500"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: 1.hour.ago,
      reviewed_at: 30.minutes.ago
    )
    latest = position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    get position_path(position)

    assert_response :success
    assert_match "Manual Proposal History", response.body
    assert_match latest.id.to_s, response.body
    assert_match older.id.to_s, response.body
    assert_match "disabled", response.body
    assert_match "not called", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "show displays blocked proposal safety status" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    with_env("AERODROME_MAX_SHORT_ETH" => "1") do
      get position_path(position)
    end

    assert_response :success
    assert_match "BLOCKED", response.body
    assert_match "suggested short amount exceeds configured maximum", response.body
    assert_match "Blocked proposals cannot be marked reviewed", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
  end

  test "show displays warnings when proposal safety limits are missing" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    get position_path(position)

    assert_response :success
    assert_match "WARNINGS", response.body
    assert_match "AERODROME_MAX_SHORT_ETH is not configured", response.body
    assert_match "not configured", response.body
  end

  test "creates manual proposal without Hyperliquid RPC trading or real hedge" do
    position = create_aerodrome_position

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, ->(*) { raise "RPC service should not be called" }) do
          assert_difference "AerodromeHedgeProposal.count", 1 do
            assert_no_difference "Hedge.count" do
              post position_aerodrome_hedge_proposals_path(position)
            end
          end
        end
      end
    end

    proposal = position.aerodrome_hedge_proposals.first
    assert_redirected_to position_path(position)
    assert_equal "draft", proposal.status
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "regenerate updates latest draft proposal without Hyperliquid RPC trading or real hedge" do
    position = create_aerodrome_position
    proposal = position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: 1.hour.ago
    )
    position.update!(asset0_amount: BigDecimal("1.5"))

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, ->(*) { raise "RPC service should not be called" }) do
          assert_no_difference "AerodromeHedgeProposal.count" do
            assert_no_difference "Hedge.count" do
              post regenerate_position_aerodrome_hedge_proposals_path(position)
            end
          end
        end
      end
    end

    assert_redirected_to position_path(position)
    assert_equal BigDecimal("1.5"), proposal.reload.suggested_short_amount
    assert_equal BigDecimal("3000"), proposal.suggested_short_notional_usd
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "regenerate creates a new draft after reviewed proposal without execution" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      status: "reviewed",
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: 1.hour.ago,
      reviewed_at: 30.minutes.ago
    )

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, ->(*) { raise "RPC service should not be called" }) do
          assert_difference "AerodromeHedgeProposal.draft.count", 1 do
            assert_no_difference "Hedge.count" do
              post regenerate_position_aerodrome_hedge_proposals_path(position)
            end
          end
        end
      end
    end

    assert_redirected_to position_path(position)
  end

  test "mark reviewed works without execution" do
    proposal = create_aerodrome_position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    with_env(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference "Hedge.count" do
          post mark_reviewed_aerodrome_hedge_proposal_path(proposal)
        end
      end
    end

    assert_redirected_to position_path(proposal.position)
    assert_equal "reviewed", proposal.reload.status
    assert_not_nil proposal.reviewed_at
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "blocked proposal cannot be marked reviewed" do
    proposal = create_aerodrome_position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    with_env("AERODROME_MAX_SHORT_ETH" => "1") do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference "Hedge.count" do
          post mark_reviewed_aerodrome_hedge_proposal_path(proposal)
        end
      end
    end

    assert_redirected_to position_path(proposal.position)
    assert_equal "draft", proposal.reload.status
    assert_nil proposal.reviewed_at
  end

  test "reject works without execution" do
    proposal = create_aerodrome_position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      assert_no_difference "Hedge.count" do
        post reject_aerodrome_hedge_proposal_path(proposal)
      end
    end

    assert_redirected_to position_path(proposal.position)
    assert_equal "rejected", proposal.reload.status
    assert_not_nil proposal.reviewed_at
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "reject works for blocked proposal without execution" do
    proposal = create_aerodrome_position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    with_env("AERODROME_MAX_SHORT_ETH" => "1") do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference "Hedge.count" do
          post reject_aerodrome_hedge_proposal_path(proposal)
        end
      end
    end

    assert_redirected_to position_path(proposal.position)
    assert_equal "rejected", proposal.reload.status
    assert_not_nil proposal.reviewed_at
  end

  test "show keeps Uniswap sync and hedge actions unchanged" do
    position = positions(:eth_usdc)

    get position_path(position)

    assert_response :success
    assert_match "Sync Now", response.body
    assert_match "View Hedge", response.body
    assert_no_match "Refresh Read-only Data", response.body
    assert_no_match "Manual Hedge Proposal", response.body
    assert_no_match "Manual Proposal History", response.body
    assert_no_match "Generate Manual Hedge Proposal", response.body
    assert_no_match "Regenerate Manual Hedge Proposal", response.body
    assert_no_match "Aerodrome Hedge Status", response.body
    assert_no_match "PnL baseline starts from first Aerodrome snapshot", response.body
    assert_no_match "AERO Rewards", response.body
  end

  test "show displays stale amount reason for changed proposal values" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.0"),
      suggested_short_notional_usd: BigDecimal("2000"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    get position_path(position)

    assert_response :success
    assert_match "Stale", response.body
    assert_match "amount changed", response.body
  end

  test "show displays stale notional reason for changed proposal values" do
    position = create_aerodrome_position
    position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2400"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )

    get position_path(position)

    assert_response :success
    assert_match "Stale", response.body
    assert_match "notional changed", response.body
  end

  test "show displays unavailable hedge preview when Aerodrome price data is missing" do
    position = create_aerodrome_position(asset0_price_usd: nil)

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Hedge preview unavailable", response.body
    assert_match "amount or USD price is missing", response.body
    assert_match "Unavailable", response.body
  end

  test "should queue sync_now" do
    position = positions(:eth_usdc)
    post sync_now_position_path(position)
    assert_redirected_to position_path(position)
  end

  private

  def create_aerodrome_position(asset0_price_usd: BigDecimal("2000"), asset1_price_usd: BigDecimal("1"), external_id: "315985", pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", active: true)
    Position.create!(
      user: users(:one),
      wallet: base_wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: asset0_price_usd,
      asset1_price_usd: asset1_price_usd,
      external_id: external_id,
      pool_address: pool_address,
      active: active
    )
  end

  def create_wallet_owned_mellow_extended_position(user:, wallet_user:)
    wallet = Wallet.create!(
      user: wallet_user,
      network: networks(:base),
      address: "0x#{SecureRandom.hex(20)}"
    )
    position = Position.create!(
      user: user,
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("0.727"),
      asset1_amount: BigDecimal("1500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "mellow:71261528",
      pool_address: "0xpool",
      active: true
    )
    position.create_hedge!(target: BigDecimal("1.0"), tolerance: BigDecimal("0.03"), active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: BigDecimal("0.727"),
      extended_status: "active",
      ethereal_short_eth: BigDecimal("0"),
      ethereal_status: "flat",
      nado_short_eth: BigDecimal("0"),
      nado_status: "flat",
      combined_short_eth: BigDecimal("0.727"),
      target_short_eth: BigDecimal("0.727"),
      tolerance_abs_eth: BigDecimal("0.02181"),
      drift_eth: BigDecimal("0"),
      inside_tolerance: true,
      signer_status: "ok"
    )
    position
  end

  def import_params(dex:, wallet:, external_id:, deactivate_existing: "0")
    {
      external_id: external_id,
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      dex_id: dex.id,
      user_id: users(:one).id,
      wallet_id: wallet.id,
      hedge_target: "1.0",
      hedge_tolerance: "0.03",
      deactivate_existing_aerodrome_positions: deactivate_existing
    }
  end

  def create_dashboard_snapshot(position, extended_short_eth:, ethereal_short_eth:, nado_short_eth:, extended_auto_enabled: false, refreshed_at: 2.minutes.ago, extended_attrs: {}, source_errors: {})
    target = BigDecimal(position.asset0_amount.to_s) * position.hedge.target
    combined = BigDecimal(extended_short_eth.to_s) + BigDecimal(ethereal_short_eth.to_s) + BigDecimal(nado_short_eth.to_s)
    tolerance = target * position.hedge.tolerance
    position.create_position_dashboard_snapshot!(
      refreshed_at: refreshed_at,
      refresh_status: "ok",
      stale: false,
      production_venue: position.hedge.execution_venue,
      selected_venue: position.hedge.execution_venue,
      target_short_eth: target,
      tolerance_ratio: position.hedge.tolerance,
      tolerance_abs_eth: tolerance,
      combined_short_eth: combined,
      drift_eth: target - combined,
      inside_tolerance: (target - combined).abs <= tolerance,
      extended_short_eth: extended_short_eth,
      ethereal_short_eth: ethereal_short_eth,
      nado_short_eth: nado_short_eth,
      extended_status: BigDecimal(extended_short_eth.to_s).positive? ? "active" : "flat",
      ethereal_status: BigDecimal(ethereal_short_eth.to_s).positive? ? "active" : "flat",
      nado_status: BigDecimal(nado_short_eth.to_s).positive? ? "active" : "flat",
      extended_notional_usd: extended_attrs.fetch(:notional_usd, nil),
      extended_entry_price: extended_attrs.fetch(:entry_price, nil),
      extended_mark_price: extended_attrs.fetch(:mark_price, nil),
      extended_unrealized_pnl_usd: extended_attrs.fetch(:unrealized_pnl_usd, nil),
      extended_realized_pnl_usd: extended_attrs.fetch(:realized_pnl_usd, nil),
      extended_leverage: extended_attrs.fetch(:leverage, nil),
      extended_effective_leverage: extended_attrs.fetch(:effective_leverage, nil),
      extended_margin_mode: extended_attrs.fetch(:margin_mode, nil),
      open_orders_count_extended: extended_attrs.fetch(:open_orders_count, nil),
      leverage_margin_gate_status: extended_attrs.fetch(:leverage_margin_gate_status, nil),
      extended_auto_enabled: extended_auto_enabled,
      ethereal_auto_enabled: false,
      nado_auto_enabled: false,
      signer_status: "ok",
      signer_checked_at: refreshed_at,
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      source_errors: source_errors.to_json
    )
  end

  def hyperliquid_write_guard
    ->(*) do
      Object.new.tap do |object|
        object.define_singleton_method(:open_short) { raise "Hyperliquid open_short must not be called" }
        object.define_singleton_method(:close_short) { raise "Hyperliquid close_short must not be called" }
        object.define_singleton_method(:set_leverage) { raise "Hyperliquid set_leverage must not be called" }
      end
    end
  end

  class HyperliquidReadMock
    def initialize(positions)
      @positions = positions
    end

    def get_position(asset)
      raise "USDC must not be read" if asset == "USDC"

      @positions.empty? ? nil : @positions.shift
    end
  end

  class NadoDashboardAdapterMock
    def initialize(position)
      @position = position
    end

    def venue_name = "Nado"

    def mode = "live_configured_but_disabled"

    def live_supported? = true

    def live_enabled? = false

    def blockers = []

    def warnings = []

    def read_position(symbol:)
      raise "unexpected symbol" unless symbol == "ETH"

      @position
    end

    def account_state
      {
        venue: "Nado",
        current_short_eth: "0.936",
        current_side: "short",
        margin_mode: "isolated",
        hedge_positions_count: 1
      }
    end

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      {
        rounded_size_eth: size_eth.to_s("F"),
        payload: {
          schema: "nado_eip712_order_preview",
          symbol: symbol,
          max_slippage: max_slippage
        }
      }
    end

    def close_preview(symbol:, size_eth:)
      {
        rounded_size_eth: size_eth.to_s("F"),
        payload: {
          schema: "nado_eip712_order_preview",
          symbol: symbol,
          reduce_only: true
        }
      }
    end
  end

  class NadoPreflightMock
    def preflight(**)
      {
        blockers: [ "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit." ],
        estimated_notional_usd: "1918.8"
      }
    end
  end

  def with_dashboard_env
    with_env(
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "1.6",
      "AERODROME_MAX_SHORT_ETH" => "1.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "1.6",
      "AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED" => "true",
      "AERODROME_DASHBOARD_HEDGE_CONFIRMATION" => AerodromeDashboardHedgeAction::CONFIRMATION,
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "HYPERLIQUID_TESTNET" => "false"
    ) { yield }
  end

  def extended_dashboard_env
    {
      "EXTENDED_API_BASE_URL" => "https://extended.example/api/v1",
      "EXTENDED_API_KEY" => "test-api-key",
      "EXTENDED_ACCOUNT_ID" => "acct",
      "EXTENDED_VAULT_NUMBER" => "123",
      "EXTENDED_CLIENT_ID" => "client",
      "EXTENDED_STARK_PUBLIC_KEY" => "0xpublic",
      "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
      "EXTENDED_LIVE_ENABLED" => "false",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def stub_extended_read_only_flat
    stub_request(:get, %r{\Ahttps://extended\.example/api/v1/user/positions\?market=ETH-USD\z})
      .to_return(status: 200, body: [].to_json)
    stub_request(:get, "https://extended.example/api/v1/user/account/info")
      .to_return(status: 200, body: { status: "ACTIVE", data: { accountId: "acct" } }.to_json)
    stub_request(:get, "https://extended.example/api/v1/user/balance")
      .to_return(status: 200, body: { data: { equity: "1999.79", balance: "1999.79" } }.to_json)
    stub_request(:get, %r{\Ahttps://extended\.example/api/v1/user/orders\?market=ETH-USD\z})
      .to_return(status: 200, body: [].to_json)
    stub_request(:get, %r{\Ahttps://extended\.example/api/v1/user/leverage\?market=ETH-USD\z})
      .to_return(status: 200, body: { data: [ { market: "ETH-USD", leverage: "1" } ] }.to_json)
    stub_request(:get, %r{\Ahttps://extended\.example/api/v1/user/fees\?market%5B%5D=ETH-USD\z})
      .to_return(status: 200, body: { data: [ { market: "ETH-USD", takerFeeRate: "0.0005" } ] }.to_json)
    stub_request(:get, %r{\Ahttps://extended\.example/api/v1/info/markets\?market=ETH-USD\z})
      .to_return(status: 200, body: {
        data: {
          name: "ETH-USD",
          tradingConfig: { minOrderSize: "0.01", minOrderSizeChange: "0.001", minPriceChange: "0.1" },
          marketStats: { markPrice: "2120" },
          l2Config: {
            collateralId: "0xcollateral",
            syntheticId: "0xsynthetic",
            collateralResolution: 1_000_000,
            syntheticResolution: 1_000_000
          }
        }
      }.to_json)
  end

  def stub_ethereal_readback(position:, active_position:)
    subaccount = ENV.fetch("ETHEREAL_SUBACCOUNT_ID")
    stub_request(:get, "https://ethereal.example/v1/product?limit=100&ticker=ETHUSD")
      .to_return(status: 200, body: {
        data: [
          {
            id: 2,
            onchainId: 2,
            displayTicker: "ETHUSD",
            ticker: "ETHUSD",
            lotSize: "0.0001",
            tickSize: "0.1",
            status: "active",
            quoteTokenName: "USD"
          }
        ]
      }.to_json)
    stub_request(:get, "https://ethereal.example/v1/position/active?productId=2&subaccountId=#{subaccount}")
      .to_return(status: 200, body: { data: active_position }.to_json)
    stub_request(:get, "https://ethereal.example/v1/subaccount/balance?subaccountId=#{subaccount}")
      .to_return(status: 200, body: {
        data: [
          {
            tokenName: "USD",
            amount: position.total_value_usd.to_s,
            available: position.total_value_usd.to_s,
            totalUsed: "0"
          }
        ]
      }.to_json)
  end

  def base_wallet
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
