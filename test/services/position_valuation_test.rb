require "test_helper"

class PositionValuationTest < ActiveSupport::TestCase
  test "mellow metadata json string drives pro rata value and delta" do
    position = create_mellow_position(
      entry_value_usd: "2611.87311081",
      mellow_metadata: JSON.generate(
        "hedge_ready" => true,
        "last_probe_confidence" => "high",
        "user_total_value_usd" => "2611.873110814818",
        "user_weth_exposure" => "1.16492319796791",
        "user_usdc_exposure" => "240.9127633559829"
      )
    )

    valuation = PositionValuation.current(position)

    assert_equal BigDecimal("2611.873110814818"), valuation.current_value_usd
    assert_equal BigDecimal("0.000000004818"), valuation.pool_delta_usd
    assert_equal BigDecimal("1.16492319796791"), valuation.weth_exposure
    assert_equal "Mellow pro-rata current value", valuation.current_value_label
  end

  test "mellow metadata hash parses when model holds hash" do
    position = Position.new(source: Position::SOURCE_MELLOW_AUTOPILOT)
    position.define_singleton_method(:mellow_metadata) do
      {
        "hedge_ready" => true,
        "last_probe_confidence" => "high",
        "user_total_value_usd" => "10"
      }
    end

    assert_equal BigDecimal("10"), position.mellow_current_value_usd
  end

  test "invalid mellow metadata does not crash and marks value unavailable" do
    position = create_mellow_position(
      entry_value_usd: "2611.87311081",
      asset0_amount: "0.01",
      asset1_amount: "100",
      asset0_price_usd: "8600",
      mellow_metadata: "{bad json"
    )

    valuation = PositionValuation.current(position)

    assert_nil valuation.current_value_usd
    assert_nil valuation.pool_delta_usd
    assert_equal "stale_unavailable", valuation.status
    assert_includes valuation.warnings, "Mellow pro-rata value is stale or unavailable."
  end

  test "direct aerodrome valuation keeps asset math" do
    position = positions(:eth_usdc)

    valuation = PositionValuation.current(position)

    assert_equal BigDecimal("6000"), valuation.current_value_usd
    assert_equal "Current pooled value", valuation.current_value_label
  end

  private

  def create_mellow_position(attributes)
    Position.create!(
      {
        user: users(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        wallet: wallets(:one),
        source: Position::SOURCE_MELLOW_AUTOPILOT,
        external_id: "mellow:71261528",
        pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: "1.16492319796791",
        asset1_amount: "240.9127633559829",
        asset0_price_usd: "159.8",
        asset1_price_usd: "1",
        active: true
      }.merge(attributes)
    )
  end
end
