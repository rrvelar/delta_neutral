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

  test "sync does not reset existing entry value and records changed observed token id history" do
    position = create_mellow_position
    position.update!(entry_value_usd: BigDecimal("777.0"))
    report = hedgeable_report(user_weth: "0.333")
    report[:pro_rata_exposure] = report.fetch(:pro_rata_exposure).merge(strategy_token_id: "80000001", user_total_value_usd: "999.0")

    result = MellowAutopilotPositionSync.new(position: position, probe_factory: ->(*) { ProbeMock.new(report) }).sync

    assert_equal "synced", result.fetch(:status)
    position.reload
    assert_equal BigDecimal("777.0"), position.entry_value_usd
    assert_equal "80000001", position.mellow_metadata_hash.fetch("strategy_token_id")
    assert_includes position.mellow_metadata_hash.fetch("observed_strategy_token_id_history"), "70927538"
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

  test "sync persists share token current fallback exposure" do
    position = create_mellow_position
    report = hedgeable_report(user_weth: "1.01675")
    report[:strategy_nft_exposure] = report.fetch(:strategy_nft_exposure).merge(
      strategy_token_id: "71261528",
      error: "Aerodrome RPC error: execution reverted: ERC721: owner query for nonexistent token"
    )
    report[:pro_rata_exposure] = report.fetch(:pro_rata_exposure).merge(
      strategy_token_id: "71261528",
      stale_strategy_token_id: "71261528",
      strategy_total_weth: "616.629150428444549772",
      strategy_total_usdc: "323204.389919",
      user_share_balance: "0.001072847820176313",
      total_shares: "0.650660374341310525",
      share_fraction: "0.001648859931361887",
      user_share_percent: "0.1648859931361887",
      user_weth_exposure: "1.01675",
      user_usdc_exposure: "532.91",
      confidence: "share_token_current_fallback",
      exposure_confidence: "share_token_current_fallback",
      exposure_source: "current_share_token_fallback",
      current_share_token_total_amounts_attempts: [
        { address: "0xshare", method: "getTotalAmounts()", status: "ok" }
      ]
    )

    result = MellowAutopilotPositionSync.new(position: position, probe_factory: ->(*) { ProbeMock.new(report) }).sync

    assert_equal "synced", result.fetch(:status)
    position.reload
    assert_equal BigDecimal("1.01675"), position.asset0_amount
    assert_equal BigDecimal("532.91"), position.asset1_amount
    assert_equal true, position.hedge_ready?
    assert_equal "current_share_token_fallback", position.mellow_metadata_hash.fetch("exposure_source")
    assert_equal "71261528", position.mellow_metadata_hash.fetch("stale_strategy_token_id")
    assert_equal "0.001648859931361887", position.mellow_metadata_hash.fetch("share_fraction")
  end

  test "sync blocks with diagnostics when share token current totals unavailable" do
    position = create_mellow_position
    report = hedgeable_report(user_weth: nil).merge(
      hedgeable: false,
      user_weth_exposure: nil,
      blockers: [ "current share-token total WETH/USDC unavailable" ],
      pro_rata_exposure: hedgeable_report(user_weth: nil).fetch(:pro_rata_exposure).merge(
        user_weth_exposure: nil,
        current_share_token_total_amounts_unavailable: true,
        current_share_token_total_amounts_attempts: [
          { address: "0xshare", method: "getTotalAmounts()", status: "unavailable" }
        ]
      )
    )

    result = MellowAutopilotPositionSync.new(position: position, probe_factory: ->(*) { ProbeMock.new(report) }).sync

    assert_equal "blocked", result.fetch(:status)
    position.reload
    assert_equal BigDecimal("0.1"), position.asset0_amount
    assert_equal false, position.hedge_ready?
    assert_includes position.mellow_metadata_hash.fetch("last_probe_blockers"), "current share-token total WETH/USDC unavailable"
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
      mellow_metadata: JSON.generate("tx_hash" => "0xtx", "submitted_wallet" => wallet.address, "strategy_token_id" => "70927538")
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
