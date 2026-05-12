require "test_helper"

class HedgeBackendsValueObjectsTest < ActiveSupport::TestCase
  test "position snapshot normalizes decimals and serializes strings for JSON" do
    snapshot = HedgeBackends::PositionSnapshot.new(
      backend: "ethereal",
      asset: "ETH",
      market: "ETH-USD",
      signed_size: "-0.25",
      short_size: "0.25",
      status: "ok"
    )

    assert_equal BigDecimal("-0.25"), snapshot.signed_size
    assert_equal BigDecimal("0.25"), snapshot.short_size
    assert_equal "-0.25", snapshot.as_json.fetch(:signed_size)
  end

  test "market metadata keeps unknown fields nil" do
    metadata = HedgeBackends::MarketMetadata.new(
      backend: "ethereal",
      asset: "ETH",
      market: "ETH-USD",
      lot_size: "0.001",
      result_status: "ok"
    )

    assert_equal BigDecimal("0.001"), metadata.lot_size
    assert_nil metadata.min_notional_usd
    assert_equal "ok", metadata.as_json.fetch(:status)
  end

  test "account health normalizes collateral balances" do
    health = HedgeBackends::AccountHealth.new(
      backend: "ethereal",
      collateral: "USDe",
      account_value_usd: "100.5",
      withdrawable_usd: "40",
      margin_used_usd: "60.5",
      status: "ok"
    )

    assert_equal BigDecimal("100.5"), health.account_value_usd
    assert_equal "60.5", health.as_json.fetch(:margin_used_usd)
  end
end
