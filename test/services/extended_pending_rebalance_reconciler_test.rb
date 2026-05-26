require "test_helper"

class ExtendedPendingRebalanceReconcilerTest < ActiveSupport::TestCase
  StaticExtendedVenue = Struct.new(:position, :read_calls, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ read_calls: 0 }.merge(kwargs))
    end

    def read_position(symbol:)
      self.read_calls += 1
      position
    end
  end

  test "pending Extended row reconciles when current readback matches expected short" do
    hedge = extended_hedge
    rebalance = pending_rebalance(hedge, expected_short: "0.01")
    venue = StaticExtendedVenue.new(position: { size: "-0.01", short_size: "0.01" })

    result = ExtendedPendingRebalanceReconciler.new(venue: venue).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 1, venue.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal "Extended order confirmed by delayed readback", rebalance.message
  end

  test "pending Extended row reconciles from receipt readback confirmation" do
    hedge = extended_hedge
    rebalance = pending_rebalance(hedge, expected_short: "0.01", receipt_readback: { short_size: "0.01", confirmed: true })
    venue = StaticExtendedVenue.new(position: nil)

    result = ExtendedPendingRebalanceReconciler.new(venue: venue).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 0, venue.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
  end

  test "pending Extended row remains pending when no evidence exists" do
    hedge = extended_hedge
    rebalance = pending_rebalance(hedge, expected_short: "0.01")
    venue = StaticExtendedVenue.new(position: { size: "0", short_size: "0" })

    result = ExtendedPendingRebalanceReconciler.new(venue: venue).reconcile(rebalance)

    assert_nil result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
  end

  private

  def extended_hedge
    Position.update_all(active: false)
    position = Position.create!(
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0x#{SecureRandom.hex(20)}"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.random_number(1_000_000).to_s,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.0",
      asset1_amount: "1000",
      asset0_price_usd: "2100",
      asset1_price_usd: "1",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
  end

  def pending_rebalance(hedge, expected_short:, receipt_readback: nil)
    path = Rails.root.join("tmp", "test-extended-pending-#{SecureRandom.hex(6)}.jsonl")
    receipt = {
      venue: "extended",
      hedge_id: hedge.id,
      exchange_order_id: "ext-order-1",
      expected_short_eth: expected_short
    }
    receipt["readback_attempts"] = [ receipt_readback ] if receipt_readback
    File.write(path, "#{JSON.generate(receipt)}\n")

    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0",
      new_short_size: expected_short,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_PENDING,
      message: "Extended submit accepted but readback did not confirm ETH-PERP position.",
      rebalanced_at: 1.minute.ago,
      venue: "extended",
      order_side: "sell",
      reduce_only: false,
      exchange_order_id: "ext-order-1",
      receipt_path: path.to_s
    )
  end
end
