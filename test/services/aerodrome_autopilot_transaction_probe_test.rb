require "test_helper"

class AerodromeAutopilotTransactionProbeTest < ActiveSupport::TestCase
  USER = "0x1111111111111111111111111111111111111111"
  ROUTER = "0xcd975e6a5f55137755487f0918b8ca74acce7925"
  GAUGE = "0x2222222222222222222222222222222222222222"
  INTERMEDIATE = "0x0000000c00000000000000000000000000000001"
  POOL = "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59"

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
      assert_equal USER, report.fetch(:user_wallet)
      assert_includes report.fetch(:strategy_token_ids), "70927538"
      assert_includes report.fetch(:intermediate_contracts), INTERMEDIATE
      assert_equal "1.2", report.dig(:user_deposit_amounts, "WETH")
      assert_equal "3000.0", report.dig(:user_deposit_amounts, "USDC")
      assert_includes report.fetch(:blockers), "Cannot hedge: transaction appears to use a shared Autopilot strategy NFT; user pro-rata WETH exposure is unknown."
    end
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

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
