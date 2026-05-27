require "test_helper"

class RewardsFeesSnapshotRefreshTest < ActiveSupport::TestCase
  test "stores AERO rewards and LP fees from read-only checks" do
    position = position_with_hedge
    rewards = StaticCheck.new(
      status: "PASS",
      claimable_aero: "25.476",
      claimable_aero_usd: "11.12",
      aero_usd_price: "0.4365",
      aero_usd_price_source: "coingecko",
      reward_source: "mellow_ui_parity_eth_call",
      value_state: "estimated",
      source_confidence: "high",
      warnings: []
    )
    fees = StaticCheck.new(
      status: "PASS",
      fee_source: "mellow_strategy",
      fee0_amount: "0.01",
      fee0_usd: "20.5",
      fee1_amount: "3.25",
      fee1_usd: "3.25",
      total_fees_usd: "23.75",
      value_state: "estimated",
      warnings: []
    )

    snapshot = RewardsFeesSnapshotRefresh.new(position: position, rewards_check: rewards, fees_check: fees).refresh

    assert_equal "ok", snapshot.refresh_status
    assert_equal BigDecimal("25.476"), snapshot.aero_rewards_amount
    assert_equal BigDecimal("11.12"), snapshot.aero_rewards_usd
    assert_equal "mellow_ui_parity_eth_call", snapshot.rewards_source
    assert_equal BigDecimal("23.75"), snapshot.lp_fee_total_usd
    assert_equal "estimated", snapshot.fee_value_state
    assert_equal 0, snapshot.orders_submitted
    assert_equal 0, snapshot.signatures_created
  end

  test "partial failure preserves previous good values" do
    position = position_with_hedge
    previous = position.create_position_rewards_fees_snapshot!(
      refreshed_at: 5.minutes.ago,
      refresh_status: "ok",
      aero_rewards_amount: "10",
      aero_rewards_usd: "4",
      lp_fee_total_usd: "2",
      rewards_value_state: "estimated",
      fee_value_state: "estimated"
    )

    snapshot = RewardsFeesSnapshotRefresh.new(
      position: position,
      rewards_check: RaisingCheck.new("rewards timeout"),
      fees_check: StaticCheck.new(status: "PASS", total_fees_usd: "3", value_state: "estimated")
    ).refresh

    assert_equal previous.id, snapshot.id
    assert_equal "partial", snapshot.refresh_status
    assert_equal BigDecimal("10"), snapshot.aero_rewards_amount
    assert_equal BigDecimal("3"), snapshot.lp_fee_total_usd
    assert_includes snapshot.source_errors_hash.fetch("rewards"), "rewards timeout"
    assert_equal 0, snapshot.orders_submitted
    assert_equal 0, snapshot.signatures_created
  end

  private

  StaticCheck = Struct.new(:payload, keyword_init: true) do
    def initialize(**payload)
      super(payload: payload)
    end

    def report = payload
  end

  RaisingCheck = Struct.new(:message) do
    def report
      raise Timeout::Error, message
    end
  end

  def position_with_hedge
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.random_number(1_000_000).to_s,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    ).tap do |position|
      Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end
end
