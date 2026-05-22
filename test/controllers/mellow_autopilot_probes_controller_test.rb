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
      user_wallet: "0x1111111111111111111111111111111111111111",
      pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      strategy_token_ids: [ "70927538" ],
      router_or_manager_contracts: [ "0xcd975e6a5f55137755487f0918b8ca74acce7925" ],
      intermediate_contracts: [ "0x0000000c00000000000000000000000000000001" ],
      user_deposit_amounts: { "WETH" => "1.2", "USDC" => "3000.0" },
      erc20_transfers: [
        { symbol: "WETH", from: "0x1111111111111111111111111111111111111111", to: "0xcd975e6a5f55137755487f0918b8ca74acce7925", amount: "1.2" }
      ],
      slipstream_nft_transfers: [
        { token_id: "70927538", from: "0xgauge", to: "0x0000000c00000000000000000000000000000001" }
      ],
      blockers: [ "Cannot hedge: transaction appears to use a shared Autopilot strategy NFT; user pro-rata WETH exposure is unknown." ],
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
    assert_match "70927538", response.body
    assert_match "Cannot hedge: transaction appears to use a shared Autopilot strategy NFT", response.body
    assert_match "Deposit amounts are transaction inputs", response.body
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
