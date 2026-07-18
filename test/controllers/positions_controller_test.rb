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

  test "dashboard random disable all preserves route policy settings" do
    position = create_aerodrome_position
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "ethereal")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "0",
      nado_short_eth: "0",
      ethereal_short_eth: "0.8"
    )
    OperationalSettings::RUNTIME_GATE_KEYS.each { |key| OperationalSettings.set!(key: key, enabled: true) }
    MigrationRouteOperationalPolicy.new.restore_defaults!(confirmation: MigrationRouteOperationalPolicy::RESTORE_CONFIRMATION)

    post random_rotation_disable_all_position_path(position), params: {
      random_rotation_confirmation: OperationalSettings::DISABLE_ALL_CONFIRMATION
    }

    assert_response :redirect
    assert_match position_path(position), response.location
    assert OperationalSettings::RUNTIME_GATE_KEYS.none? { |key| OperationalSettings.enabled?(key) }
    assert OperationalSettings::ROUTE_KEYS.all? { |key| OperationalSettings.enabled?(key) }
    assert_equal "source_first", OperationalSettings.get("MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY").raw_value
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
    assert_match "Extended", response.body
    assert_match "In tolerance", response.body
    assert_match position.external_id, response.body
    assert_match position_path(position, hedge_venue: "extended"), response.body
    assert_no_match "No active positions found.", response.body
  end

  test "index groups active duplicate historical and legacy positions with human labels" do
    active = create_aerodrome_position(external_id: "71674988", pool_address: "0xdup")
    active.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
    duplicate = create_aerodrome_position(external_id: "71674988", pool_address: "0xdup", active: false)
    duplicate.create_hedge!(target: "1.0", tolerance: "0.03", active: false, execution_venue: "hyperliquid")
    active.touch
    old_mellow = create_aerodrome_position(external_id: "mellow:71261528", active: false)
    old_mellow.update!(source: Position::SOURCE_MELLOW_AUTOPILOT)
    old_mellow.create_hedge!(target: "1.0", tolerance: "0.03", active: false, execution_venue: "extended")

    get positions_path

    assert_response :success
    assert_match "Active production", response.body
    assert_match "Inactive duplicates", response.body
    assert_match "Historical positions", response.body
    assert_match "Legacy unsupported venue positions", response.body
    assert_match "WETH/USDC Aerodrome LP #71674988, Position ##{active.id}", response.body
    assert_match "WETH/USDC Aerodrome LP #71674988, Position ##{duplicate.id}", response.body
    assert_match "Duplicate inactive", response.body
    assert_match "WETH/USDC Mellow Autopilot #mellow:71261528, Position ##{old_mellow.id}", response.body
    assert_match "Historical inactive", response.body
    assert_match "Unsupported legacy venue: hyperliquid", response.body
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
    assert_includes HedgeVenues::SUPPORTED_KEYS, position.hedge.execution_venue
    assert_not_equal "hyperliquid", position.hedge.execution_venue
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

  test "duplicate Aerodrome token id and pool updates existing position instead of creating duplicate" do
    existing = create_aerodrome_position(external_id: "71674988")
    existing.create_hedge!(target: "1.0", tolerance: "0.03", active: false, execution_venue: "hyperliquid")

    PositionSyncJob.stub(:perform_now, ->(_) { }) do
      assert_no_difference "Position.count" do
        post positions_path, params: {
          position: import_params(dex: existing.dex, wallet: existing.wallet, external_id: "71674988")
        }
      end
    end

    assert_redirected_to position_path(existing)
    assert_predicate existing.reload, :active?
    assert_predicate existing.hedge.reload, :active?
    assert_not_equal "hyperliquid", existing.hedge.execution_venue
    assert_match "activated instead of creating a duplicate", flash[:notice]
  end

  test "create deactivates old active Aerodrome positions by default unless explicitly opted out" do
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
          external_id: "new-with-default-deactivate"
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
    assert_match "Production runner venue: Nado", response.body
    assert_match "Advanced / manual controls", response.body
    assert_match "Manual UI selected venue", response.body
    assert_match "Live Gated", response.body
    assert_match "Auto Off", response.body
    assert_match "Aerodrome Slipstream", response.body
    assert_match "Token ID", response.body
    assert_match "315985", response.body
    assert_match "Refresh Read-only Data", response.body
    assert_match "Generate Manual Hedge Proposal", response.body
    assert_match "Hedge Control Center", response.body
    assert_match "1.250000", response.body
    assert_match "$3,000.00", response.body
    assert_match "Current Nado ETH short", response.body
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

  test "show displays emergency restore section for underhedged Extended production position" do
    position = create_aerodrome_position
    position.create_hedge!(target: BigDecimal("1.0"), tolerance: BigDecimal("0.03"), active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: BigDecimal("0"),
      extended_status: "flat",
      ethereal_short_eth: BigDecimal("0"),
      ethereal_status: "flat",
      nado_short_eth: BigDecimal("0"),
      nado_status: "flat",
      combined_short_eth: BigDecimal("0"),
      target_short_eth: BigDecimal("1.25"),
      tolerance_abs_eth: BigDecimal("0.0375"),
      drift_eth: BigDecimal("1.25"),
      inside_tolerance: false
    )

    readiness = extended_readiness(
      position,
      within_tolerance: false,
      planned_auto_action: "increase_short",
      target: "0.8",
      current: "0.74",
      drift: "0.06",
      tolerance: "0.024"
    )

    ExtendedAutoReadiness.stub(:new, ReadinessFactory.new(readiness)) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Emergency Restore Hedge", response.body
    assert_match "Emergency Refresh", response.body
    assert_match "does not use stale DB exposure", response.body
    assert_match HedgeEmergencyRestore::ADJUST_CONFIRMATION, response.body
  end

  test "show displays read-only Aerodrome hedge status and pnl baseline" do
    position = create_aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2500"))
    hedge = Hedge.create!(position: position, target: BigDecimal("0.5"), tolerance: BigDecimal("0.05"), active: true)
    rebalance = hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
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
    assert_match "Current Nado ETH short", response.body
    assert_match "Live Gated", response.body
    assert_match "Auto Off", response.body
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

  test "show defaults dashboard hedge venue to supported venue and renders selector" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_select "select[name='hedge_venue']"
    assert_select "option[selected='selected']", text: "Nado"
    assert_select "option", text: "Hyperliquid", count: 0
    assert_match "Ethereal", response.body
    assert_match "Nado", response.body
    assert_match "Extended", response.body
  end

  test "show existing hyperliquid record as unsupported legacy with switch action" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "hyperliquid")

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "unsupported legacy hedge venue Hyperliquid", response.body
    assert_match "Select Nado, Ethereal, or Extended", response.body
    assert_select "option", text: "Hyperliquid", count: 0
    assert_select "option[selected='selected']", text: "Nado"
  end

  test "archive deactivates position and hedge without live orders" do
    position = create_aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")

    HyperliquidService.stub(:new, hyperliquid_write_guard) do
      post archive_position_path(position)
    end

    assert_redirected_to positions_path
    assert_not position.reload.active?
    assert_not position.hedge.reload.active?
    assert_match "did not close the on-chain LP or any perps", flash[:notice]
  end

  test "archive is blocked if active hedge exposure exists" do
    position = create_aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
    create_dashboard_snapshot(position, extended_short_eth: "0", ethereal_short_eth: "0", nado_short_eth: "0.5")

    post archive_position_path(position)

    assert_redirected_to position_path(position)
    assert_predicate position.reload, :active?
    assert_match "active hedge exposure exists", flash[:alert]
  end

  test "activate makes production position and deactivates siblings without live orders" do
    old_position = create_aerodrome_position(external_id: "old-active")
    new_position = create_aerodrome_position(external_id: "new-inactive", active: false)
    new_position.create_hedge!(target: "1.0", tolerance: "0.03", active: false, execution_venue: "hyperliquid")

    HyperliquidService.stub(:new, hyperliquid_write_guard) do
      post activate_position_path(new_position)
    end

    assert_redirected_to position_path(new_position)
    assert_not old_position.reload.active?
    assert_predicate new_position.reload, :active?
    assert_predicate new_position.hedge.reload, :active?
    assert_not_equal "hyperliquid", new_position.hedge.execution_venue
    assert_match "No orders or signatures", flash[:notice]
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
    assert_match "Detailed live preflight loads separately;", response.body
    assert_match "Initial render uses cached values; diagnostics load separately.", response.body
    assert_match "Detailed live preflight loads separately;", response.body
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
    assert_match "Auto Off", response.body
    assert_no_match "Auto: Auto Off", response.body
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

  test "show surfaces carried-forward Extended exposure as stale diagnostic not live exposure" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(position, extended_short_eth: "1.997", ethereal_short_eth: "0", nado_short_eth: "0")
    position.position_dashboard_snapshot.update!(
      extended_short_eth: nil,
      extended_carried_forward_short_eth: "1.997",
      extended_status: "error",
      extended_source_status: "stale",
      extended_critical_read_status: "error_carried_forward"
    )

    get position_path(position)

    assert_response :success
    assert_match "Live readback failed", response.body
    assert_match "not counted as live exposure", response.body
    assert_match "1.997000 ETH shown for diagnostics only", response.body
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
    assert_match "Auto On", response.body
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
    assert_match "Auto On", response.body
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

    readiness = extended_readiness(
      position,
      within_tolerance: false,
      planned_auto_action: "increase_short",
      target: "0.8",
      current: "0.74",
      drift: "0.06",
      tolerance: "0.024"
    )

    ExtendedAutoReadiness.stub(:new, ReadinessFactory.new(readiness)) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Migration Control Center", response.body
    assert_match "Migration complete: production venue Extended.", response.body
    assert_match "Extended → Ethereal", response.body
    assert_match "Ethereal → Extended", response.body
    assert_match "Extended → Nado", response.body
    assert_match "Nado → Extended", response.body
    assert_match "Ethereal → Nado", response.body
    assert_match "Nado → Ethereal", response.body
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
    assert_match "Legacy route matrix diagnostics only", response.body
    assert_match "Cached daily venue rotation diagnostics", response.body
    assert_match "Random Rotation Planner", response.body
    assert_match "Live Autopilot Readiness", response.body
    assert_match "No live orders are submitted by this readiness panel.", response.body
    assert_match "Run virtual random rotation decision", response.body
    assert_match "Dry-run eligible targets", response.body
    assert_match "Live eligible routes", response.body
    assert_match "Selected route live", response.body
    assert_match "Virtual current venue", response.body
    assert_match "Virtual dry-run state only. Production hedge venue was not changed.", response.body
    assert_match "Last Daily Dry-run", response.body
    assert_match "Decision-only. No migration executed.", response.body
    assert_match "Run dry-run route proof", response.body
  end

  test "show renders latest daily random rotation dry run receipt" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
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

  test "production random runner section renders" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Production Control Center", response.body
    assert_match "24/7 Random Rotation: RUNNING", response.body
    assert_match "Production Random Runner", response.body
    assert_match "24/7 random rotation control", response.body
    assert_match "Running normally — no action needed", response.body
    assert_match "Route proofs", response.body
    assert_match "6/6 READY_FOR_RANDOM", response.body
    assert_match "Start 24h Canary", response.body
    assert_match "Start 24/7 Production", response.body
    assert_match "Request Stop After Current Cycle", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "operator control center renders recommended action venue cards and progress" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position)

    assert_response :success
    primary = css_select("#production-control-center").first.text
    assert_match "Running normally — no action needed", primary
    assert_match "Recommended action", primary
    assert_match "No action needed", primary
    assert_match "Do not press Start again", primary
    assert_match "Active hedge", primary
    assert_match "Route / cycle progress", primary
    assert_match "Runner internals (diagnostics)", primary
    # Top operator view must not dump raw JSON payloads at the operator.
    refute_match(/status_payload|=>|\{"/, primary)
    refute_match(/\bUnavailable\b/, primary)
  ensure
    clear_random_production_files(position&.id)
  end

  test "operator control center shows carried-forward extended value as diagnostic only" do
    position = production_random_position
    position.position_dashboard_snapshot.update!(
      extended_source_status: "stale",
      extended_critical_read_status: "error_carried_forward",
      extended_carried_forward_short_eth: "1.997"
    )
    write_random_production_files(position)

    get position_path(position)

    assert_response :success
    primary = css_select("#production-control-center").first.text
    assert_match "Previous stale value: 1.997", primary
    assert_match "Diagnostic only — not counted as live exposure", primary
  ensure
    clear_random_production_files(position&.id)
  end

  test "operator control center flags multiple exposure as red blocker without start recommendation" do
    position = production_random_position
    status = {
      status: "unsafe_multiple_exposure",
      current_production_venue: "nado",
      direct_preflight_blockers: [],
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: { "extended" => "1.0", "ethereal" => "0", "nado" => "2.12" },
      inside_tolerance: false,
      route_proofs_summary: random_production_route_summary
    }
    write_random_production_files(position, status: status)

    get position_path(position)

    assert_response :success
    primary = css_select("#production-control-center").first.text
    assert_match "Blocked — multiple exposure", primary
    assert_match "Do not start 24/7 production", primary
    refute_match "No action needed", primary
  ensure
    clear_random_production_files(position&.id)
  end

  test "production summary uses runner venue over manual selected venue" do
    position = production_random_position
    status = {
      status: "running",
      current_production_venue: "ethereal",
      direct_preflight_blockers: [],
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: { "extended" => "0", "ethereal" => "2.12", "nado" => "0" },
      inside_tolerance: true,
      route_proofs_summary: random_production_route_summary,
      gates_state: {
        "MIGRATION_LIVE_ENABLED" => true,
        "MIGRATION_AUTO_ENABLED" => true,
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => true
      }
    }
    heartbeat = {
      runner: "random_production_runner",
      position_id: position.id,
      pid: 12_345,
      started_at: Time.current.utc.iso8601,
      updated_at: Time.current.utc.iso8601,
      last_cycle: 1,
      last_route: "nado->ethereal",
      current_production_venue: "ethereal",
      target_short_eth: "2.12",
      combined_short_eth: "2.12",
      inside_tolerance: true,
      open_orders_zero: true,
      gates_enabled: true,
      last_hold_check_at: Time.current.utc.iso8601,
      status: "running"
    }
    write_random_production_files(position, status: status, heartbeat: heartbeat)

    get position_path(position, hedge_venue: "extended")

    assert_response :success
    assert_match "Production runner venue: Ethereal", response.body
    assert_match "Advanced / manual controls", response.body
    assert_match "Manual UI selected venue", response.body
    # Active venue short comes from the runner's direct readback (Ethereal 2.12),
    # not the manually selected Extended venue.
    primary = css_select("#production-control-center").first.text
    assert_match "Active venue short", primary
    assert_match "2.120000 ETH", primary
  ensure
    clear_random_production_files(position&.id)
  end

  test "production overview reduces primary tabs while runner active" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position)

    assert_response :success
    assert_match "Hedge / Migration / Routes in Diagnostics", response.body
    nav_labels = css_select("nav.sticky a").map { |node| node.text.strip }
    assert_equal [ "Overview", "Accounting", "Diagnostics", "Settings" ], nav_labels
  ensure
    clear_random_production_files(position&.id)
  end

  test "production start buttons disabled while runner is already running" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Already running. Use Request Stop After Current Cycle only if needed.", response.body
    assert_select "input[value='Start 24h Canary'][disabled]"
    assert_select "input[value='Start 24/7 Production'][disabled]"
  ensure
    clear_random_production_files(position&.id)
  end

  test "legacy diagnostics do not contradict ready production route proofs" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Advanced / legacy diagnostics: setup wizard and route matrix are diagnostic only", response.body
    assert_match "Legacy setup diagnostics", response.body
    assert_match "Production route proofs are 6/6 READY_FOR_RANDOM", response.body
    assert_match "Production runner uses READY_FOR_RANDOM route proofs.", response.body
    assert_no_match "Next required step: Run Supervised Live Canary", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "primary production control center does not show bare unavailable" do
    position = production_random_position
    status = {
      status: "running",
      current_production_venue: "nado",
      direct_preflight_blockers: [],
      direct_venue_shorts: { "extended" => "0", "ethereal" => "0", "nado" => nil },
      inside_tolerance: nil,
      route_proofs_summary: random_production_route_summary,
      gates_state: {
        "MIGRATION_LIVE_ENABLED" => true,
        "MIGRATION_AUTO_ENABLED" => true,
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => true
      }
    }
    write_random_production_files(position, heartbeat: {
      runner: "random_production_runner",
      position_id: position.id,
      pid: Process.pid,
      started_at: Time.current.utc.iso8601,
      updated_at: Time.current.utc.iso8601,
      last_cycle: nil,
      last_route: nil,
      current_production_venue: "nado",
      inside_tolerance: nil,
      open_orders_zero: nil,
      gates_enabled: true,
      last_hold_check_at: nil,
      status: "running"
    }, status: status)

    get position_path(position)

    assert_response :success
    primary_text = css_select("#production-control-center").first.text
    assert_no_match(/\bUnavailable\b/, primary_text)
    assert_match "unknown — not read back yet", primary_text
  ensure
    clear_random_production_files(position&.id)
  end

  # Regression for the exact production bug: authoritative status is safe with no
  # current blockers, but a stale heartbeat / previous-run event carries an old
  # "blocked_before_submit" blocker and an old combined short. The rendered
  # dashboard must trust the authoritative direct status, not the stale data.
  def stale_blocker_bug_files(position)
    status = {
      status: "running",
      current_direct_market_safe: true,
      updated_at: Time.current.utc.iso8601,
      blockers: [],
      direct_preflight_blockers: [],
      current_production_venue: "ethereal",
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: { "extended" => "0", "ethereal" => "2.4027", "nado" => "0" },
      inside_tolerance: true,
      route_proofs_summary: random_production_route_summary
    }
    heartbeat = {
      runner: "random_production_runner",
      position_id: position.id,
      pid: Process.pid,
      started_at: Time.current.utc.iso8601,
      updated_at: Time.current.utc.iso8601,
      last_cycle: 18,
      last_route: "nado->ethereal",
      current_production_venue: "ethereal",
      target_short_eth: "2.554154",
      combined_short_eth: "2.5627",
      inside_tolerance: true,
      open_orders_zero: true,
      status: "running"
    }
    latest_event = {
      event: "cycle",
      cycle: 18,
      route: "nado->ethereal",
      timestamp: 1.hour.ago.utc.iso8601,
      blockers: [ "active venue one-shot rebalance status is blocked_before_submit" ]
    }
    write_random_production_files(position, status: status, heartbeat: heartbeat, latest_event: latest_event)
  end

  test "stale blocked_before_submit is not the current top blocker when backend blockers are empty" do
    position = production_random_position
    stale_blocker_bug_files(position)

    get position_path(position)

    assert_response :success
    primary = css_select("#production-control-center").first.text
    # Banner is safe, not red action-required.
    assert_match "Running normally — no action needed", primary
    refute_match "Resolve blockers", primary
    # Top active short is the authoritative direct readback, not the stale combined.
    assert_match "2.402700 ETH", primary
    # The stale blocker is only present as a collapsed historical diagnostic,
    # never as the current recommended action.
    assert_match "Historical last event", primary
    assert_match "blocked_before_submit", primary
    assert_match "No action needed", primary
  ensure
    clear_random_production_files(position&.id)
  end

  test "random_production_status json endpoint returns a coherent view-model" do
    position = production_random_position
    stale_blocker_bug_files(position)

    get random_production_status_position_path(position, format: :json)

    assert_response :success
    vm = JSON.parse(response.body)
    assert_equal true, vm["market_safe"]
    assert_empty vm["current_blockers"]
    refute_equal "red", vm["banner_tone"]
    assert_equal "2.4027", vm["active_short_eth"].to_s
    assert_equal "2.5627", vm["combined_short_eth"].to_s
    assert vm["latest_event_stale"]
    assert vm["freshness"].present?
  ensure
    clear_random_production_files(position&.id)
  end

  test "full page wires the auto-refresh controller and refresh endpoint" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position)

    assert_response :success
    assert_match "data-controller=\"production-status-refresh\"", response.body
    assert_match "production-status-refresh-url-value", response.body
    assert_match "production-status-refresh#refreshNow", response.body
    assert_match "Last refreshed", response.body
    assert_match "Auto-refreshing every 8s", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  # End-to-end auto-refresh: the refresh fragment must reflect a CHANGED
  # authoritative status without any full-page reload, and the stale historical
  # blocker must never be promoted to a current blocker across refreshes. Saves
  # real rendered HTML/JSON artifacts for the report.
  test "auto-refresh fragment updates as authoritative status changes over time" do
    position = production_random_position
    stale_blocker_bug_files(position)
    evidence_dir = "/tmp/dn_dashboard_evidence"
    FileUtils.mkdir_p(evidence_dir)

    # First render: authoritative direct short is 2.4027, stale blocker present.
    get position_path(position)
    assert_response :success
    File.write(File.join(evidence_dir, "full_page.html"), response.body)
    full = css_select("#production-control-center").first.text
    assert_match "2.402700 ETH", full
    assert_match "Running normally — no action needed", full

    get random_production_status_position_path(position)
    assert_response :success
    File.write(File.join(evidence_dir, "fragment_before.html"), response.body)
    assert_match "2.402700 ETH", response.body
    refute_match(/Recommended action[^!]*Resolve blockers/, response.body)

    get random_production_status_position_path(position, format: :json)
    File.write(File.join(evidence_dir, "status_before.json"), response.body)
    before_vm = JSON.parse(response.body)
    assert_equal "2.4027", before_vm["active_short_eth"].to_s
    assert_empty before_vm["current_blockers"]

    # The runner rebalances: authoritative direct short changes to 2.5000.
    status = JSON.parse(File.read(random_production_dir.join("status_position_#{position.id}.json")))
    status["direct_venue_shorts"]["ethereal"] = "2.5000"
    status["updated_at"] = Time.current.utc.iso8601
    File.write(random_production_dir.join("status_position_#{position.id}.json"), JSON.pretty_generate(status))

    # Second fragment render reflects the new value with no full page reload.
    get random_production_status_position_path(position)
    assert_response :success
    File.write(File.join(evidence_dir, "fragment_after.html"), response.body)
    assert_match "2.500000 ETH", response.body
    refute_match "2.402700 ETH", response.body

    get random_production_status_position_path(position, format: :json)
    after_vm = JSON.parse(response.body)
    assert_equal "2.5000", after_vm["active_short_eth"].to_s
    # The stale blocker still never becomes a current blocker.
    assert_empty after_vm["current_blockers"]
    refute_equal "red", after_vm["banner_tone"]
  ensure
    clear_random_production_files(position&.id)
  end

  test "random_production_status html endpoint returns the control-center fragment" do
    position = production_random_position
    write_random_production_files(position)

    get random_production_status_position_path(position)

    assert_response :success
    assert_match "Production Control Center", response.body
    assert_match "Active venue short", response.body
    # It is a fragment, not a full-page render.
    assert_no_match(/<html/, response.body)
  ensure
    clear_random_production_files(position&.id)
  end

  test "optional accounting unavailable does not mark production runner blocked" do
    position = production_random_position
    write_random_production_files(position)

    get position_path(position, tab: "accounting")

    assert_response :success
    assert_match "Accounting diagnostics are optional and do not affect bot safety.", response.body
    assert_match "This does not mark the production runner blocked.", response.body
    assert_match "24/7 Random Rotation: RUNNING", response.body
    assert_no_match "24/7 Random Rotation: BLOCKED", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random 24h canary start requires confirmation phrase" do
    position = production_random_position
    control = random_production_control_guard

    MigrationRandomProductionControl.stub(:new, -> { control }) do
      post random_production_start_position_path(position), params: {
        production_runner_mode: "canary",
        random_production_confirmation: "WRONG"
      }
    end

    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_match "confirmation must equal #{MigrationRandomProductionRunner::CONFIRMATION}", flash[:alert]
    assert_equal [], control.calls
  end

  test "production random 24x7 start requires confirmation phrase" do
    position = production_random_position
    control = random_production_control_guard

    MigrationRandomProductionControl.stub(:new, -> { control }) do
      post random_production_start_position_path(position), params: {
        production_runner_mode: "production",
        random_production_confirmation: "WRONG"
      }
    end

    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_match "confirmation must equal #{MigrationRandomProductionRunner::CONFIRMATION}", flash[:alert]
    assert_equal [], control.calls
  end

  test "production random start submits systemd adapter with exact confirmation only" do
    position = production_random_position
    control = random_production_control_guard(ok: true)

    stub_clean_start_preflight do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "canary",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_equal [ [ :start, position.id, "canary" ] ], control.calls
    assert_no_match MigrationRandomProductionRunner::CONFIRMATION, flash[:notice]
  end

  test "production random docker mode writes host bridge control request instead of failing" do
    position = production_random_position
    control = MigrationRandomProductionControl.new(control_mode: "bridge")

    stub_clean_start_preflight do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "canary",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    payload = JSON.parse(File.read(random_production_dir.join("control_position_#{position.id}.json")))
    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_equal "start", payload["action"]
    assert_equal "canary_24h", payload["mode"]
    assert_equal true, payload["confirmation_present"]
    assert_no_match MigrationRandomProductionRunner::CONFIRMATION, payload.to_json
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random 24h canary start writes canary bridge mode" do
    position = production_random_position
    control = MigrationRandomProductionControl.new(control_mode: "bridge")

    stub_clean_start_preflight do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "canary",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    payload = JSON.parse(File.read(random_production_dir.join("control_position_#{position.id}.json")))
    assert_equal "start", payload["action"]
    assert_equal "canary_24h", payload["mode"]
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random 24x7 start writes production bridge mode" do
    position = production_random_position
    control = MigrationRandomProductionControl.new(control_mode: "bridge")

    stub_clean_start_preflight do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "production",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    payload = JSON.parse(File.read(random_production_dir.join("control_position_#{position.id}.json")))
    assert_equal "start", payload["action"]
    assert_equal "production_24x7", payload["mode"]
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random start is rejected by fresh backend preflight blockers" do
    position = production_random_position
    control = random_production_control_guard(ok: true)
    blocked_runner = Class.new do
      def start_preflight_blockers = [ "extended is quarantined; enabled routes involve it (nado->extended)" ]
    end.new

    MigrationRandomProductionRunner.stub(:new, ->(**_kwargs) { blocked_runner }) do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "production",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_match "blocked by fresh preflight", flash[:alert]
    assert_match "quarantined", flash[:alert]
    assert_equal [], control.calls, "control adapter must never be invoked when the fresh preflight blocks"
  end

  test "show renders Path A route subset, extended admission state and start confirmation notice" do
    position = production_random_position
    OperationalSettings.set!(key: "MIGRATION_ALLOWED_ROUTES", enabled: "nado->ethereal,ethereal->nado", reason: "test")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    get position_path(position, hedge_venue: "nado", tab: "migration")

    assert_response :success
    assert_match "Route subset mode: ACTIVE", response.body
    assert_match "nado-&gt;ethereal", response.body
    assert_match "ethereal-&gt;nado", response.body
    assert_match "not in approved subset", response.body
    assert_match "Extended venue: QUARANTINED", response.body
    assert_match "Starting production with 2-route subset: Nado ↔ Ethereal. Extended quarantined and excluded.", response.body
    assert_match "ROUTE SUBSET MODE active", response.body
  end

  test "production random stop safely calls production stop path" do
    position = production_random_position
    control = random_production_control_guard(ok: true)

    MigrationRandomProductionControl.stub(:new, -> { control }) do
      post random_production_stop_position_path(position), params: { random_production_stop_confirmation: "REQUEST_STOP_AFTER_CURRENT_CYCLE" }
    end

    assert_redirected_to position_path(position, hedge_venue: "nado", tab: "migration")
    assert_equal [ [ :stop, position.id ] ], control.calls
    assert_match "stop-after-current-cycle requested", flash[:notice]
  end

  test "production random stop writes bridge stop action and stop request" do
    position = production_random_position
    control = MigrationRandomProductionControl.new(control_mode: "bridge")

    MigrationRandomProductionControl.stub(:new, -> { control }) do
      post random_production_stop_position_path(position), params: { random_production_stop_confirmation: "REQUEST_STOP_AFTER_CURRENT_CYCLE" }
    end

    control_payload = JSON.parse(File.read(random_production_dir.join("control_position_#{position.id}.json")))
    stop_payload = JSON.parse(File.read(random_production_dir.join("stop_position_#{position.id}.json")))
    assert_equal "stop", control_payload["action"]
    assert_nil control_payload["mode"]
    assert_equal "stop_requested", stop_payload["status"]
    assert_equal position.id, stop_payload["position_id"]
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard reads heartbeat status and tail json safely" do
    position = production_random_position
    write_random_production_files(position, latest_event: {
      event: "cycle",
      cycle: 7,
      route: "ethereal->nado",
      status: "success",
      execution: { orders_submitted: 0 },
      post_cycle_hedge: { production_venue: "nado" },
      hold_rebalance_checks_count: 13,
      hold_monitor_actual_span_seconds: 3600,
      hold_monitor_gap_warning: nil,
      blockers: []
    })

    get position_path(position, tab: "migration", show_random_production_tail: true)

    assert_response :success
    assert_match "ethereal-&gt;nado", response.body
    assert_match "3600", response.body
    assert_match "Hold checks", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard renders when files are missing" do
    position = production_random_position
    clear_random_production_files(position.id)

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Production Random Runner", response.body
    assert_match "unavailable", response.body
    assert_match "Start 24h Canary", response.body
    assert_match "Request Stop After Current Cycle", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard status timeout returns placeholder" do
    position = production_random_position
    write_random_production_files(position)
    slow_dashboard = Class.new do
      def report(tail_lines:)
        sleep 0.1
        { status: "should_not_render", tail_lines: tail_lines }
      end
    end

    with_env("POSITIONS_DASHBOARD_SECTION_TIMEOUT_SECONDS" => "0.01", "POSITIONS_RANDOM_PRODUCTION_DASHBOARD_TIMEOUT_SECONDS" => "0.01") do
      MigrationRandomProductionDashboard.stub(:new, ->(*) { slow_dashboard.new }) do
        get position_path(position, tab: "migration")
      end
    end

    assert_response :success
    assert_match "Production Random Runner", response.body
    assert_match "unavailable", response.body
    assert_no_match "should_not_render", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard does not parse full huge jsonl" do
    position = production_random_position
    write_random_production_files(position)
    latest_path = random_production_dir.join("latest_position_#{position.id}.jsonl")
    File.open(latest_path, "wb") do |file|
      1_000.times { |index| file.write(JSON.generate({ event: "old", cycle: index, position_id: position.id }) + "\n") }
      file.write(JSON.generate({ event: "cycle", cycle: 1_001, route: "nado->ethereal", position_id: position.id }) + "\n")
    end

    File.stub(:readlines, ->(*) { raise "full file read is not allowed in position show" }) do
      get position_path(position, tab: "migration", show_random_production_tail: true)
    end

    assert_response :success
    assert_match "nado-&gt;ethereal", response.body
    assert_no_match "full file read is not allowed", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard does not call direct venue preflight" do
    position = production_random_position
    write_random_production_files(position)

    MigrationRandomBurnInPreflight.stub(:new, ->(*) { raise "direct preflight must not run in position show" }) do
      get position_path(position, tab: "migration")
    end

    assert_response :success
    assert_match "Production Random Runner", response.body
    assert_no_match "direct preflight must not run", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "position show does not recompute route proofs" do
    position = production_random_position
    write_random_production_files(position)

    HedgeVenueMigrationRouteMatrix.stub(:new, ->(*) { raise "route matrix recompute must not run in position show" }) do
      MigrationRouteProofRegistry.stub(:new, ->(*) { raise "route proof registry recompute must not run in position show" }) do
        get position_path(position, tab: "migration")
      end
    end

    assert_response :success
    assert_match "Legacy route matrix diagnostics only", response.body
    assert_no_match "route matrix recompute must not run", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "slow random rotation setup returns placeholder without slow page" do
    position = production_random_position
    write_random_production_files(position)
    fake_cache = Class.new do
      def route_matrix
        { routes: [], orders_submitted: 0, signatures_created: 0 }
      end

      def random_setup
        sleep 0.1
        { status_label: "should_not_render" }
      end
    end

    with_env("POSITIONS_RANDOM_ROTATION_SETUP_TIMEOUT_SECONDS" => "0.01") do
      MigrationRouteProofCache.stub(:new, ->(*) { fake_cache.new }) do
        get position_path(position, tab: "migration")
      end
    end

    assert_response :success
    assert_match "Route proof cache unavailable", response.body
    assert_no_match "should_not_render", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard renders host control result" do
    position = production_random_position
    write_random_production_files(position)
    File.write(
      random_production_dir.join("control_position_#{position.id}.json"),
      JSON.pretty_generate({
        action: "start",
        mode: "canary_24h",
        position_id: position.id,
        requested_at: Time.current.utc.iso8601,
        request_id: "request-1",
        confirmation_present: true
      })
    )
    File.write(
      random_production_dir.join("control_result_position_#{position.id}.json"),
      JSON.pretty_generate({
        status: "success",
        action: "start",
        mode: "canary_24h",
        position_id: position.id,
        request_id: "request-1",
        handled_at: Time.current.utc.iso8601,
        systemd_status: { "delta-neutral-random-production-6-canary.service" => "active" }
      })
    )

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Control mode", response.body
    assert_match "Bridge status", response.body
    assert_match "handled", response.body
    assert_match "canary_24h", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard shows stale lock clearly" do
    position = production_random_position
    write_random_production_files(position, lock: { runner: "random_production_runner", pid: 99_999_999 })

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "stale lock", response.body
    assert_match "99999999", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard shows direct preflight blockers" do
    position = production_random_position
    write_random_production_files(position, status: {
      status: "blocked",
      direct_preflight_blockers: [ "direct open orders are nonzero" ],
      direct_open_orders: random_production_open_orders("blocked"),
      direct_venue_shorts: random_production_shorts,
      inside_tolerance: true,
      gates_state: {}
    })

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Direct preflight blockers", response.body
    assert_match "direct open orders are nonzero", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard shows six of six route proofs from status cache" do
    position = production_random_position
    routes = MigrationRouteProofRegistry::ROUTES.map do |from, to|
      { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: MigrationRouteProofRegistry::STATUSES[:ready] }
    end
    write_random_production_files(position, status: {
      status: "running",
      direct_preflight_blockers: [],
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: random_production_shorts,
      inside_tolerance: true,
      proof_report: {
        routes: routes,
        completed_route_proofs: routes,
        missing_route_proofs: [],
        stale_route_proofs: []
      },
      gates_state: {}
    })

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "ready 6 / total 6", response.body
    assert_match "missing 0", response.body
    assert_match "stale 0", response.body
    assert_match "Legacy setup diagnostics", response.body
    assert_match "Next target venue", response.body
    assert_match "daily coverage policy", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard shows cache missing instead of fake zero route proofs" do
    position = production_random_position
    write_random_production_files(position, status: {
      status: "running",
      direct_preflight_blockers: [],
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: random_production_shorts,
      inside_tolerance: true,
      gates_state: {}
    })

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "cache missing", response.body
    assert_no_match "ready 0 / total 0", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random dashboard shows snapshot blockers as diagnostics only" do
    position = production_random_position
    position.position_dashboard_snapshot.update!(
      open_orders_count_extended: nil,
      extended_critical_read_status: "error",
      source_errors: { extended: "carried forward previous Extended snapshot" }.to_json
    )
    write_random_production_files(position)

    get position_path(position, tab: "migration")

    assert_response :success
    assert_match "Dashboard snapshot diagnostics only", response.body
    assert_match "critical Extended readback failed", response.body
    assert_match "carried forward previous Extended snapshot", response.body
    assert_no_match "Direct preflight blockers", response.body
  ensure
    clear_random_production_files(position&.id)
  end

  test "production random confirmation phrase is not persisted" do
    position = production_random_position
    control = MigrationRandomProductionControl.new(control_mode: "bridge")

    stub_clean_start_preflight do
      MigrationRandomProductionControl.stub(:new, -> { control }) do
        post random_production_start_position_path(position), params: {
          production_runner_mode: "production",
          random_production_confirmation: MigrationRandomProductionRunner::CONFIRMATION
        }
      end
    end

    assert_nil OperationalSetting.where("value LIKE ?", "%PRODUCTION_RANDOM_ROTATION%").first
    assert_no_match MigrationRandomProductionRunner::CONFIRMATION, flash[:notice].to_s
    assert_no_match MigrationRandomProductionRunner::CONFIRMATION, File.read(random_production_dir.join("control_position_#{position.id}.json"))
  ensure
    clear_random_production_files(position&.id)
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
    assert_match "Current Extended auto readiness is the production truth", response.body
    assert_match "Last success", response.body
    assert_match "pending 0", response.body
  end

  test "migration preview action writes dry run receipt and keeps production venue selected" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
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
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/route-proof-controller-#{SecureRandom.hex(4)}")
    receipt_path = registry_dir.join("#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0
    matrix = HedgeVenueMigrationRouteMatrix.new(position: position, receipt_dir: registry_dir)

    HedgeVenueMigrationRouteMatrix.stub(:new, matrix) do
      post migration_route_proof_position_path(position)
    end

    assert_response :redirect
    assert_match "Dry-run route proof wrote", flash[:notice]
    lines = File.readlines(receipt_path).drop(before_lines)
    assert_operator lines.size, :>, 0
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "migration_route_proof" }
    assert receipt
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
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

  test "random rotation setup panel guides new extended position without terminal commands" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "Random Rotation Setup", response.body
    assert_match "Dashboard setup wizard", response.body
    assert_match "Status:", response.body
    assert_match "Current venue:", response.body
    assert_match "Extended", response.body
    assert_match "0 / 6 READY_FOR_RANDOM", response.body
    assert_match "Final random rotation stays blocked until every route is ready.", response.body
    assert_match "Prepare Next Route", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "Live order possible?", response.body
    assert_match "No", response.body
    assert_match "Route setup progress:", response.body
    assert_match "Advanced details", response.body
    assert_no_match "Hyperliquid -&gt;", response.body
    assert_no_match "Random rotation setup did not load", response.body
    assert_no_match "0 ready / 0 total", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "random rotation setup renders out of tolerance blocker with route matrix" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "2.166",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    position.update!(asset0_amount: BigDecimal("2.248279624519602"))
    position.position_dashboard_snapshot.update!(
      target_short_eth: "2.248279624519602",
      tolerance_abs_eth: "0.06744838873558806",
      combined_short_eth: "2.166",
      drift_eth: "0.082279624519602",
      inside_tolerance: false
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "Setup blocked / current hedge out of tolerance", response.body
    assert_match "Out of tolerance", response.body
    assert_match "Target 2.248280 ETH", response.body
    assert_match "drift 0.082280 ETH", response.body
    assert_match "Extended 2.166000", response.body
    assert_match "0 / 6 READY_FOR_RANDOM", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "Rebalance current hedge first", response.body
    assert_no_match "Random rotation setup did not load", response.body
    assert_no_match "0 ready / 0 total", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "random rotation setup tolerates readiness slower than old 300ms timeout" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    readiness_factory = ->(**kwargs) do
      Object.new.tap do |object|
        object.define_singleton_method(:report) do
          sleep 0.4
          proof_report = kwargs.fetch(:proof_registry).report(position: kwargs.fetch(:position))
          {
            action: "migration_random_readiness",
            position_id: kwargs.fetch(:position).id,
            current_production_venue: "extended",
            next_recommended_canary: proof_report.fetch(:missing_route_proofs).find { |route| route[:from_venue] == "extended" },
            completed_route_proofs: proof_report.fetch(:completed_route_proofs),
            missing_route_proofs: proof_report.fetch(:missing_route_proofs),
            stale_route_proofs: [],
            pending_nado_target_continuation: nil,
            pending_nado_target_continuation_blocking: false,
            stale_pending_continuation_ignored: false,
            blockers: [
              "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true",
              "MIGRATION_LIVE_ENABLED must be true",
              "all route proofs must be READY_FOR_RANDOM"
            ],
            orders_submitted: 0,
            orders_placed: 0,
            signatures_created: 0
          }
        end
      end
    end

    MigrationRandomReadiness.stub(:new, readiness_factory) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "Random Rotation Setup", response.body
    assert_match "0 / 6 READY_FOR_RANDOM", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_no_match "Random rotation setup did not load", response.body
    assert_no_match "0 ready / 0 total", response.body
  end

  test "random rotation setup falls back to route matrix when readiness raises" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)

    MigrationRouteProofRegistry.stub(:new, registry) do
      MigrationRandomReadiness.stub(:new, ->(**) { raise "random readiness failed in test" }) do
        get position_path(position, hedge_venue: "extended", tab: "migration")
      end
    end

    assert_response :success
    assert_match "Setup loaded with limited diagnostics", response.body
    assert_match "0 / 6 READY_FOR_RANDOM", response.body
    assert_match "Final random rotation stays blocked until every route is ready.", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "Random readiness refresh needed", response.body
    assert_no_match "0 ready / 0 total", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "random rotation setup shows live canary CTA after dry run proof" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_dry_run_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "Dry-run complete / supervised canary required", response.body
    assert_match "Run Supervised Live Canary", response.body
    assert_match MigrationManualLiveCanaryRunner::CONFIRMATION, response.body
    assert_match "Route setup progress:", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "dry-run proven, live canary required", response.body
    assert_match "0 / 6 READY_FOR_RANDOM", response.body
    assert_match "Random enablement blockers", response.body
    assert_no_match "Next safe action</p>\n      <p class=\"mt-1 text-sm text-gray-300\">Prepare Next Route</p>", response.body
  end

  test "random rotation setup keeps final random blockers separate from canary CTA" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_dry_run_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "Run Supervised Live Canary", response.body
    assert_match "Random enablement blockers", response.body
    assert_match "all route proofs must be READY_FOR_RANDOM", response.body
  end

  test "random rotation setup offers source move instead of canary for flat non-current source" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_ready_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "ethereal", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "extended", to: "nado", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "nado", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_dry_run_route_proof(position, from: "ethereal", to: "nado", receipt_dir: registry_dir.join("random"))
    write_dry_run_route_proof(position, from: "nado", to: "ethereal", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "4 / 6 READY_FOR_RANDOM", response.body
    assert_match "Move to required source venue", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "Ethereal", response.body
    assert_match "Nado", response.body
    assert_no_match "Run Supervised Live Canary", response.body
    assert_no_match "Prepare Next Route", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "random rotation setup repositions before failed repair route with flat non-current source" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_ready_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "ethereal", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "extended", to: "nado", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "nado", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_failed_route_proof(position, from: "ethereal", to: "nado", receipt_dir: registry_dir.join("canaries"))
    write_dry_run_route_proof(position, from: "nado", to: "ethereal", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "extended", tab: "migration")
    end

    assert_response :success
    assert_match "4 / 6 READY_FOR_RANDOM", response.body
    assert_match "Move to required source venue", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "Ethereal", response.body
    assert_match "Nado", response.body
    assert_no_match "Run Supervised Live Canary", response.body
    assert_no_match "Prepare Next Route", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "limited diagnostics fallback keeps source reposition before Nado target repair" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_ready_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "ethereal", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "extended", to: "nado", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "nado", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_failed_route_proof(position, from: "ethereal", to: "nado", receipt_dir: registry_dir.join("canaries"))
    write_dry_run_route_proof(position, from: "nado", to: "ethereal", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      MigrationRandomReadiness.stub(:new, ->(**) { raise "random readiness failed in test" }) do
        get position_path(position, hedge_venue: "extended", tab: "migration")
      end
    end

    assert_response :success
    assert_match "Setup loaded with limited diagnostics", response.body
    assert_match "Move to required source venue", response.body
    assert_match "Extended -&gt; Ethereal", response.body
    assert_match "limited_diagnostics", response.body
    assert_match "fallback_used", response.body
    assert_no_match "Run Supervised Live Canary", response.body
    assert_no_match "Prepare Next Route", response.body
  ensure
    FileUtils.rm_rf(registry_dir) if registry_dir
  end

  test "random rotation prepare next route is dry run only and preserves migration tab" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    assert_no_difference "ShortRebalance.count" do
      post random_rotation_prepare_next_route_position_path(position), params: {
        tab: "migration",
        from_venue: "extended",
        to_venue: "ethereal"
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_includes response.location, "preview_from_venue=extended"
    assert_includes response.location, "preview_to_venue=ethereal"
    assert_match "orders_submitted=0, orders_placed=0, signatures_created=0, cancels_submitted=0", flash[:notice]
    assert_no_match "signatures_created=1", flash[:notice]
  end

  test "random rotation live canary rejects wrong phrase without submitting" do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )

    runner = Object.new
    runner.define_singleton_method(:run) { raise "canary runner must not be called with a wrong phrase" }
    assert_no_difference "ShortRebalance.count" do
      MigrationManualLiveCanaryRunner.stub(:new, runner) do
        post random_rotation_live_canary_position_path(position), params: {
          tab: "migration",
          from_venue: "extended",
          to_venue: "ethereal",
          random_rotation_confirmation: "WRONG"
        }
      end
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_match "submitted confirmation must equal #{MigrationManualLiveCanaryRunner::CONFIRMATION}", flash[:alert]
    assert_match "orders_submitted=0", flash[:alert]
    assert_match "orders_placed=0", flash[:alert]
    assert_match "signatures_created=0", flash[:alert]
    assert_match "cancels_submitted=0", flash[:alert]
    assert_equal false, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
  end

  test "stale invalid canary request remains blocked and tells operator to move source first" do
    OperationalSetting.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )

    assert_no_difference "ShortRebalance.count" do
      post random_rotation_live_canary_position_path(position), params: {
        tab: "migration",
        from_venue: "ethereal",
        to_venue: "nado",
        migration_sequence: "target_first",
        random_rotation_confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_no_match "preview_from_venue=ethereal", response.location
    assert_match "position hedge execution_venue must be ethereal before migration", flash[:alert]
    assert_match "source venue must have a real short before canary", flash[:alert]
    assert_match "orders_submitted=0", flash[:alert]
    assert_match "orders_placed=0", flash[:alert]
    assert_match "signatures_created=0", flash[:alert]
    assert_match "cancels_submitted=0", flash[:alert]
    assert_match "Move to Ethereal first", flash[:alert]
  end

  test "random rotation live canary accepts exact phrase and calls supervised canary runner" do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    captured = {}
    runner = Object.new
    runner.define_singleton_method(:run) do |**kwargs|
      captured.merge!(kwargs)
      MigrationManualLiveCanaryRunner::Result.new(
        "LIVE_CANARY_CONFIRMED",
        [],
        [],
        {
          from_venue: kwargs.fetch(:from),
          to_venue: kwargs.fetch(:to),
          orders_submitted: 2,
          orders_placed: 2,
          signatures_created: 2,
          exchange_order_ids: [ "test-order-1", "test-order-2" ]
        }
      )
    end

    MigrationManualLiveCanaryRunner.stub(:new, runner) do
      post random_rotation_live_canary_position_path(position), params: {
        tab: "migration",
        from_venue: "extended",
        to_venue: "ethereal",
        migration_sequence: "target_first",
        random_rotation_confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_equal position, captured.fetch(:position)
    assert_equal "extended", captured.fetch(:from)
    assert_equal "ethereal", captured.fetch(:to)
    assert_equal "target_first", captured.fetch(:sequence)
    assert_equal MigrationManualLiveCanaryRunner::CONFIRMATION, captured.fetch(:confirmation)
    assert_equal true, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_FULL_ALLOWED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_match "Supervised live canary LIVE_CANARY_CONFIRMED", flash[:notice]
  end

  test "random rotation live canary exact phrase enables Nado supervised gates only" do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    captured = {}
    runner = Object.new
    runner.define_singleton_method(:run) do |**kwargs|
      captured.merge!(kwargs)
      MigrationManualLiveCanaryRunner::Result.new(
        "TARGET_LEG_FAILED_SOURCE_UNCHANGED",
        [ "mock stopped before live submit" ],
        [],
        {
          from_venue: kwargs.fetch(:from),
          to_venue: kwargs.fetch(:to),
          orders_submitted: 0,
          orders_placed: 0,
          signatures_created: 0
        }
      )
    end

    MigrationManualLiveCanaryRunner.stub(:new, runner) do
      post random_rotation_live_canary_position_path(position), params: {
        tab: "migration",
        from_venue: "extended",
        to_venue: "nado",
        migration_sequence: "target_first",
        random_rotation_confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_equal position, captured.fetch(:position)
    assert_equal "extended", captured.fetch(:from)
    assert_equal "nado", captured.fetch(:to)
    assert_equal "target_first", captured.fetch(:sequence)
    assert_equal true, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_FULL_ALLOWED")
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
  end

  test "random rotation setup reconciles completed Extended to Nado and shows next Nado to Ethereal" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "nado")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1.25",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    registry_dir = Rails.root.join("tmp/random-rotation-controller-#{SecureRandom.hex(4)}")
    registry = isolated_route_registry(registry_dir)
    write_ready_route_proof(position, from: "extended", to: "ethereal", receipt_dir: registry_dir.join("canaries"))
    write_ready_route_proof(position, from: "ethereal", to: "extended", receipt_dir: registry_dir.join("canaries"))
    write_dry_run_route_proof(position, from: "extended", to: "nado", receipt_dir: registry_dir.join("random"))

    MigrationRouteProofRegistry.stub(:new, registry) do
      get position_path(position, hedge_venue: "nado", tab: "migration")
    end

    assert_response :success
    assert_match "Current venue:", response.body
    assert_match "Nado", response.body
    assert_match "2 / 6 READY_FOR_RANDOM", response.body
    assert_match "Nado -&gt; Ethereal", response.body
    assert_match "Prepare Next Route", response.body
    assert_no_match "Run Supervised Live Canary", response.body
    assert_no_match "active hedge-ready Mellow Autopilot position is required", response.body
  end

  test "random rotation finalize is idempotent and submits no orders" do
    OperationalSetting.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1.25",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    position.position_dashboard_snapshot.update!(production_venue: "extended", selected_venue: "extended")

    assert_no_difference "ShortRebalance.count" do
      post random_rotation_finalize_position_path(position), params: {
        tab: "migration",
        from_venue: "extended",
        to_venue: "nado",
        random_rotation_confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
      }
    end

    assert_response :redirect
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_includes response.location, "tab=migration"
    assert_no_match "preview_from_venue=extended", response.location
    assert_match "Migration finalization MIGRATION_FINALIZED_BY_READBACK", flash[:notice]
    assert_match "orders_submitted=0", flash[:notice]
    assert_match "orders_placed=0", flash[:notice]
    assert_match "signatures_created=0", flash[:notice]
    assert_match "cancels_submitted=0", flash[:notice]
  end

  test "random rotation live canary stale already complete result clears old route params" do
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "nado")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1.25",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    runner = Object.new
    runner.define_singleton_method(:run) do |**kwargs|
      MigrationManualLiveCanaryRunner::Result.new(
        "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
        [],
        [],
        {
          from_venue: kwargs.fetch(:from),
          to_venue: kwargs.fetch(:to),
          orders_submitted: 0,
          orders_placed: 0,
          signatures_created: 0,
          cancels_submitted: 0,
          exchange_order_ids: []
        }
      )
    end

    MigrationManualLiveCanaryRunner.stub(:new, runner) do
      post random_rotation_live_canary_position_path(position), params: {
        tab: "migration",
        from_venue: "extended",
        to_venue: "nado",
        random_rotation_confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_no_match "preview_from_venue=extended", response.location
    assert_match "Supervised live canary STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE", flash[:notice]
    assert_match "orders_submitted=0", flash[:notice]
    assert_match "orders_placed=0", flash[:notice]
    assert_match "signatures_created=0", flash[:notice]
    assert_match "cancels_submitted=0", flash[:notice]
  end

  test "random rotation enable writes DB operational settings when all routes are ready" do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )
    setup = {
      enable_blockers: [],
      next_route: { from_venue: "extended", to_venue: "ethereal", route: "extended->ethereal" }
    }

    RandomRotationSetupWizard.stub(:new, ->(**) { Object.new.tap { |object| object.define_singleton_method(:report) { setup } } }) do
      post random_rotation_enable_position_path(position), params: {
        tab: "migration",
        random_rotation_confirmation: RandomRotationSetupWizard::ENABLE_CONFIRMATION
      }
    end

    assert_response :redirect
    assert_includes response.location, "tab=migration"
    assert_equal true, OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal true, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_match "active venue auto is enabled only for Extended", flash[:notice]
    assert_match "No orders or signatures were created", flash[:notice]
  end

  test "random rotation enable remains blocked until all six routes are ready" do
    OperationalSetting.delete_all
    position = create_aerodrome_position
    clear_migration_receipts_for_position(position.id)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )

    assert_no_difference "ShortRebalance.count" do
      post random_rotation_enable_position_path(position), params: {
        tab: "migration",
        random_rotation_confirmation: RandomRotationSetupWizard::ENABLE_CONFIRMATION
      }
    end

    assert_response :redirect
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_match "all route proofs must be READY_FOR_RANDOM", flash[:alert]
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
    fast_unified_readiness = Class.new do
      def report(position:)
        {
          status: "ok",
          execution_venue: position.hedge.execution_venue,
          active_auto_venue: position.hedge.execution_venue,
          active_within_tolerance: true,
          within_tolerance: true,
          planned_auto_action: "no_op",
          target_short_eth: "1.0",
          active_current_short_eth: "1.0",
          continuous_auto_ready: true,
          active_auto_ready: true,
          blockers: [],
          active_auto_blockers: [],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end.new

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AerodromeRewardsCheck.stub(:new, blocked_reader) do
      AerodromeFeesCheck.stub(:new, blocked_reader) do
        ExtendedAutoReadiness.stub(:new, blocked_reader) do
          HedgeVenueAutoReadiness.stub(:new, fast_unified_readiness) do
            get position_path(position, hedge_venue: "extended")
          end
        end
      end
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :success
    assert_operator elapsed, :<, 3.0
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
    assert_match "EXTENDED_LIVE_ENABLED must be true", flash[:alert]
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
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.25",
      tolerance_abs_eth: "0.0625",
      combined_short_eth: "0",
      drift_eth: "1.25",
      inside_tolerance: false,
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_short_eth: "0"
    )

    with_env(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_MAX_SHORT_ETH" => "2.3",
      "ETHEREAL_MAX_ORDER_SIZE_ETH" => "2.3",
      "ETHEREAL_MAX_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_SHORT_ETH" => "2.3",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "2.3",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "2.3",
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
    assert_match AerodromeDashboardHedgeAction::ETHEREAL_CONFIRMATION, response.body
    assert_select "input#dashboard-hedge-confirmation-open[name='dashboard_hedge_confirmation']" do |inputs|
      assert_equal 1, inputs.size
      assert_nil inputs.first["disabled"]
      assert_equal AerodromeDashboardHedgeAction::ETHEREAL_CONFIRMATION, inputs.first["data-required-confirmation"]
    end
    assert_select "input#dashboard-hedge-live-submit-open[disabled]", 1
    assert_match "document.getElementById(this.dataset.liveSubmitId).disabled = this.value !== this.dataset.requiredConfirmation", response.body
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
    assert_match "Detailed live preflight loads separately;", response.body
    assert_match "Live submit is disabled for Nado; previews do not create orders.", response.body
    assert_match "Nado Hedge Actions", response.body
  end

  test "show selected Nado venue enables manual rebalance input when auto is disabled" do
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
    create_dashboard_snapshot(position, extended_short_eth: "0", ethereal_short_eth: "0", nado_short_eth: "1.40")
    OperationalSettings.set!(key: "AERODROME_NADO_HEDGE_LIVE_ENABLED", enabled: true)
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: false)

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position, hedge_venue: "nado")
    end

    assert_response :success
    assert_match "Rebalance Hedge", response.body
    assert_match AerodromeDashboardHedgeAction::NADO_CONFIRMATION, response.body
    assert_select "input#dashboard-hedge-confirmation-rebalance[disabled]", count: 0
    assert_no_match "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true", response.body
  end

  test "show active unhedged position puts hedge tab and open hedge risk cap near top" do
    position = create_aerodrome_position(asset0_price_usd: BigDecimal("2000"), active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")

    with_env(
      "ETHEREAL_MAX_SHORT_ETH" => "1.0",
      "ETHEREAL_MAX_ORDER_SIZE_ETH" => "1.0",
      "ETHEREAL_MAX_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.0",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "2.0",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "2.0"
    ) do
      get position_path(position)
    end

    assert_response :success
    assert_match "tab=hedge", response.body
    assert_no_match "href=\"#hedge\"", response.body
    assert_match "Hedge Control Center", response.body
    assert_match "Open Hedge Preview", response.body
    assert_match "Risk Cap Status", response.body
    assert_match "ETHEREAL_MAX_SHORT_ETH", response.body
    assert_match "Minimum required cap", response.body
    assert_match "Active production position", response.body
    assert_no_match "Make Active Production Position", response.body
  end

  test "show hedge tab presents recommended risk dependency fix" do
    RiskSetting.delete_all
    position = create_aerodrome_position(asset0_price_usd: BigDecimal("2000"), active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      selected_venue: "ethereal",
      production_venue: "ethereal",
      target_short_eth: "1.66",
      combined_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_short_eth: "0",
      drift_eth: "1.66",
      inside_tolerance: false
    )
    {
      "ETHEREAL_MAX_SHORT_ETH" => "2.3",
      "ETHEREAL_MAX_ORDER_SIZE_ETH" => "2.3",
      "ETHEREAL_MAX_NOTIONAL_USD" => "4200",
      "AERODROME_MAX_SHORT_ETH" => "3.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4200",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD" => "4200",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "4200"
    }.each { |key, value| RiskSetting.create!(key: key, value: value) }

    with_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "1.6") do
      get position_path(position, hedge_venue: "ethereal", tab: "hedge")
    end

    assert_response :success
    assert_match "Recommended fix available", response.body
    assert_match "Lower Global max short size from 3.5 to 2.1 ETH", response.body
    assert_match "Set Emergency close max ETH from 1.6 to 2.1 ETH", response.body
    assert_match "Apply recommended limits", response.body
    assert_match RiskSettings::INCREASE_CONFIRMATION, response.body
  end

  test "show initial render does not run slow hedge venue auto readiness" do
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")

    HedgeVenueAutoReadiness.stub(:new, ->(*) { raise "slow readiness should not run during initial render" }) do
      get position_path(position, hedge_venue: "ethereal", tab: "hedge")
    end

    assert_response :success
    assert_match "Diagnostics not loaded", response.body
    assert_match "Hedge Control Center", response.body
  end

  test "show inactive position exposes make active and inactive label" do
    position = create_aerodrome_position(active: false)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: false, execution_venue: "ethereal")

    get position_path(position)

    assert_response :success
    assert_match "Inactive / archived", response.body
    assert_match "Make Active Production Position", response.body
  end

  test "show active Ethereal position exposes enable auto control when auto is off" do
    OperationalSetting.delete_all
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      tolerance_abs_eth: "0.048",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0",
      ethereal_auto_enabled: false,
      signer_status: "ok"
    )

    with_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true") do
      get position_path(position, hedge_venue: "ethereal", tab: "accounting")
    end

    assert_response :success
    assert_match "Auto-Rebalance Controls", response.body
    assert_match "Enable Ethereal Auto", response.body
    assert_match OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal"), response.body
    assert_match "This only changes the auto loop setting. It does not submit an order.", response.body
  end

  test "show active Ethereal position exposes disable auto control when auto is on" do
    OperationalSetting.delete_all
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0",
      signer_status: "ok"
    )
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true)

    with_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true") do
      get position_path(position, hedge_venue: "ethereal", tab: "accounting")
    end

    assert_response :success
    assert_match "Auto On", response.body
    assert_no_match "Auto: Auto On", response.body
    assert_no_match "Auto: Auto Off", response.body
    assert_match "Disable Ethereal Auto", response.body
    assert_match OperationalSettings::DISABLE_CONFIRMATIONS.fetch("ethereal"), response.body
  end

  test "auto rebalance toggle sets DB overrides without orders" do
    OperationalSetting.delete_all
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0",
      signer_status: "ok"
    )

    with_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true") do
      post auto_rebalance_position_path(position), params: {
        venue: "ethereal",
        enabled: "true",
        auto_confirmation: OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal")
      }
    end

    assert_redirected_to position_path(position, hedge_venue: "ethereal", tab: "accounting")
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
  end

  test "enable auto for current venue only keeps random and migration disabled" do
    OperationalSetting.delete_all
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "1.25",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      refreshed_at: Time.current,
      extended_attrs: { leverage_margin_gate_status: "pass", open_orders_count: 0 }
    )

    with_env("EXTENDED_LIVE_ENABLED" => "true") do
      assert_no_difference "ShortRebalance.count" do
        post auto_rebalance_position_path(position), params: {
          tab: "migration",
          venue: "extended",
          enabled: "true",
          auto_confirmation: OperationalSettings::ENABLE_CONFIRMATIONS.fetch("extended")
        }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "extended", tab: "migration")
    assert_equal true, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
  end

  test "auto rebalance toggle rejects wrong confirmation without changing settings" do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0",
      signer_status: "ok"
    )

    with_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true") do
      assert_no_difference [ "OperationalSetting.count", "OperationalSettingAudit.count", "ShortRebalance.count" ] do
        post auto_rebalance_position_path(position), params: {
          venue: "ethereal",
          enabled: "true",
          auto_confirmation: "WRONG"
        }
      end
    end

    assert_redirected_to position_path(position, hedge_venue: "ethereal", tab: "accounting")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    follow_redirect!
    assert_match "Auto setting blocked: confirmation must equal #{OperationalSettings::ENABLE_CONFIRMATIONS.fetch('ethereal')}", response.body
  end

  test "show tab navigation does not change active production selection" do
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")

    get position_path(position, hedge_venue: "ethereal", tab: "hedge")
    assert_response :success
    assert_predicate position.reload, :active?
    assert_match "Active production position", response.body
    assert_no_match "Archived app record", response.body
    assert_no_match "Make Active Production Position", response.body

    get position_path(position, hedge_venue: "ethereal", tab: "accounting")
    assert_response :success
    assert_predicate position.reload, :active?
    assert_match "Active production position", response.body
    assert_no_match "Archived app record", response.body
  end

  test "refresh read-only data action does not change active production selection" do
    position = create_aerodrome_position(active: true)
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")

    assert_enqueued_with(job: PositionSyncJob, args: [ position.id ]) do
      assert_enqueued_with(job: DashboardSnapshotJob, args: [ position.id, { force: true } ]) do
        post sync_now_position_path(position)
      end
    end

    assert_redirected_to position_path(position)
    assert_predicate position.reload, :active?
    assert_predicate position.hedge.reload, :active?
  end

  test "hedge venue selection persists to hedge" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    patch hedge_venue_position_path(position), params: { hedge_venue: "nado" }

    assert_redirected_to position_path(position)
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

    assert_redirected_to position_path(position)
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
    assert_match "submitted confirmation must equal", flash[:alert]
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
    assert_match "Close preview", flash[:notice]
    assert_match "Target 1.25 ETH", flash[:notice]
  end

  test "show renders rebalance history block with no hedge empty state" do
    position = create_aerodrome_position

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Recent Rebalance History", response.body
    assert_match "No Nado rebalance history yet.", response.body
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
    assert_match "No Nado rebalance history yet.", response.body
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
    assert_match "Previous venue history", response.body
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
    assert_match "Partial PnL Excluding Rewards / Fees", response.body
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

  test "show displays current share-token source and does not block on old hedge_ready false" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      asset0_amount: "0.8",
      asset1_amount: "500",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      mellow_metadata: {
        "hedge_ready" => false,
        "exposure_source" => "current_share_token_resolver",
        "successful_method" => "previewMint(uint256)",
        "last_current_exposure_at" => Time.current.iso8601,
        "last_probe_confidence" => "low",
        "user_weth_exposure" => "0.8",
        "user_usdc_exposure" => "500",
        "user_total_value_usd" => "2100"
      }.to_json
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.74",
      drift_eth: "0.06",
      inside_tolerance: false,
      extended_short_eth: "0.74",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      planned_auto_action: "increase_short"
    )

    readiness = extended_readiness(
      position,
      within_tolerance: false,
      planned_auto_action: "increase_short",
      target: "0.8",
      current: "0.74",
      drift: "0.06",
      tolerance: "0.024"
    )

    ExtendedAutoReadiness.stub(:new, ReadinessFactory.new(readiness)) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "current_share_token_resolver", response.body
    assert_match "previewMint(uint256)", response.body
    assert_match "SELL non-reduce-only / increase short", response.body
    assert_no_match "Mellow Autopilot pro-rata exposure is not hedge-ready", response.body
  end

  test "dashboard header uses cached snapshot and defers Extended readiness" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false, snapshot_target: "9.9")

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Operations / Migration Safety", response.body
    assert_match "Out of tolerance", response.body
    assert_match "Initial render uses cached dashboard snapshot; refresh diagnostics for venue readiness.", response.body
    assert_match "9.900000", response.body
  end

  test "dashboard initial render defers anti churn diagnostics" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Operations / Migration Safety", response.body
    assert_match "Auto diagnostics are loaded separately.", response.body
    assert_no_match "Auto should act", response.body
  end

  test "hedge preview unavailable remains isolated to explicit preview state" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: true)
    position.update!(asset0_price_usd: nil)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "In tolerance", response.body
    assert_match "Initial render uses cached dashboard snapshot; refresh diagnostics for venue readiness.", response.body
  end

  test "emergency section uses cached inside tolerance state on initial render" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Manual recovery only", response.body
  end

  test "migration preview outside tolerance does not override cached production state" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Disabled unless manually gated", response.body
    assert_match "Out of tolerance", response.body
    assert_no_match "Full migration correction", response.body
  end

  test "cached decrease short action hides old preview unavailable warning" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false)
    position.position_dashboard_snapshot.update!(
      target_short_eth: "0.8",
      combined_short_eth: "0.86",
      extended_short_eth: "0.86",
      drift_eth: "-0.06",
      planned_auto_action: "decrease_short"
    )
    position.update!(asset0_price_usd: nil)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "BUY reduce-only / reduce short", response.body
  end

  test "cached no-op hides old preview unavailable warning" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: true)
    position.position_dashboard_snapshot.update!(planned_auto_action: "no_op")
    position.update!(asset0_price_usd: nil)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "No-op / inside tolerance", response.body
  end

  test "current resolver ok prevents stale Mellow pro rata warning in main PnL summary" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: true)
    metadata = position.mellow_metadata_hash.merge(
      "exposure_source" => "current_share_token_resolver",
      "successful_method" => "previewMint(uint256)",
      "user_total_value_usd" => nil
    )
    position.update!(mellow_metadata: metadata.to_json)
    readiness = extended_readiness(position, within_tolerance: true, planned_auto_action: "no_op")

    ExtendedAutoReadiness.stub(:new, ReadinessFactory.new(readiness)) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "current_share_token_resolver", response.body
    assert_match "previewMint(uint256)", response.body
    assert_no_match "Mellow pro-rata value is stale or unavailable.", response.body
  end

  test "legacy rewards ERC721 nonexistent token is labeled as legacy rewards fees unavailable" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: true)
    position.update!(
      mellow_metadata: position.mellow_metadata_hash.merge(
        "strategy_token_id" => "71261528",
        "exposure_source" => "current_share_token_resolver",
        "successful_method" => "previewMint(uint256)"
      ).to_json
    )
    position.create_position_rewards_fees_snapshot!(
      refresh_status: "failed",
      refreshed_at: Time.current,
      rewards_value_state: "unavailable",
      fee_value_state: "unavailable",
      rewards_stop_reason: "ERC721 owner query failed for nonexistent token 71261528",
      warnings: [ "ERC721 owner query failed for nonexistent token 71261528" ].to_json
    )
    readiness = extended_readiness(position, within_tolerance: true, planned_auto_action: "no_op")

    ExtendedAutoReadiness.stub(:new, ReadinessFactory.new(readiness)) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Legacy rewards/fees read unavailable for historical token 71261528", response.body
    assert_match "Current hedge exposure uses current_share_token_resolver", response.body
    assert_no_match "Mellow pro-rata value is stale or unavailable.", response.body
  end

  test "Production Health defers auto can act readiness on initial render" do
    position = mellow_extended_position_with_snapshot(snapshot_inside: false)

    ExtendedAutoReadiness.stub(:new, -> { raise "initial render must not load readiness" }) do
      get position_path(position, hedge_venue: "extended")
    end

    assert_response :success
    assert_match "Operations / Migration Safety", response.body
    assert_match "BLOCKED", response.body
    assert_match "Initial render uses cached dashboard snapshot; refresh diagnostics for venue readiness.", response.body
    assert_no_match "Auto can act", response.body
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
    assert_match "Partial PnL Excluding Rewards / Fees", response.body
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

  ReadinessFactory = Struct.new(:payload) do
    def report(position:)
      payload
    end
  end

  def extended_readiness(position, within_tolerance:, planned_auto_action:, suppressed: nil, target: "0.8", current: "0.79", drift: "0.01", tolerance: "0.024", auto_can_act: nil)
    {
      venue: "extended",
      action: "auto_readiness",
      position_id: position.id,
      hedge_id: position.hedge.id,
      execution_venue: "extended",
      target_short_eth: target,
      target_source: "current_share_token_fallback",
      exposure_source: "current_share_token_fallback",
      exposure_refreshed_at: Time.current.iso8601,
      exposure_stale: false,
      extended_current_short_eth: current,
      drift_eth: drift,
      tolerance_eth: tolerance,
      within_tolerance: within_tolerance,
      drift_outside_tolerance: !within_tolerance,
      planned_auto_action: planned_auto_action,
      action_suppressed_reason: suppressed,
      min_rebalance_size_eth: "0.03",
      min_rebalance_notional_usd: "50.0",
      cooldown_remaining_seconds: 0,
      consecutive_outside_tolerance_required: 2,
      consecutive_outside_tolerance_count: 1,
      strong_drift_threshold: "0.048",
      drift_to_tolerance_ratio: "0.4166666667",
      strong_drift_bypass_used: false,
      planned_auto_order_size_eth: planned_auto_action == "no_op" ? nil : drift,
      auto_max_rebalance_size_eth: "0.1",
      partial_auto_rebalance: false,
      auto_can_act: auto_can_act.nil? ? suppressed.blank? && planned_auto_action != "no_op" : auto_can_act,
      ethereal_short_eth: "0",
      ethereal_flat: true,
      nado_short_eth: "0",
      nado_flat: true,
      continuous_auto_ready: suppressed.blank?,
      blockers: [],
      warnings: []
    }
  end

  def mellow_extended_position_with_snapshot(snapshot_inside:, snapshot_target: "1.25")
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      asset0_amount: "0.8",
      asset1_amount: "500",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      mellow_metadata: {
        "hedge_ready" => true,
        "exposure_source" => "current_share_token_fallback",
        "last_current_exposure_at" => Time.current.iso8601,
        "last_probe_confidence" => "current_share_token_fallback",
        "user_weth_exposure" => "0.8",
        "user_usdc_exposure" => "500",
        "user_total_value_usd" => "2100"
      }.to_json
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: 20.minutes.ago,
      refresh_status: "ok",
      stale: true,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: snapshot_target,
      tolerance_abs_eth: "0.0375",
      combined_short_eth: snapshot_inside ? snapshot_target : "0.1",
      drift_eth: snapshot_inside ? "0" : "1.15",
      inside_tolerance: snapshot_inside,
      extended_short_eth: snapshot_inside ? snapshot_target : "0.1",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      planned_auto_action: snapshot_inside ? "no_op" : "increase_short"
    )
    position
  end

  def create_aerodrome_position(id: nil, asset0_price_usd: BigDecimal("2000"), asset1_price_usd: BigDecimal("1"), external_id: "315985", pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", active: true)
    Position.create!(
      id: id,
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

  def import_params(dex:, wallet:, external_id:, deactivate_existing: "1")
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

  def production_random_position
    position = create_aerodrome_position(id: unique_random_production_position_id)
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "nado")
    position.update!(asset0_amount: "2.65")
    create_dashboard_snapshot(
      position,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "2.12",
      extended_attrs: { open_orders_count: 0, leverage_margin_gate_status: "pass" }
    )
    position
  end

  def unique_random_production_position_id
    @unique_random_production_position_id ||= 10_000_000_000 + (Process.pid * 1_000_000) + SecureRandom.random_number(1_000_000)
  end

  def random_production_dir
    MigrationRandomProductionRunner::LOG_DIR
  end

  def write_random_production_files(position, status: nil, heartbeat: nil, lock: nil, latest_event: nil)
    FileUtils.mkdir_p(random_production_dir)
    heartbeat ||= {
      runner: "random_production_runner",
      position_id: position.id,
      pid: Process.pid,
      started_at: Time.current.utc.iso8601,
      updated_at: Time.current.utc.iso8601,
      last_cycle: 3,
      last_route: "extended->nado",
      current_production_venue: "nado",
      target_short_eth: "2.12",
      combined_short_eth: "2.12",
      inside_tolerance: true,
      open_orders_zero: true,
      gates_enabled: true,
      last_hold_check_at: Time.current.utc.iso8601,
      status: "running"
    }
    lock = {
      runner: "random_production_runner",
      position_id: position.id,
      pid: Process.pid,
      started_at: Time.current.utc.iso8601,
      updated_at: Time.current.utc.iso8601
    } if lock.nil?
    status ||= {
      status: "running",
      direct_preflight_blockers: [],
      direct_open_orders: random_production_open_orders("zero"),
      direct_venue_shorts: random_production_shorts,
      inside_tolerance: true,
      route_proofs_summary: random_production_route_summary,
      gates_state: {
        "MIGRATION_LIVE_ENABLED" => true,
        "MIGRATION_AUTO_ENABLED" => true,
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => true
      },
      heartbeat: heartbeat
    }
    latest_event ||= {
      event: "cycle",
      cycle: 3,
      route: "extended->nado",
      status: "success",
      execution: { orders_submitted: 0 },
      post_cycle_hedge: { production_venue: "nado" },
      hold_rebalance_checks_count: 13,
      hold_monitor_actual_span_seconds: 3600,
      hold_monitor_gap_warning: nil,
      blockers: []
    }
    File.write(random_production_dir.join("heartbeat_position_#{position.id}.json"), JSON.pretty_generate(heartbeat))
    File.write(random_production_dir.join("status_position_#{position.id}.json"), JSON.pretty_generate(status))
    File.write(random_production_dir.join("latest_position_#{position.id}.jsonl"), "#{JSON.generate(latest_event)}\n")
    File.write(random_production_dir.join("lock_position_#{position.id}.json"), JSON.pretty_generate(lock)) if lock
  end

  def random_production_open_orders(status)
    HedgeVenues::SUPPORTED_KEYS.to_h { |venue| [ venue, { status: status, count: status == "zero" ? 0 : 1 } ] }
  end

  def random_production_shorts
    { "extended" => "0", "ethereal" => "0", "nado" => "2.12" }
  end

  def random_production_route_summary
    {
      "ready" => 6,
      "missing" => 0,
      "stale" => 0,
      "total" => 6
    }
  end

  def clear_random_production_files(position_id)
    return unless position_id

    %w[heartbeat status latest lock stop control control_result].each do |prefix|
      suffix = prefix == "latest" ? "jsonl" : "json"
      FileUtils.rm_f(random_production_dir.join("#{prefix}_position_#{position_id}.#{suffix}"))
    end
  end

  def write_ready_random_route_proofs(position)
    writer = HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_live_canaries"))
    MigrationRouteProofRegistry::ROUTES.each do |from, to|
      writer.write(
        action: "manual_live_canary",
        timestamp: Time.current.utc.iso8601,
        position_id: position.id,
        from_venue: from,
        to_venue: to,
        route: "#{from}->#{to}",
        final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
        target_leg_readback_confirmed: true,
        source_leg_readback_confirmed: true,
        final_inside_tolerance: true,
        source_flat_after: true,
        target_holds_expected_short: true,
        open_orders_after: 0,
        production_venue_finalized: true,
        orders_submitted: 1,
        orders_placed: 1,
        signatures_created: 1
      )
    end
  end

  def isolated_route_registry(base_dir)
    MigrationRouteProofRegistry.new(
      route_proof_dir: base_dir.join("route_proofs"),
      canary_dir: base_dir.join("canaries"),
      recovery_dir: base_dir.join("recoveries"),
      continuation_dir: base_dir.join("continuations"),
      random_dir: base_dir.join("random")
    )
  end

  def write_dry_run_route_proof(position, from:, to:, receipt_dir: Rails.root.join("storage/hedge_migration_random_rehearsals"))
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: receipt_dir).write(
      action: "random_migration_rehearsal",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      final_status: "dry_run",
      route_status: "READY_FOR_DRY_RUN",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )
  end

  def write_ready_route_proof(position, from:, to:, receipt_dir:)
    payload = {
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      cancels_submitted: 0
    }
    payload.merge!(nado_target_latency_proof_fields) if to == "nado"
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: receipt_dir).write(payload)
  end

  def nado_target_latency_proof_fields
    {
      migration_sequence: "source_first",
      route_latency_proof: true,
      production_safe_route: true,
      route_production_safe: true,
      double_exposure_seconds: "0",
      underhedge_seconds: "2.0",
      total_route_seconds: "4.0"
    }
  end

  def write_failed_route_proof(position, from:, to:, receipt_dir:)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: receipt_dir).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      final_status: "BLOCKED_BEFORE_SUBMIT",
      manual_action_required: true,
      blockers: [ "test repair required" ],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )
  end

  def clear_migration_receipts_for_position(position_id)
    Dir.glob(Rails.root.join("storage/hedge_migration_{route_proofs,random_rehearsals,live_canaries,recoveries,continuations}/*.jsonl")).each do |path|
      retained = File.readlines(path).reject do |line|
        JSON.parse(line)["position_id"].to_s == position_id.to_s
      rescue JSON::ParserError
        false
      end
      File.write(path, retained.join)
    rescue SystemCallError
      next
    end
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

  def random_production_control_guard(ok: false)
    RandomProductionControlGuard.new(ok: ok)
  end

  # Dashboard start runs a fresh fail-closed runner preflight; stub it clean so
  # dispatch-path tests exercise the control adapter deterministically.
  def stub_clean_start_preflight(&block)
    fake = Class.new do
      def start_preflight_blockers = []
    end.new
    MigrationRandomProductionRunner.stub(:new, ->(**_kwargs) { fake }, &block)
  end

  class RandomProductionControlGuard
    attr_reader :calls

    def initialize(ok:)
      @ok = ok
      @calls = []
    end

    def start(position:, mode:)
      @calls << [ :start, position.id, mode ]
      MigrationRandomProductionControl::Result.new(@ok, @ok ? "submitted" : "failed", @ok ? "submitted" : "blocked in test", [ "systemctl", "start" ])
    end

    def stop(position:)
      @calls << [ :stop, position.id ]
      MigrationRandomProductionControl::Result.new(@ok, @ok ? "submitted" : "failed", @ok ? "submitted" : "blocked in test", [ "systemctl", "stop" ])
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
      "AERODROME_MAX_ORDER_SIZE_ETH" => "1.5",
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
    stub_request(:get, "https://ethereal.example/v1/order?isWorking=true&limit=100&productIds=2&subaccountId=#{subaccount}")
      .to_return(status: 200, body: { data: [] }.to_json)
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
