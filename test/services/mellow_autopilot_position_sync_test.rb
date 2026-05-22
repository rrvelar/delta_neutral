require "test_helper"

class MellowAutopilotPositionSyncTest < ActiveSupport::TestCase
  test "sync updates mellow pro rata weth and usdc" do
    position = create_mellow_position
    report = hedgeable_report(user_weth: "0.333")

    assert_difference "PnlSnapshot.count", 0 do
      result = MellowAutopilotPositionSync.new(position: position, probe_factory: ->(*) { ProbeMock.new(report) }).sync

      assert_equal "synced", result.fetch(:status)
    end

    position.reload
    assert_equal BigDecimal("0.333"), position.asset0_amount
    assert_equal BigDecimal("222.0"), position.asset1_amount
    assert_equal true, position.hedge_ready?
    assert_equal "70927538", position.mellow_metadata_hash.fetch("strategy_token_id")
    assert_equal "high", position.mellow_metadata_hash.fetch("last_probe_confidence")
  end

  test "sync marks mellow position not hedge ready when strategy weth unavailable" do
    position = create_mellow_position
    report = hedgeable_report(user_weth: nil).merge(
      hedgeable: false,
      user_weth_exposure: nil,
      blockers: [ "Cannot hedge: current shared strategy WETH exposure is unavailable." ],
      pro_rata_exposure: hedgeable_report(user_weth: nil).fetch(:pro_rata_exposure).merge(user_weth_exposure: nil)
    )

    result = MellowAutopilotPositionSync.new(position: position, probe_factory: ->(*) { ProbeMock.new(report) }).sync

    assert_equal "blocked", result.fetch(:status)
    assert_equal false, position.reload.hedge_ready?
    assert_includes position.mellow_metadata_hash.fetch("last_probe_blockers"), "Cannot hedge: current shared strategy WETH exposure is unavailable."
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

  def create_mellow_position
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644")
    position = Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:70927538",
      pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("0.1"),
      asset1_amount: BigDecimal("100"),
      asset0_price_usd: BigDecimal("2500"),
      asset1_price_usd: BigDecimal("1"),
      active: true,
      mellow_metadata: JSON.generate("tx_hash" => "0xtx", "submitted_wallet" => wallet.address)
    )
    position.create_hedge!(target: BigDecimal("1.0"), tolerance: BigDecimal("0.03"), active: true)
    position
  end

  def hedgeable_report(user_weth:)
    {
      hedgeable: user_weth.present?,
      tx_hash: "0xtx",
      submitted_wallet: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644",
      strategy_nft_exposure: {
        token0_address: AerodromeAutopilotTransactionProbe::WETH_ADDRESS,
        token1_address: AerodromeAutopilotTransactionProbe::USDC_ADDRESS
      },
      pro_rata_exposure: {
        share_token: "0xshare",
        strategy_token_id: "70927538",
        strategy_pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        strategy_total_weth: "4.0",
        strategy_total_usdc: "2000.0",
        strategy_total_value_usd: "12000.0",
        user_share_balance: "0.0005",
        total_shares: "0.008",
        user_share_percent: "6.25",
        user_weth_exposure: user_weth,
        user_usdc_exposure: "222.0",
        user_total_value_usd: "888.0",
        confidence: "high",
        exposure_confidence: "high"
      },
      blockers: []
    }
  end
end
