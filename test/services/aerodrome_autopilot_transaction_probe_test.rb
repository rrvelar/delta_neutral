require "test_helper"

class AerodromeAutopilotTransactionProbeTest < ActiveSupport::TestCase
  USER = "0x1111111111111111111111111111111111111111"
  ROUTER = "0xcd975e6a5f55137755487f0918b8ca74acce7925"
  GAUGE = "0x2222222222222222222222222222222222222222"
  INTERMEDIATE = "0x0000000c00000000000000000000000000000001"
  POOL = "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59"
  SHARE = "0x3333333333333333333333333333333333333333"

  test "classifies shared strategy when nft moves gauge to intermediate and back" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(AerodromeAutopilotTransactionProbe::USDC_ADDRESS, USER, ROUTER, 3000, 6),
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, ROUTER, POOL, 1.2, 18),
        erc20_transfer(AerodromeAutopilotTransactionProbe::USDC_ADDRESS, ROUTER, POOL, 3000, 6),
        nft_transfer(GAUGE, INTERMEDIATE, "70927538"),
        nft_transfer(INTERMEDIATE, GAUGE, "70927538")
      ]
    }

    assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
      report = AerodromeAutopilotTransactionProbe.new(tx_hash: "0xtx", receipt: receipt).report

      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:external_api)
      assert_equal "autopilot_shared_strategy", report.fetch(:classification)
      assert_equal false, report.fetch(:hedgeable)
      assert_equal USER, report.fetch(:detected_depositor_wallet)
      assert_includes report.fetch(:strategy_token_ids), "70927538"
      assert_includes report.fetch(:intermediate_contracts), INTERMEDIATE
      assert_equal "1.2", report.dig(:user_deposit_amounts, "WETH")
      assert_equal "3000.0", report.dig(:user_deposit_amounts, "USDC")
      assert_includes report.fetch(:blockers), "Cannot hedge: current shared strategy WETH exposure is unavailable."
    end
  end

  test "detects candidate share token transfer" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(SHARE, ROUTER, USER, 25, 18),
        nft_transfer(GAUGE, INTERMEDIATE, "70927538"),
        nft_transfer(INTERMEDIATE, GAUGE, "70927538")
      ]
    }

    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: "0xtx",
      wallet_address: USER,
      receipt: receipt,
      eth_call_results: {
        [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(25 * 10**18),
        [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:total_supply) ] => word(100 * 10**18)
      }
    ).report

    token = report.fetch(:candidate_share_tokens).first
    assert_equal SHARE, token.fetch(:token_address)
    assert_equal "25.0", token.fetch(:transfer_amount)
    assert_equal "25.0", token.fetch(:user_balance)
    assert_equal "100.0", token.fetch(:total_supply)
    assert_equal true, token.fetch(:looks_like_share_token)
    assert_equal true, token.fetch(:ownership_directly_attributable_to_user)
    assert_equal USER, token.fetch(:candidate_share_holders).find { |holder| holder.fetch(:why_candidate).include?("submitted_wallet") }.fetch(:address)
    assert_equal "25.0", token.fetch(:candidate_share_holders).find { |holder| holder.fetch(:address) == USER }.fetch(:share_percentage)
    assert_equal ROUTER, token.fetch(:transfers).first.fetch(:from)
    assert_equal USER, token.fetch(:transfers).first.fetch(:to)
    assert_equal true, token.fetch(:transfers).first.fetch(:involves_submitted_wallet)
  end

  test "computes pro rata exposure from shared strategy nft data" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(SHARE, ROUTER, USER, 25, 18),
        nft_transfer(GAUGE, INTERMEDIATE, "70927538"),
        nft_transfer(INTERMEDIATE, GAUGE, "70927538")
      ]
    }
    calls = {
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(25 * 10**18),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:total_supply) ] => word(100 * 10**18)
    }
    slipstream = SlipstreamMock.new(strategy_position(amount0_raw: 4 * 10**18, amount1_raw: 2_000 * 10**6))

    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: "0xtx",
      wallet_address: USER,
      receipt: receipt,
      eth_call_results: calls,
      slipstream_service: slipstream
    ).report

    assert_equal true, report.fetch(:hedgeable)
    assert_empty report.fetch(:blockers)
    assert_equal [ "70927538" ], slipstream.fetches
    assert_equal "70927538", report.dig(:pro_rata_exposure, :strategy_token_id)
    assert_equal "70927538", report.fetch(:strategy_token_id)
    assert_equal POOL, report.dig(:pro_rata_exposure, :strategy_pool_address)
    assert_equal "4.0", report.dig(:pro_rata_exposure, :strategy_total_weth)
    assert_equal "4.0", report.fetch(:strategy_total_weth)
    assert_equal "2000.0", report.dig(:pro_rata_exposure, :strategy_total_usdc)
    assert_equal "25.0", report.dig(:pro_rata_exposure, :user_share_percent)
    assert_equal "25.0", report.fetch(:user_share_percent)
    assert_equal "high", report.dig(:pro_rata_exposure, :confidence)
    assert_equal "1.0", report.dig(:pro_rata_exposure, :user_weth_exposure)
    assert_equal "1.0", report.fetch(:user_weth_exposure)
    assert_equal "500.0", report.dig(:pro_rata_exposure, :user_usdc_exposure)
    assert_equal "shared strategy Slipstream NFT", report.dig(:pro_rata_exposure, :source)
  end

  test "computes pro rata exposure from current share token totals when strategy nft is nonexistent" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(SHARE, ROUTER, USER, "0.001072847820176313", 18),
        nft_transfer(GAUGE, INTERMEDIATE, "71261528"),
        nft_transfer(INTERMEDIATE, GAUGE, "71261528")
      ]
    }
    calls = {
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(BigDecimal("0.001072847820176313") * 10**18),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:total_supply) ] => word(BigDecimal("0.650660374341310525") * 10**18),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:token0) ] => address_word(AerodromeAutopilotTransactionProbe::WETH_ADDRESS),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:token1) ] => address_word(AerodromeAutopilotTransactionProbe::USDC_ADDRESS),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:pool) ] => address_word(POOL),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:get_total_amounts) ] => two_words(BigDecimal("616.629150428444549772") * 10**18, BigDecimal("323204.389919") * 10**6)
    }
    slipstream = FailingSlipstreamMock.new("Aerodrome RPC error: execution reverted: ERC721: owner query for nonexistent token")

    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: "0xtx",
      wallet_address: USER,
      receipt: receipt,
      eth_call_results: calls,
      slipstream_service: slipstream
    ).report

    assert_equal true, report.fetch(:hedgeable)
    assert_empty report.fetch(:blockers)
    assert_equal "71261528", report.dig(:pro_rata_exposure, :stale_strategy_token_id)
    assert_equal "current_share_token_fallback", report.dig(:pro_rata_exposure, :exposure_source)
    assert_equal "share_token_current_fallback", report.dig(:pro_rata_exposure, :confidence)
    assert_in_delta BigDecimal("1.01675"), BigDecimal(report.dig(:pro_rata_exposure, :user_weth_exposure)), BigDecimal("0.0001")
    assert_in_delta BigDecimal("532.91"), BigDecimal(report.dig(:pro_rata_exposure, :user_usdc_exposure)), BigDecimal("0.01")
    assert_equal "71261528", report.fetch(:strategy_token_id)
    assert_equal POOL, report.fetch(:strategy_pool_address)
  end

  test "remains non hedgeable when strategy nft weth is unavailable" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(SHARE, ROUTER, USER, 25, 18),
        nft_transfer(GAUGE, INTERMEDIATE, "70927538"),
        nft_transfer(INTERMEDIATE, GAUGE, "70927538")
      ]
    }

    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: "0xtx",
      wallet_address: USER,
      receipt: receipt,
      eth_call_results: {
        [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(25 * 10**18),
        [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:total_supply) ] => word(100 * 10**18)
      },
      slipstream_service: SlipstreamMock.new(strategy_position(amount0_raw: nil, amount1_raw: 2_000 * 10**6))
    ).report

    assert_equal false, report.fetch(:hedgeable)
    assert_includes report.fetch(:blockers), "current share-token total WETH/USDC unavailable"
    assert_nil report.dig(:pro_rata_exposure, :user_weth_exposure)
    assert report.dig(:pro_rata_exposure, :current_share_token_total_amounts_attempts).present?
  end

  test "shares held by intermediate contract remain non hedgeable" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, ROUTER, 1.2, 18),
        erc20_transfer(SHARE, "0x0000000000000000000000000000000000000000", INTERMEDIATE, 25, 18),
        nft_transfer(GAUGE, INTERMEDIATE, "70927538"),
        nft_transfer(INTERMEDIATE, GAUGE, "70927538")
      ]
    }
    calls = {
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(0),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:balance_of) + INTERMEDIATE.delete_prefix("0x").rjust(64, "0") ] => word(25 * 10**18),
      [ SHARE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:total_supply) ] => word(100 * 10**18),
      [ INTERMEDIATE, AerodromeAutopilotTransactionProbe::SELECTORS.fetch(:get_total_amounts) ] => "0x#{word(4 * 10**18).delete_prefix('0x')}#{word(2_000 * 10**6).delete_prefix('0x')}"
    }

    report = AerodromeAutopilotTransactionProbe.new(
      tx_hash: "0xtx",
      wallet_address: USER,
      receipt: receipt,
      eth_call_results: calls
    ).report

    token = report.fetch(:candidate_share_tokens).first
    submitted_holder = token.fetch(:candidate_share_holders).find { |holder| holder.fetch(:address) == USER }
    intermediate_holder = token.fetch(:candidate_share_holders).find { |holder| holder.fetch(:address) == INTERMEDIATE }

    assert_equal false, report.fetch(:hedgeable)
    assert_equal "0.0", submitted_holder.fetch(:balance)
    assert_equal "25.0", intermediate_holder.fetch(:balance)
    assert_equal "25.0", intermediate_holder.fetch(:share_percentage)
    assert_equal false, token.fetch(:ownership_directly_attributable_to_user)
    assert_includes token.fetch(:contract_holders), INTERMEDIATE
    assert_includes report.fetch(:blockers), "Shares appear held by contract #{INTERMEDIATE}; user ownership mapping still unknown."
    assert_nil report.dig(:pro_rata_exposure, :user_weth_exposure)
  end

  test "classifies direct lp nft when nft does not return through intermediate" do
    receipt = {
      "logs" => [
        erc20_transfer(AerodromeAutopilotTransactionProbe::WETH_ADDRESS, USER, POOL, 0.5, 18),
        erc20_transfer(AerodromeAutopilotTransactionProbe::USDC_ADDRESS, USER, POOL, 1200, 6),
        nft_transfer("0x0000000000000000000000000000000000000000", USER, "71141789")
      ]
    }

    report = AerodromeAutopilotTransactionProbe.new(tx_hash: "0xtx", receipt: receipt).report

    assert_equal "direct_lp_nft", report.fetch(:classification)
    assert_equal true, report.fetch(:hedgeable)
    assert_empty report.fetch(:blockers)
    assert_equal [ "71141789" ], report.fetch(:strategy_token_ids)
  end

  test "returns rpc unavailable blocker" do
    with_env("BASE_RPC_URL" => nil) do
      report = AerodromeAutopilotTransactionProbe.new(tx_hash: "0xtx").report

      assert_equal false, report.fetch(:hedgeable)
      assert_match "BASE_RPC_URL is not configured", report.fetch(:blockers).first
    end
  end

  private

  class SlipstreamMock
    attr_reader :fetches

    def initialize(position_data)
      @position_data = position_data
      @fetches = []
    end

    def fetch_position(token_id)
      @fetches << token_id.to_s
      @position_data
    end
  end

  class FailingSlipstreamMock
    def initialize(message)
      @message = message
    end

    def fetch_position(_token_id)
      raise @message
    end
  end

  def strategy_position(amount0_raw:, amount1_raw:)
    AerodromeSlipstreamService::PositionData.new(
      token_id: "70927538",
      owner_address: INTERMEDIATE,
      position_manager_address: AerodromeAutopilotTransactionProbe::SLIPSTREAM_POSITION_MANAGER,
      factory_address: "0x4444444444444444444444444444444444444444",
      pool_address: POOL,
      token0_address: AerodromeAutopilotTransactionProbe::WETH_ADDRESS,
      token1_address: AerodromeAutopilotTransactionProbe::USDC_ADDRESS,
      token0_decimals: 18,
      token1_decimals: 6,
      token0_symbol: "WETH",
      token1_symbol: "USDC",
      tick_spacing: 100,
      tick_lower: -1,
      tick_upper: 1,
      liquidity: 1,
      sqrt_price_x96: 1,
      current_tick: 0,
      tokens_owed0_raw: 0,
      tokens_owed1_raw: 0,
      amount0_raw: amount0_raw,
      amount1_raw: amount1_raw,
      partial_data_reason: nil,
      verification_status: "verified_math",
      token0_price_usd: BigDecimal("2500"),
      token1_price_usd: BigDecimal("1"),
      total_value_usd: BigDecimal("12000"),
      valuation_status: "supported",
      valuation_source: "test",
      valuation_reason: nil
    )
  end

  def erc20_transfer(token, from, to, amount, decimals)
    {
      "address" => token,
      "topics" => [
        AerodromeAutopilotTransactionProbe::TRANSFER_TOPIC,
        address_topic(from),
        address_topic(to)
      ],
      "data" => "0x#{(BigDecimal(amount.to_s) * BigDecimal(10**decimals)).to_i.to_s(16).rjust(64, '0')}"
    }
  end

  def nft_transfer(from, to, token_id)
    {
      "address" => AerodromeAutopilotTransactionProbe::SLIPSTREAM_POSITION_MANAGER,
      "topics" => [
        AerodromeAutopilotTransactionProbe::TRANSFER_TOPIC,
        address_topic(from),
        address_topic(to),
        "0x#{token_id.to_i.to_s(16).rjust(64, '0')}"
      ],
      "data" => "0x"
    }
  end

  def address_topic(address)
    "0x#{address.delete_prefix('0x').rjust(64, '0')}"
  end

  def word(value)
    "0x#{value.to_i.to_s(16).rjust(64, '0')}"
  end

  def two_words(value0, value1)
    "0x#{word(value0).delete_prefix('0x')}#{word(value1).delete_prefix('0x')}"
  end

  def address_word(address)
    "0x#{address.delete_prefix('0x').rjust(64, '0')}"
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
