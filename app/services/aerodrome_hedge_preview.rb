# Preview-only Aerodrome hedge sizing for operator review.
#
# This service never calls Hyperliquid, never places orders, and never enables
# execution. It only computes what a 1x WETH short would look like for a
# supported WETH/USDC monitor-only position.
class AerodromeHedgePreview
  SOURCE = "Aerodrome monitor-only WETH/USDC amount preview"
  EVM_ADDRESS_PATTERN = /\A0x[0-9a-f]{40}\z/

  Result = Data.define(
    :supported,
    :reason,
    :hedge_asset,
    :hedge_side,
    :suggested_short_amount,
    :suggested_short_notional_usd,
    :lp_weth_amount,
    :lp_usdc_amount,
    :lp_total_value_usd,
    :weth_price_usd,
    :source,
    :execution_enabled,
    :hyperliquid_called,
    :verification_status
  )

  def initialize(weth_address: ENV["AERODROME_WETH_ADDRESS"].presence)
    @weth_address = normalize_address_or_nil(weth_address)
  end

  def preview(position_data)
    return unsupported("AERODROME_WETH_ADDRESS is not configured") if @weth_address.nil?
    return unsupported("amount math is not verified") unless position_data.verification_status == "verified_math"
    return unsupported("USD valuation is unsupported") unless position_data.valuation_status == "supported"

    token0_address = normalize_address_or_nil(position_data.token0_address)
    token1_address = normalize_address_or_nil(position_data.token1_address)
    return unsupported("token address is invalid") if token0_address.nil? || token1_address.nil?

    weth_index =
      if token0_address == @weth_address
        0
      elsif token1_address == @weth_address
        1
      end
    return unsupported("position does not include configured WETH token") if weth_index.nil?

    weth_amount = token_decimal_amount(position_data, weth_index)
    usdc_amount = token_decimal_amount(position_data, 1 - weth_index)
    weth_price = weth_index.zero? ? position_data.token0_price_usd : position_data.token1_price_usd
    return unsupported("WETH price is unavailable") if weth_price.nil?

    supported_result(
      weth_amount: weth_amount,
      usdc_amount: usdc_amount,
      weth_price: BigDecimal(weth_price.to_s),
      total_value_usd: position_data.total_value_usd
    )
  rescue AerodromeSlipstreamMath::Error => e
    unsupported(e.message)
  end

  def preview_fields(token0_address:, token1_address:, amount0_decimal:, amount1_decimal:, token0_price_usd:, token1_price_usd:, total_value_usd:, amount_verified:, valuation_supported:)
    return unsupported("AERODROME_WETH_ADDRESS is not configured") if @weth_address.nil?
    return unsupported("amount math is not verified") unless amount_verified
    return unsupported("USD valuation is unsupported") unless valuation_supported

    token0_address = normalize_address_or_nil(token0_address)
    token1_address = normalize_address_or_nil(token1_address)
    return unsupported("token address is invalid") if token0_address.nil? || token1_address.nil?

    weth_index =
      if token0_address == @weth_address
        0
      elsif token1_address == @weth_address
        1
      end
    return unsupported("position does not include configured WETH token") if weth_index.nil?

    weth_amount = weth_index.zero? ? BigDecimal(amount0_decimal.to_s) : BigDecimal(amount1_decimal.to_s)
    usdc_amount = weth_index.zero? ? BigDecimal(amount1_decimal.to_s) : BigDecimal(amount0_decimal.to_s)
    weth_price = weth_index.zero? ? token0_price_usd : token1_price_usd
    return unsupported("WETH price is unavailable") if weth_price.nil?

    supported_result(
      weth_amount: weth_amount,
      usdc_amount: usdc_amount,
      weth_price: BigDecimal(weth_price.to_s),
      total_value_usd: total_value_usd
    )
  rescue ArgumentError
    unsupported("amount or price is invalid")
  end

  private

  def supported_result(weth_amount:, usdc_amount:, weth_price:, total_value_usd:)
    Result.new(
      supported: true,
      reason: nil,
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: weth_amount,
      suggested_short_notional_usd: weth_amount * weth_price,
      lp_weth_amount: weth_amount,
      lp_usdc_amount: usdc_amount,
      lp_total_value_usd: total_value_usd,
      weth_price_usd: weth_price,
      source: SOURCE,
      execution_enabled: false,
      hyperliquid_called: false,
      verification_status: "preview_only"
    )
  end

  def token_decimal_amount(position_data, token_index)
    if token_index.zero?
      AerodromeSlipstreamMath.decimal_amount(position_data.amount0_raw, position_data.token0_decimals)
    else
      AerodromeSlipstreamMath.decimal_amount(position_data.amount1_raw, position_data.token1_decimals)
    end
  end

  def unsupported(reason)
    Result.new(
      supported: false,
      reason: reason,
      hedge_asset: nil,
      hedge_side: nil,
      suggested_short_amount: nil,
      suggested_short_notional_usd: nil,
      lp_weth_amount: nil,
      lp_usdc_amount: nil,
      lp_total_value_usd: nil,
      weth_price_usd: nil,
      source: nil,
      execution_enabled: false,
      hyperliquid_called: false,
      verification_status: "unsupported"
    )
  end

  def normalize_address_or_nil(address)
    value = address.to_s.downcase
    return nil unless value.match?(EVM_ADDRESS_PATTERN)

    value
  end
end
