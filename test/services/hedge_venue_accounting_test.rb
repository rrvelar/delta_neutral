require "test_helper"

class HedgeVenueAccountingTest < ActiveSupport::TestCase
  test "computes net venue pnl from available components and leaves missing costs unavailable" do
    hedge = hedge_for("extended")
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0",
      new_short_size: "0.01",
      realized_pnl: "1.25",
      status: ShortRebalance::STATUS_SUCCESS,
      message: "confirmed",
      rebalanced_at: 1.minute.ago,
      venue: "extended"
    )
    adapter = StaticAccountingVenue.new(
      position: {
        side: "short",
        size: "-0.01",
        short_size: "0.01",
        entry_price: "2100",
        mark_price: "2080",
        notional_usd: "20.8",
        margin_mode: "cross"
      },
      account_state: { fee_rates: { taker_fee_rate: "0.0005" } }
    )

    report = HedgeVenueAccounting.new(position: hedge.position, venue_key: "extended", adapter: adapter).report

    assert_equal "Extended", report.fetch(:venue_name)
    assert_equal "0.01", report.fetch(:current_short_eth)
    assert_equal "0.2", report.dig(:components, :unrealized_pnl_usd, :value)
    assert_equal "1.25", report.dig(:components, :realized_pnl_usd, :value)
    assert_equal "1.45", report.fetch(:net_venue_pnl_usd)
    assert_equal "unavailable", report.dig(:components, :trading_fees_usd, :state)
    assert_includes report.fetch(:unavailable_components), :trading_fees_usd
    assert_equal({ taker_fee_rate: "0.0005" }, report.fetch(:fee_rates))
  end

  test "uses venue unrealized pnl when readback provides it" do
    hedge = hedge_for("ethereal")
    adapter = StaticAccountingVenue.new(
      position: { side: "short", size: "-0.5", short_size: "0.5", unrealized_pnl_usd: "-3.75", margin_mode: "cross" },
      account_state: {}
    )

    report = HedgeVenueAccounting.new(position: hedge.position, venue_key: "ethereal", adapter: adapter).report

    assert_equal "-3.75", report.dig(:components, :unrealized_pnl_usd, :value)
    assert_equal "-3.75", report.fetch(:net_venue_pnl_usd)
  end

  private

  StaticAccountingVenue = Struct.new(:position, :account_state, keyword_init: true) do
    def read_position(symbol:) = position
  end

  def hedge_for(venue)
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
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: venue)
  end
end
