require "test_helper"

class AerodromeSlipstreamMathTest < ActiveSupport::TestCase
  SAMPLE_LIQUIDITY = 998_471_580_054_153
  SAMPLE_SQRT_PRICE_X96 = 3_787_828_781_868_895_734_512_899
  SAMPLE_TICK_LOWER = -201_000
  SAMPLE_TICK_UPPER = -197_700

  test "tick to sqrt price x96 matches verified TickMath value at zero" do
    assert_equal 2**96, AerodromeSlipstreamMath.tick_to_sqrt_price_x96(0)
  end

  test "below range position is all token0" do
    sqrt_price = AerodromeSlipstreamMath.tick_to_sqrt_price_x96(-202_000)

    amount0, amount1 = AerodromeSlipstreamMath.amounts_for_liquidity(
      sqrt_price_x96: sqrt_price,
      tick_lower: SAMPLE_TICK_LOWER,
      tick_upper: SAMPLE_TICK_UPPER,
      liquidity: SAMPLE_LIQUIDITY
    )

    assert_equal 3_514_829_407_770_963_336, amount0
    assert_equal 0, amount1
  end

  test "in range position has both token amounts" do
    amount0, amount1 = AerodromeSlipstreamMath.amounts_for_liquidity(
      sqrt_price_x96: SAMPLE_SQRT_PRICE_X96,
      tick_lower: SAMPLE_TICK_LOWER,
      tick_upper: SAMPLE_TICK_UPPER,
      liquidity: SAMPLE_LIQUIDITY
    )

    assert_equal 1_290_590_456_994_170_212, amount0
    assert_equal 4_594_633_482, amount1
  end

  test "above range position is all token1" do
    sqrt_price = AerodromeSlipstreamMath.tick_to_sqrt_price_x96(-197_000)

    amount0, amount1 = AerodromeSlipstreamMath.amounts_for_liquidity(
      sqrt_price_x96: sqrt_price,
      tick_lower: SAMPLE_TICK_LOWER,
      tick_upper: SAMPLE_TICK_UPPER,
      liquidity: SAMPLE_LIQUIDITY
    )

    assert_equal 0, amount0
    assert_equal 7_738_853_205, amount1
  end

  test "zero liquidity returns zero amounts" do
    amount0, amount1 = AerodromeSlipstreamMath.amounts_for_liquidity(
      sqrt_price_x96: SAMPLE_SQRT_PRICE_X96,
      tick_lower: SAMPLE_TICK_LOWER,
      tick_upper: SAMPLE_TICK_UPPER,
      liquidity: 0
    )

    assert_equal 0, amount0
    assert_equal 0, amount1
  end

  test "negative ticks and extreme safe ticks are supported" do
    assert_operator AerodromeSlipstreamMath.tick_to_sqrt_price_x96(-887_000), :>, AerodromeSlipstreamMath::MIN_SQRT_RATIO
    assert_operator AerodromeSlipstreamMath.tick_to_sqrt_price_x96(887_000), :<, AerodromeSlipstreamMath::MAX_SQRT_RATIO
  end

  test "decimal conversion supports 18 and 6 decimal tokens without floats" do
    amount0, amount1 = AerodromeSlipstreamMath.amounts_for_liquidity(
      sqrt_price_x96: SAMPLE_SQRT_PRICE_X96,
      tick_lower: SAMPLE_TICK_LOWER,
      tick_upper: SAMPLE_TICK_UPPER,
      liquidity: SAMPLE_LIQUIDITY
    )

    assert_instance_of Integer, amount0
    assert_instance_of Integer, amount1
    assert_equal "1.290590456994170212", AerodromeSlipstreamMath.decimal_amount(amount0, 18).to_s("F")
    assert_equal "4594.633482", AerodromeSlipstreamMath.decimal_amount(amount1, 6).to_s("F")
  end

  test "invalid sqrt and tick ranges fail clearly" do
    error = assert_raises(AerodromeSlipstreamMath::Error) do
      AerodromeSlipstreamMath.amounts_for_liquidity(
        sqrt_price_x96: 1,
        tick_lower: SAMPLE_TICK_LOWER,
        tick_upper: SAMPLE_TICK_UPPER,
        liquidity: SAMPLE_LIQUIDITY
      )
    end
    assert_match "sqrt_price_x96", error.message

    error = assert_raises(AerodromeSlipstreamMath::Error) do
      AerodromeSlipstreamMath.amounts_for_liquidity(
        sqrt_price_x96: SAMPLE_SQRT_PRICE_X96,
        tick_lower: SAMPLE_TICK_UPPER,
        tick_upper: SAMPLE_TICK_LOWER,
        liquidity: SAMPLE_LIQUIDITY
      )
    end
    assert_match "tick_lower", error.message
  end
end
