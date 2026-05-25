require "test_helper"

class EtherealPendingRebalanceReconcilerTest < ActiveSupport::TestCase
  class ReadOnlyEtherealService
    attr_reader :read_calls

    def initialize(position)
      @position = position
      @read_calls = 0
    end

    def read_position
      @read_calls += 1
      @position
    end
  end

  test "pending Ethereal row reconciles when current readback matches new short" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357")
    service = ReadOnlyEtherealService.new(size: "-0.357")

    result = EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 1, service.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal BigDecimal("0.357"), rebalance.new_short_size
    assert_equal "Ethereal order confirmed by delayed readback", rebalance.message
    assert_equal "eth-order-1", rebalance.exchange_order_id
  end

  test "pending Ethereal row reconciles when later row observed expected old short" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357")
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0.357",
      new_short_size: "0.3444",
      realized_pnl: 0,
      status: ShortRebalance::STATUS_PENDING,
      message: "later pending",
      rebalanced_at: 1.minute.ago,
      venue: "ethereal"
    )
    service = ReadOnlyEtherealService.new(:unavailable)

    result = EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 0, service.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
  end

  test "pending remains pending when no evidence exists" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357")
    service = ReadOnlyEtherealService.new(:unavailable)

    result = EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_nil result
    assert_equal 1, service.read_calls
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
  end

  test "conflicting readback does not mark success" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357")
    service = ReadOnlyEtherealService.new(size: "-0.25")

    result = EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_nil result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
  end

  test "receipt readback can confirm expected new short" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357", receipt_readback: { size: "-0.357", margin_mode: "cross" })
    service = ReadOnlyEtherealService.new(:unavailable)

    result = EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 0, service.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
  end

  test "reconcile path submits no orders and creates no signatures" do
    hedge = ethereal_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.3751", expected_short: "0.357")
    service = ReadOnlyEtherealService.new(size: "-0.357")

    assert_no_difference "ShortRebalance.count" do
      EtherealPendingRebalanceReconciler.new(service: service).reconcile(rebalance)
    end

    assert_equal 1, service.read_calls
  end

  private

  def ethereal_hedge
    Position.update_all(active: false)
    position = Position.create!(
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:#{SecureRandom.hex(4)}",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.0"),
      asset1_amount: BigDecimal("240"),
      asset0_price_usd: BigDecimal("2300"),
      asset1_price_usd: BigDecimal("1"),
      entry_value_usd: BigDecimal("2540"),
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true,
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: "1.0",
        user_usdc_exposure: "240",
        user_total_value_usd: "2540"
      }.to_json
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
  end

  def pending_rebalance(hedge, old_short:, expected_short:, receipt_readback: nil)
    exchange_order_id = "eth-order-1"
    path = Rails.root.join("tmp", "test-ethereal-pending-#{SecureRandom.hex(6)}.jsonl")
    receipt = {
      venue: "ethereal",
      hedge_id: hedge.id,
      exchange_order_id: exchange_order_id,
      expected_short_eth: expected_short
    }
    receipt[:post_submit_readback] = receipt_readback if receipt_readback
    File.write(path, "#{JSON.generate(receipt)}\n")

    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short,
      new_short_size: expected_short,
      realized_pnl: BigDecimal("0"),
      status: ShortRebalance::STATUS_PENDING,
      message: "Ethereal submit accepted but readback did not confirm ETH-PERP position.",
      rebalanced_at: 5.minutes.ago,
      venue: "ethereal",
      order_side: "buy",
      reduce_only: true,
      exchange_order_id: exchange_order_id,
      receipt_path: path.to_s
    )
  end

  def size(value)
    {
      size: BigDecimal(value),
      short_size: BigDecimal(value).negative? ? BigDecimal(value).abs : BigDecimal("0"),
      symbol: "ETH-PERP",
      side: BigDecimal(value).negative? ? "short" : "long",
      margin_mode: "cross"
    }
  end
end
