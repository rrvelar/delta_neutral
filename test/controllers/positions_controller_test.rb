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
    assert_select "span", text: "MONITOR ONLY"
    assert_select "span", text: "NO ORDERS"
    assert_select "span", text: "HEDGE DISABLED"
    assert_select "span", text: "READ-ONLY HYPERLIQUID"
    assert_select "span", text: "NOT LIVE HEDGE-READY"
    assert_match "Aerodrome Slipstream", response.body
    assert_match "Token ID 315985", response.body
    assert_match "Refresh Read-only Data", response.body
    assert_match "Generate Manual Hedge Proposal", response.body
    assert_match "Manual proposal only", response.body
    assert_match "No orders", response.body
    assert_match "Updates on-chain LP data only", response.body
    assert_match "No Hyperliquid", response.body
    assert_match "Execution disabled", response.body
    assert_match "No hedge execution", response.body
    assert_match "PREVIEW ONLY", response.body
    assert_match "short", response.body
    assert_match "ETH", response.body
    assert_match "1.250000", response.body
    assert_match "$2,500.00", response.body
    assert_match "AERODROME_HEDGE_ENABLED must remain false", response.body
    assert_match "Production Hedge Dashboard", response.body
    assert_match "Current Hyperliquid ETH position", response.body
    assert_match "Dashboard Flow", response.body
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
    assert_match "Aerodrome Hedge Status", response.body
    assert_match "Hedge configured", response.body
    assert_match "yes", response.body
    assert_match "Target percent", response.body
    assert_match "50.00%", response.body
    assert_match "Tolerance percent", response.body
    assert_match "5.00%", response.body
    assert_match "Target ETH short", response.body
    assert_match "0.625000", response.body
    assert_match "Current Hyperliquid ETH position", response.body
    assert_match "current ETH readback unavailable", response.body
    assert_match "disabled", response.body
    assert_match "paused", response.body
    assert_match "testnet", response.body
    assert_match "live-blocked", response.body
    assert_match "AERODROME_HEDGE_ENABLED", response.body
    assert_match "AERODROME_HEDGE_PAUSED", response.body
    assert_match "AERODROME_LIVE_APPROVED", response.body
    assert_match "HYPERLIQUID_TESTNET", response.body
    assert_match "Last WETH/ETH Rebalance", response.body
    assert_match rebalance.id.to_s, response.body
    assert_match "0.400000", response.body
    assert_match "success", response.body
    assert_match "testnet rebalance complete", response.body
    assert_match "PnL Baseline", response.body
    assert_match "Entry value", response.body
    assert_match "$2,500.00", response.body
    assert_match "Current pooled value", response.body
    assert_match "$3,000.00", response.body
    assert_match "Pool delta from entry", response.body
    assert_match "$500.00", response.body
    assert_match "PnL baseline starts from first Aerodrome snapshot unless manually set.", response.body
    assert_match "Aerodrome LP Fees", response.body
    assert_match "Collecting fees is not implemented", response.body
    assert_no_match "Hedge: None", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
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
    assert_match "AERO Rewards", response.body
    assert_match "Read-only. Claiming is not implemented. Rewards are not included in Total PnL.", response.body
    assert_match "Claimable AERO", response.body
    assert_match "Claimable AERO USD", response.body
    assert_match "not configured", response.body
    assert_match "unavailable", response.body
    assert_match "AERO USD price source", response.body
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
      AerodromeRewardsCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
          get position_path(position)
        end
      end
    end

    assert_response :success
    assert_match "AERO Rewards", response.body
    assert_match "detected", response.body
    assert_match "true", response.body
    assert_match "14.140000", response.body
    assert_match "$0.500000", response.body
    assert_match "manual", response.body
    assert_match "$7.07", response.body
    assert_match "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6", response.body
    assert_match "env", response.body
    assert_match "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28", response.body
    assert_match "Read-only. Claiming is not implemented. Rewards are not included in Total PnL.", response.body
    assert_match "$500.00", response.body
    assert_match "Total PnL Excluding Rewards / Fees", response.body
    assert_match "Total PnL Including Unclaimed AERO Rewards Estimate", response.body
    assert_match "$507.07", response.body
    assert_match "Unclaimed rewards are not realized until claimed/sold", response.body
    assert_no_match "Claim rewards", response.body
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
      AerodromeRewardsCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { rewards_report } }
      }) do
        AerodromeFeesCheck.stub(:new, -> {
          Object.new.tap { |object| object.define_singleton_method(:report) { fees_report } }
        }) do
          HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
            get position_path(position)
          end
        end
      end
    end

    assert_response :success
    assert_match "Aerodrome LP Fees", response.body
    assert_match "nonfungible_position_manager.positions.tokens_owed", response.body
    assert_match "0.010000 WETH", response.body
    assert_match "$20.00", response.body
    assert_match "3.500000 USDC", response.body
    assert_match "$23.50", response.body
    assert_match "Total PnL Excluding Rewards / Fees", response.body
    assert_match "Total PnL Including Rewards + LP Fees Estimate", response.body
    assert_match "$530.57", response.body
    assert_match "Unclaimed fees are not realized PnL until collected", response.body
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
      AerodromeFeesCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { fees_report } }
      }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "Aerodrome LP Fees", response.body
    assert_match "unavailable", response.body
    assert_match "fee read for staked Slipstream NFT is not verified", response.body
    assert_match "Including fees unavailable", response.body
    assert_no_match "Aerodrome fee read not implemented yet.", response.body
  end

  test "show renders unavailable AERO rewards when check raises" do
    position = create_aerodrome_position

    with_env("AERODROME_REWARDS_ENABLED" => "true") do
      AerodromeRewardsCheck.stub(:new, -> { raise AerodromeRewardsService::RpcError, "RPC unavailable" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_match "AERO Rewards", response.body
    assert_match "unavailable", response.body
    assert_match "RPC unavailable", response.body
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

  def create_aerodrome_position(asset0_price_usd: BigDecimal("2000"), asset1_price_usd: BigDecimal("1"))
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
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
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
