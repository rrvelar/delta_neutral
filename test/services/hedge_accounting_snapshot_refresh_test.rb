require "test_helper"

class HedgeAccountingSnapshotRefreshTest < ActiveSupport::TestCase
  test "stores Extended hedge accounting from dashboard snapshot readback" do
    position = position_with_hedge
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: "0.866",
      extended_status: "active",
      extended_entry_price: "2068.4",
      extended_mark_price: "2065.555237925",
      extended_notional_usd: "1788.770836",
      extended_unrealized_pnl_usd: "2.47",
      extended_source_status: "ok"
    )

    snapshot = HedgeAccountingSnapshotRefresh.new(position: position).refresh

    assert_equal "ok", snapshot.refresh_status
    assert_equal "extended", snapshot.venue
    assert_equal BigDecimal("0.866"), snapshot.current_short_eth
    assert_equal BigDecimal("2.47"), snapshot.unrealized_pnl_usd
    assert_equal BigDecimal("2.47"), snapshot.net_hedge_pnl_usd
    assert_equal 0, snapshot.orders_submitted
    assert_equal 0, snapshot.signatures_created
  end

  private

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
