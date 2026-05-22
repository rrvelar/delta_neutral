require "test_helper"

class MellowAutopilotProbesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "renders probe form" do
    get mellow_autopilot_probe_path

    assert_response :success
    assert_match "Mellow Autopilot Probe", response.body
    assert_select "input[name='wallet_address']"
    assert_select "input[name='vault_address']"
    assert_select "input[name='network']"
  end

  test "renders probe results" do
    report = {
      source: "Mellow official points API",
      network: "base",
      hedge_target_computable: true,
      blockers: [],
      warnings: [],
      positions: [
        {
          vault_name: "Mellow WETH/USDC Autopilot",
          vault_identifier: "vault-1",
          position_type: "direct_lp_nft",
          strategy_token_id: "71141789",
          vault_address: "0xvault",
          receipt_share_amount: "12.5",
          total_shares: nil,
          weth_amount: "0.42",
          usdc_amount: "234.56",
          total_value_usd: "1234.56",
          hedgeable: true
        }
      ]
    }

    MellowAutopilotPositionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
          get mellow_autopilot_probe_path, params: { wallet_address: "0xabc", vault_address: "0xvault" }
        end
      end
    end

    assert_response :success
    assert_match "Mellow WETH/USDC Autopilot", response.body
    assert_match "0.42", response.body
    assert_match "234.56", response.body
    assert_match "$1,234.56", response.body
    assert_match "hedge target computable", response.body
    assert_match "Direct LP token IDs can be hedged", response.body
    assert_match "Autopilot/Mellow shared strategy token IDs require user share accounting", response.body
    assert_match "direct_lp_nft", response.body
  end

  test "renders transaction probe results" do
    report = {
      network: "base",
      tx_hash: "0xtx",
      classification: "autopilot_shared_strategy",
      hedgeable: false,
      submitted_wallet: "0x1111111111111111111111111111111111111111",
      detected_depositor_wallet: "0x1111111111111111111111111111111111111111",
      pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      strategy_token_ids: [ "70927538" ],
      router_or_manager_contracts: [ "0xcd975e6a5f55137755487f0918b8ca74acce7925" ],
      intermediate_contracts: [ "0x0000000c00000000000000000000000000000001" ],
      pool_or_gauge_contracts: [ "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59" ],
      user_deposit_amounts: { "WETH" => "1.2", "USDC" => "3000.0" },
      candidate_share_tokens: [
        {
          token_address: "0xshare",
          symbol: "SHARE",
          name: "Autopilot Share",
          transfer_amount: "25.0",
          user_balance: "25.0",
          total_supply: "100.0",
          looks_like_share_token: true,
          ownership_directly_attributable_to_user: true,
          transfers: [
            {
              from: "0xcd975e6a5f55137755487f0918b8ca74acce7925",
              to: "0x1111111111111111111111111111111111111111",
              amount: "25.0",
              mint: false,
              involves_submitted_wallet: true,
              involves_router_or_manager: true,
              involves_intermediate: false
            }
          ],
          candidate_share_holders: [
            {
              address: "0x1111111111111111111111111111111111111111",
              why_candidate: [ "submitted_wallet", "transfer_recipient" ],
              balance: "25.0",
              share_percentage: "25.0"
            }
          ]
        }
      ],
      strategy_contract_reads: [
        { address: "0x0000000c00000000000000000000000000000001", total_supply: nil, token0: nil, token1: nil, pool: nil, get_total_amounts: nil }
      ],
      pro_rata_exposure: { user_weth_exposure: nil, user_usdc_exposure: nil, confidence: "unavailable" },
      erc20_transfers: [
        { symbol: "WETH", from: "0x1111111111111111111111111111111111111111", to: "0xcd975e6a5f55137755487f0918b8ca74acce7925", amount: "1.2" }
      ],
      slipstream_nft_transfers: [
        { token_id: "70927538", from: "0xgauge", to: "0x0000000c00000000000000000000000000000001" }
      ],
      blockers: [ "Cannot hedge: user pro-rata WETH exposure is unknown." ],
      warnings: [ "Deposit amounts are transaction inputs, not current hedge exposure." ]
    }

    AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
          get mellow_autopilot_probe_path, params: { tx_hash: "0xtx" }
        end
      end
    end

    assert_response :success
    assert_match "Transaction Probe Result", response.body
    assert_match "autopilot_shared_strategy", response.body
    assert_match "Submitted wallet", response.body
    assert_match "Detected depositor wallet", response.body
    assert_match "70927538", response.body
    assert_match "Candidate share token", response.body
    assert_match "Share %", response.body
    assert_match "submitted_wallet", response.body
    assert_match "User WETH exposure", response.body
    assert_match "Cannot hedge: user pro-rata WETH exposure is unknown", response.body
    assert_match "Deposit amounts are transaction inputs", response.body
  end

  test "passes submitted wallet to transaction probe" do
    captured_kwargs = nil
    report = {
      network: "base",
      tx_hash: "0xtx",
      classification: "unknown",
      hedgeable: false,
      submitted_wallet: "0xabc",
      detected_depositor_wallet: nil,
      pool_address: nil,
      strategy_token_ids: [],
      router_or_manager_contracts: [],
      intermediate_contracts: [],
      pool_or_gauge_contracts: [],
      user_deposit_amounts: {},
      candidate_share_tokens: [],
      strategy_contract_reads: [],
      pro_rata_exposure: { user_weth_exposure: nil, user_usdc_exposure: nil, confidence: "unavailable" },
      erc20_transfers: [],
      slipstream_nft_transfers: [],
      blockers: [],
      warnings: []
    }

    MellowAutopilotPositionProbe.stub(:new, ->(**) { ProbeMock.new({ source: "stub", network: "base", hedge_target_computable: false, blockers: [], warnings: [], positions: [] }) }) do
      AerodromeAutopilotTransactionProbe.stub(:new, ->(**kwargs) { captured_kwargs = kwargs; ProbeMock.new(report) }) do
        get mellow_autopilot_probe_path, params: { tx_hash: "0xtx", wallet_address: "0xabc" }
      end
    end

    assert_response :success
    assert_equal "0xabc", captured_kwargs.fetch(:wallet_address)
    assert_match "0xabc", response.body
  end

  private

  class ProbeMock
    def initialize(report)
      @report = report
    end

    def report
      @report
    end
  end
end
