require "test_helper"

class MellowAutopilotProbesControllerTest < ActionDispatch::IntegrationTest
  VALID_TX_HASH = "0x35512ec38b2b7320ab143727daaefa314b52896cb5137ac2410b40f90505d85f"

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
    assert_select "input[name='tx_hash']"
    assert_select "input[name='tx_wallet_address']"
    assert_select "input[name='tx_network'][value='base']"
    assert_no_match "0x35512ec38b2b7320ab143727daaefa314b52896cb5137ac2410b40f90505d85f", response.body
  end

  test "transaction form submission does not populate mellow api form" do
    report = hedgeable_transaction_report

    MellowAutopilotPositionProbe.stub(:new, ->(**) { raise "Mellow API probe should not be called" }) do
      AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
        get mellow_autopilot_probe_path, params: {
          tx_hash: VALID_TX_HASH,
          tx_wallet_address: report.fetch(:submitted_wallet),
          tx_network: "base"
        }
      end
    end

    assert_response :success
    assert_no_match %(name="wallet_address" value="#{VALID_TX_HASH}"), response.body
    assert_no_match %(name="wallet_address" value="#{report.fetch(:submitted_wallet)}"), response.body
    assert_select "input[name='wallet_address'][value='']"
    assert_select "input[name='tx_hash'][value='#{VALID_TX_HASH}']"
    assert_select "input[name='tx_wallet_address'][value='#{report.fetch(:submitted_wallet)}']"
  end

  test "mellow api form submission does not populate transaction form" do
    report = {
      source: "Mellow official points API",
      network: "base",
      hedge_target_computable: false,
      blockers: [],
      warnings: [],
      positions: []
    }

    MellowAutopilotPositionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { raise "Transaction probe should not be called" }) do
        get mellow_autopilot_probe_path, params: { wallet_address: "0xabc", vault_address: "0xvault", network: "base" }
      end
    end

    assert_response :success
    assert_select "input[name='wallet_address'][value='0xabc']"
    assert_select "input[name='tx_hash'][value='']"
    assert_select "input[name='tx_wallet_address'][value='']"
    assert_no_match %(name="tx_hash" value="0xabc"), response.body
    assert_no_match %(name="tx_wallet_address" value="0xabc"), response.body
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
      tx_hash: VALID_TX_HASH,
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
          get mellow_autopilot_probe_path, params: { tx_hash: VALID_TX_HASH }
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
      tx_hash: VALID_TX_HASH,
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
        get mellow_autopilot_probe_path, params: { tx_hash: VALID_TX_HASH, tx_wallet_address: "0xabc" }
      end
    end

    assert_response :success
    assert_equal "0xabc", captured_kwargs.fetch(:wallet_address)
    assert_equal VALID_TX_HASH, captured_kwargs.fetch(:tx_hash)
    assert_equal "base", captured_kwargs.fetch(:network)
    assert_match "0xabc", response.body
    assert_match VALID_TX_HASH, response.body
  end

  test "invalid transaction hash blocks before transaction probe" do
    AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { raise "Transaction probe should not be called" }) do
      get mellow_autopilot_probe_path, params: { tx_hash: "0xtx", tx_wallet_address: "0xabc", tx_network: "base" }
    end

    assert_response :success
    assert_match "Invalid transaction hash format.", response.body
    assert_match "Submitted transaction hash", response.body
    assert_match "0xtx", response.body
  end

  test "transaction probe formats pro rata exposure values for display" do
    report = hedgeable_transaction_report
    report[:pro_rata_exposure] = report.fetch(:pro_rata_exposure).merge(
      strategy_total_weth: "123.123456789123456789",
      strategy_total_usdc: "456789.987654321",
      user_share_percent: "0.066652589123456789",
      user_weth_exposure: "0.000533219260472093",
      user_usdc_exposure: "123.987654321"
    )
    report[:strategy_total_weth] = "123.123456789123456789"
    report[:strategy_total_usdc] = "456789.987654321"
    report[:user_share_percent] = "0.066652589123456789"
    report[:user_weth_exposure] = "0.000533219260472093"
    report[:user_usdc_exposure] = "123.987654321"

    MellowAutopilotPositionProbe.stub(:new, ->(**) { ProbeMock.new({ source: "stub", network: "base", hedge_target_computable: false, blockers: [], warnings: [], positions: [] }) }) do
      AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
        get mellow_autopilot_probe_path, params: { tx_hash: VALID_TX_HASH, tx_wallet_address: report.fetch(:submitted_wallet) }
      end
    end

    assert_response :success
    assert_match "123.123457", response.body
    assert_match "456,789.99", response.body
    assert_match "0.066653%", response.body
    assert_match "0.000533", response.body
    assert_match "123.99", response.body
    assert_match 'title="123.123456789123456789"', response.body
    assert_match 'title="0.000533219260472093"', response.body
    assert_no_match ">123.123456789123456789<", response.body
    assert_no_match ">0.000533219260472093<", response.body
  end

  test "hedgeable transaction probe can create mellow autopilot position and hedge" do
    report = hedgeable_transaction_report

    AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_difference "Position.count", 1 do
          assert_difference "Hedge.count", 1 do
            post create_mellow_autopilot_position_path, params: {
              mellow_position: {
                tx_hash: VALID_TX_HASH,
                wallet_address: report.fetch(:submitted_wallet),
                network: "base",
                deactivate_existing_positions: "1"
              }
            }
          end
        end
      end
    end

    position = Position.order(:id).last
    assert_redirected_to position_path(position)
    assert_equal Position::SOURCE_MELLOW_AUTOPILOT, position.source
    assert_equal "mellow:70927538", position.external_id
    assert_equal BigDecimal("0.25"), position.asset0_amount
    assert_equal BigDecimal("125.0"), position.asset1_amount
    assert_equal true, position.hedge.active?
    assert_equal "0xshare", position.mellow_metadata_hash.fetch("share_token")
    assert_equal true, position.mellow_metadata_hash.fetch("hedge_ready")
  end

  test "non hedgeable transaction probe cannot create mellow position" do
    report = hedgeable_transaction_report.merge(
      hedgeable: false,
      user_weth_exposure: nil,
      blockers: [ "Cannot hedge: current shared strategy WETH exposure is unavailable." ],
      pro_rata_exposure: hedgeable_transaction_report.fetch(:pro_rata_exposure).merge(user_weth_exposure: nil)
    )

    AerodromeAutopilotTransactionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      assert_no_difference [ "Position.count", "Hedge.count" ] do
        post create_mellow_autopilot_position_path, params: {
          mellow_position: {
            tx_hash: VALID_TX_HASH,
            wallet_address: report.fetch(:submitted_wallet),
            network: "base"
          }
        }
      end
    end

    assert_redirected_to mellow_autopilot_probe_path(tx_hash: VALID_TX_HASH, tx_wallet_address: report.fetch(:submitted_wallet))
    assert_match "Probe result is not hedgeable", flash[:alert]
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

  def hedgeable_transaction_report
    {
      network: "base",
      tx_hash: VALID_TX_HASH,
      classification: "autopilot_shared_strategy",
      hedgeable: true,
      submitted_wallet: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644",
      detected_depositor_wallet: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644",
      pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      strategy_token_id: "70927538",
      strategy_pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      strategy_total_weth: "4.0",
      strategy_total_usdc: "2000.0",
      strategy_total_value_usd: "12000.0",
      user_share_balance: "0.0005",
      total_shares: "0.008",
      user_share_percent: "6.25",
      user_weth_exposure: "0.25",
      user_usdc_exposure: "125.0",
      user_total_value_usd: "750.0",
      exposure_confidence: "high",
      strategy_token_ids: [ "70927538" ],
      router_or_manager_contracts: [ "0xcd975e6a5f55137755487f0918b8ca74acce7925" ],
      intermediate_contracts: [ "0x0000000c00000000000000000000000000000001" ],
      pool_or_gauge_contracts: [ "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59" ],
      user_deposit_amounts: { "WETH" => "0.48", "USDC" => "329" },
      candidate_share_tokens: [],
      strategy_contract_reads: [],
      strategy_nft_exposure: {
        token0_address: AerodromeAutopilotTransactionProbe::WETH_ADDRESS,
        token1_address: AerodromeAutopilotTransactionProbe::USDC_ADDRESS
      },
      pro_rata_exposure: {
        strategy_token_id: "70927538",
        strategy_pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        strategy_total_weth: "4.0",
        strategy_total_usdc: "2000.0",
        strategy_total_value_usd: "12000.0",
        user_share_balance: "0.0005",
        total_shares: "0.008",
        user_share_percent: "6.25",
        user_weth_exposure: "0.25",
        user_usdc_exposure: "125.0",
        user_total_value_usd: "750.0",
        confidence: "high",
        exposure_confidence: "high",
        share_token: "0xshare"
      },
      erc20_transfers: [],
      slipstream_nft_transfers: [],
      blockers: [],
      warnings: []
    }
  end
end
