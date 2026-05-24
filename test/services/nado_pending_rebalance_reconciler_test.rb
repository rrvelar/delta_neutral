require "test_helper"

class NadoPendingRebalanceReconcilerTest < ActiveSupport::TestCase
  class ReadOnlyNadoService
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

  test "pending Nado increase reconciles to success when readback matches expected short" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "-0.7")

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 1, service.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal BigDecimal("0.7"), rebalance.new_short_size
    assert_equal "Confirmed by later Nado readback", rebalance.message
    assert_equal "0x#{"28" * 32}", rebalance.exchange_order_id
  end

  test "pending Nado decrease reconciles to success when readback matches expected short" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.936", expected_short: "0.804", side: "buy")
    service = ReadOnlyNadoService.new(size: "-0.804")

    NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal BigDecimal("0.804"), rebalance.new_short_size
    assert_equal true, rebalance.reduce_only
  end

  test "pending remains pending when readback is missing" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(:unavailable)

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_nil result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
    assert_match "readback did not confirm", rebalance.message
  end

  test "pending remains pending with manual action message when readback conflicts" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "0.2")

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
    assert_match "long ETH-PERP", rebalance.message
  end

  test "reconcile path submits no orders and creates no signatures" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "-0.7")

    assert_no_difference "ShortRebalance.count" do
      NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)
    end

    assert_equal 1, service.read_calls
  end

  private

  def nado_hedge
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
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
  end

  def pending_rebalance(hedge, old_short:, expected_short:, side:)
    exchange_order_id = "0x#{"28" * 32}"
    path = Rails.root.join("tmp", "test-nado-pending-#{SecureRandom.hex(6)}.jsonl")
    receipt = {
      venue: "nado",
      hedge_id: hedge.id,
      exchange_order_id: exchange_order_id,
      action_plan: {
        expected_after_short_eth: expected_short,
        delta_eth: (BigDecimal(expected_short) - BigDecimal(old_short)).to_s("F")
      }
    }
    File.write(path, "#{JSON.generate(receipt)}\n")

    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short,
      new_short_size: old_short,
      realized_pnl: BigDecimal("0"),
      status: ShortRebalance::STATUS_PENDING,
      message: "Nado submit accepted but readback did not confirm ETH-PERP position.",
      rebalanced_at: 5.minutes.ago,
      venue: "nado",
      order_side: side,
      reduce_only: side == "buy",
      exchange_order_id: exchange_order_id,
      receipt_path: path.to_s
    )
  end

  def size(value)
    { size: BigDecimal(value), symbol: "ETH-PERP", side: BigDecimal(value).negative? ? "short" : "long" }
  end
end
