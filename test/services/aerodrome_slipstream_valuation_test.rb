require "test_helper"

class AerodromeSlipstreamValuationTest < ActiveSupport::TestCase
  WETH = "0x4200000000000000000000000000000000000006"
  USDC = "0x0000000000000000000000000000000000000001"
  AERO = "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b"
  WETH_USDC_2000_SQRT_PRICE_X96 = 3_543_191_142_285_914_205_922_034
  USDC_WETH_2000_SQRT_PRICE_X96 = 1_771_595_571_142_957_102_961_017_161_607_260

  test "values WETH USDC when token0 is WETH and token1 is USDC" do
    result = valuation.preview(
      token0_address: WETH,
      token1_address: USDC,
      token0_decimals: 18,
      token1_decimals: 6,
      sqrt_price_x96: WETH_USDC_2000_SQRT_PRICE_X96,
      amount0_raw: 1_300_000_000_000_000_000,
      amount1_raw: 4_500_000_000
    )

    assert result.supported
    assert_in_delta 2000, result.token0_price_usd.to_f, 0.000001
    assert_equal BigDecimal("1"), result.token1_price_usd
    assert_in_delta 7100, result.total_value_usd.to_f, 0.000001
    assert_equal "verified_usdc_quote", result.verification_status
  end

  test "values USDC WETH when token0 is USDC and token1 is WETH" do
    result = valuation.preview(
      token0_address: USDC,
      token1_address: WETH,
      token0_decimals: 6,
      token1_decimals: 18,
      sqrt_price_x96: USDC_WETH_2000_SQRT_PRICE_X96,
      amount0_raw: 4_500_000_000,
      amount1_raw: 1_300_000_000_000_000_000
    )

    assert result.supported
    assert_equal BigDecimal("1"), result.token0_price_usd
    assert_in_delta 2000, result.token1_price_usd.to_f, 0.000001
    assert_in_delta 7100, result.total_value_usd.to_f, 0.000001
  end

  test "unsupported non USDC pair leaves valuation nil" do
    result = valuation.preview(
      token0_address: AERO,
      token1_address: WETH,
      token0_decimals: 18,
      token1_decimals: 18,
      sqrt_price_x96: WETH_USDC_2000_SQRT_PRICE_X96,
      amount0_raw: 1_000_000_000_000_000_000,
      amount1_raw: 1_000_000_000_000_000_000
    )

    assert_not result.supported
    assert_nil result.token0_price_usd
    assert_nil result.token1_price_usd
    assert_nil result.total_value_usd
    assert_match "USDC", result.reason
  end

  test "missing quote token config is unsupported" do
    result = AerodromeSlipstreamValuation.new(quote_token_address: nil).preview(
      token0_address: WETH,
      token1_address: USDC,
      token0_decimals: 18,
      token1_decimals: 6,
      sqrt_price_x96: WETH_USDC_2000_SQRT_PRICE_X96,
      amount0_raw: 1_000_000_000_000_000_000,
      amount1_raw: 0
    )

    assert_not result.supported
    assert_match "AERODROME_USDC_ADDRESS", result.reason
  end

  test "invalid sqrt price fails safely" do
    result = valuation.preview(
      token0_address: WETH,
      token1_address: USDC,
      token0_decimals: 18,
      token1_decimals: 6,
      sqrt_price_x96: 0,
      amount0_raw: 1_000_000_000_000_000_000,
      amount1_raw: 0
    )

    assert_not result.supported
    assert_match "sqrt_price_x96", result.reason
  end

  test "price critical values are BigDecimal" do
    result = valuation.preview(
      token0_address: WETH,
      token1_address: USDC,
      token0_decimals: 18,
      token1_decimals: 6,
      sqrt_price_x96: WETH_USDC_2000_SQRT_PRICE_X96,
      amount0_raw: 1_000_000_000_000_000_000,
      amount1_raw: 0
    )

    assert_instance_of BigDecimal, result.token0_price_usd
    assert_instance_of BigDecimal, result.token1_price_usd
    assert_instance_of BigDecimal, result.total_value_usd
  end

  private

  def valuation
    AerodromeSlipstreamValuation.new(quote_token_address: USDC)
  end
end
