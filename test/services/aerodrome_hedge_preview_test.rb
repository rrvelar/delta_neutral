require "test_helper"

class AerodromeHedgePreviewTest < ActiveSupport::TestCase
  WETH = "0x4200000000000000000000000000000000000006"
  USDC = "0x0000000000000000000000000000000000000001"
  AERO = "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b"

  test "WETH USDC position returns supported ETH short preview" do
    result = preview.preview(weth_usdc_position)

    assert result.supported
    assert_equal "ETH", result.hedge_asset
    assert_equal "short", result.hedge_side
    assert_equal BigDecimal("1.3"), result.suggested_short_amount
    assert_equal BigDecimal("2600"), result.suggested_short_notional_usd
    assert_equal BigDecimal("1.3"), result.lp_weth_amount
    assert_equal BigDecimal("4500"), result.lp_usdc_amount
    assert_equal BigDecimal("7100"), result.lp_total_value_usd
    assert_equal BigDecimal("2000"), result.weth_price_usd
    assert_equal false, result.execution_enabled
    assert_equal false, result.hyperliquid_called
    assert_equal "preview_only", result.verification_status
  end

  test "USDC WETH ordering returns supported ETH short preview" do
    result = preview.preview(usdc_weth_position)

    assert result.supported
    assert_equal BigDecimal("1.3"), result.suggested_short_amount
    assert_equal BigDecimal("2600"), result.suggested_short_notional_usd
    assert_equal BigDecimal("1.3"), result.lp_weth_amount
    assert_equal BigDecimal("4500"), result.lp_usdc_amount
    assert_equal BigDecimal("2000"), result.weth_price_usd
  end

  test "explicit decimal fields return supported preview for UI display" do
    result = preview.preview_fields(
      token0_address: WETH,
      token1_address: USDC,
      amount0_decimal: BigDecimal("1.25"),
      amount1_decimal: BigDecimal("500"),
      token0_price_usd: BigDecimal("2000"),
      token1_price_usd: BigDecimal("1"),
      total_value_usd: BigDecimal("3000"),
      amount_verified: true,
      valuation_supported: true
    )

    assert result.supported
    assert_equal BigDecimal("1.25"), result.suggested_short_amount
    assert_equal BigDecimal("2500"), result.suggested_short_notional_usd
    assert_equal false, result.execution_enabled
    assert_equal false, result.hyperliquid_called
  end

  test "non WETH pair is unsupported" do
    result = preview.preview(weth_usdc_position.with(token0_address: AERO, token1_address: USDC))

    assert_not result.supported
    assert_match "WETH", result.reason
    assert_equal false, result.execution_enabled
    assert_equal false, result.hyperliquid_called
  end

  test "unsupported valuation is unsupported" do
    result = preview.preview(weth_usdc_position.with(valuation_status: "unsupported", token0_price_usd: nil, total_value_usd: nil))

    assert_not result.supported
    assert_match "valuation", result.reason
  end

  test "unverified amount math is unsupported" do
    result = preview.preview(weth_usdc_position.with(verification_status: "partial"))

    assert_not result.supported
    assert_match "amount math", result.reason
  end

  test "missing WETH config is unsupported" do
    result = AerodromeHedgePreview.new(weth_address: nil).preview(weth_usdc_position)

    assert_not result.supported
    assert_match "AERODROME_WETH_ADDRESS", result.reason
  end

  test "does not call HyperliquidService" do
    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      assert_equal false, preview.preview(weth_usdc_position).hyperliquid_called
    end
  end

  private

  def preview
    AerodromeHedgePreview.new(weth_address: WETH)
  end

  def weth_usdc_position
    position_data(
      token0_address: WETH,
      token1_address: USDC,
      token0_symbol: "WETH",
      token1_symbol: "USDC",
      token0_decimals: 18,
      token1_decimals: 6,
      amount0_raw: 1_300_000_000_000_000_000,
      amount1_raw: 4_500_000_000,
      token0_price_usd: BigDecimal("2000"),
      token1_price_usd: BigDecimal("1")
    )
  end

  def usdc_weth_position
    position_data(
      token0_address: USDC,
      token1_address: WETH,
      token0_symbol: "USDC",
      token1_symbol: "WETH",
      token0_decimals: 6,
      token1_decimals: 18,
      amount0_raw: 4_500_000_000,
      amount1_raw: 1_300_000_000_000_000_000,
      token0_price_usd: BigDecimal("1"),
      token1_price_usd: BigDecimal("2000")
    )
  end

  def position_data(token0_address:, token1_address:, token0_symbol:, token1_symbol:, token0_decimals:, token1_decimals:, amount0_raw:, amount1_raw:, token0_price_usd:, token1_price_usd:)
    AerodromeSlipstreamService::PositionData.new(
      token_id: "315985",
      owner_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token0_address: token0_address,
      token1_address: token1_address,
      token0_decimals: token0_decimals,
      token1_decimals: token1_decimals,
      token0_symbol: token0_symbol,
      token1_symbol: token1_symbol,
      tick_spacing: 50,
      tick_lower: -201000,
      tick_upper: -197700,
      liquidity: 998_471_580_054_153,
      sqrt_price_x96: 3_543_191_142_285_914_205_922_034,
      current_tick: -198995,
      tokens_owed0_raw: 0,
      tokens_owed1_raw: 0,
      amount0_raw: amount0_raw,
      amount1_raw: amount1_raw,
      partial_data_reason: nil,
      verification_status: "verified_math",
      token0_price_usd: token0_price_usd,
      token1_price_usd: token1_price_usd,
      total_value_usd: BigDecimal("7100"),
      valuation_status: "supported",
      valuation_source: AerodromeSlipstreamValuation::VALUATION_SOURCE,
      valuation_reason: nil
    )
  end
end
