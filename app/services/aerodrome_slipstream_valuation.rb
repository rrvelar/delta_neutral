# Read-only USD valuation preview for Aerodrome Slipstream pools.
#
# This is intentionally narrow: it only supports pools with a configured USDC
# quote token address and never falls back to guessed prices.
class AerodromeSlipstreamValuation
  VALUATION_SOURCE = "Aerodrome Slipstream slot0 sqrtPriceX96 + configured USDC quote token"
  PRICE_PRECISION = 50
  EVM_ADDRESS_PATTERN = /\A0x[0-9a-f]{40}\z/

  Result = Data.define(
    :supported,
    :reason,
    :token0_price_usd,
    :token1_price_usd,
    :total_value_usd,
    :quote_token,
    :valuation_source,
    :verification_status
  )

  def initialize(quote_token_address: ENV["AERODROME_USDC_ADDRESS"].presence)
    @quote_token_address = normalize_address_or_nil(quote_token_address)
  end

  def preview(token0_address:, token1_address:, token0_decimals:, token1_decimals:, sqrt_price_x96:, amount0_raw:, amount1_raw:)
    return unsupported("AERODROME_USDC_ADDRESS is not configured") if @quote_token_address.nil?

    token0_address = normalize_address_or_nil(token0_address)
    token1_address = normalize_address_or_nil(token1_address)
    return unsupported("token address is invalid") if token0_address.nil? || token1_address.nil?

    unless [ token0_address, token1_address ].include?(@quote_token_address)
      return unsupported("pool does not include configured USDC quote token")
    end

    amount0_decimal = AerodromeSlipstreamMath.decimal_amount(amount0_raw, token0_decimals)
    amount1_decimal = AerodromeSlipstreamMath.decimal_amount(amount1_raw, token1_decimals)
    token1_per_token0 = token1_per_token0_price(
      sqrt_price_x96: sqrt_price_x96,
      token0_decimals: token0_decimals,
      token1_decimals: token1_decimals
    )

    token0_price_usd, token1_price_usd =
      if token1_address == @quote_token_address
        [ token1_per_token0, BigDecimal("1") ]
      else
        [ BigDecimal("1"), BigDecimal("1").div(token1_per_token0, PRICE_PRECISION) ]
      end

    Result.new(
      supported: true,
      reason: nil,
      token0_price_usd: token0_price_usd,
      token1_price_usd: token1_price_usd,
      total_value_usd: (amount0_decimal * token0_price_usd) + (amount1_decimal * token1_price_usd),
      quote_token: @quote_token_address,
      valuation_source: VALUATION_SOURCE,
      verification_status: "verified_usdc_quote"
    )
  rescue AerodromeSlipstreamMath::Error => e
    unsupported(e.message)
  end

  private

  def token1_per_token0_price(sqrt_price_x96:, token0_decimals:, token1_decimals:)
    sqrt_price_x96 = AerodromeSlipstreamMath.uint!(sqrt_price_x96, "sqrt_price_x96")
    AerodromeSlipstreamMath.validate_current_sqrt!(sqrt_price_x96)
    token0_decimals = AerodromeSlipstreamMath.uint!(token0_decimals, "token0_decimals")
    token1_decimals = AerodromeSlipstreamMath.uint!(token1_decimals, "token1_decimals")

    raw_ratio = (BigDecimal(sqrt_price_x96) * BigDecimal(sqrt_price_x96))
      .div(BigDecimal(AerodromeSlipstreamMath::Q96) * BigDecimal(AerodromeSlipstreamMath::Q96), PRICE_PRECISION)

    raw_ratio * (BigDecimal(10)**token0_decimals) / (BigDecimal(10)**token1_decimals)
  end

  def unsupported(reason)
    Result.new(
      supported: false,
      reason: reason,
      token0_price_usd: nil,
      token1_price_usd: nil,
      total_value_usd: nil,
      quote_token: @quote_token_address,
      valuation_source: nil,
      verification_status: "unsupported"
    )
  end

  def normalize_address_or_nil(address)
    value = address.to_s.downcase
    return nil unless value.match?(EVM_ADDRESS_PATTERN)

    value
  end
end
