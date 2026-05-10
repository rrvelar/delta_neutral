class AerodromeFeesService
  FeeData = Data.define(
    :status,
    :fee_source,
    :token_id,
    :pool_address,
    :fee0_symbol,
    :fee0_amount,
    :fee0_usd,
    :fee1_symbol,
    :fee1_amount,
    :fee1_usd,
    :total_fees_usd,
    :warnings,
    :blockers
  )

  SOURCE = "nonfungible_position_manager.positions.tokens_owed"

  def initialize(slipstream_service: nil)
    @slipstream_service = slipstream_service
  end

  def fees_for_position(position)
    raw_position = slipstream_service.position(position.external_id)
    token0 = slipstream_service.token_data(raw_position.token0_address)
    token1 = slipstream_service.token_data(raw_position.token1_address)
    fee0_amount = decimal_amount(raw_position.tokens_owed0_raw, token0.decimals)
    fee1_amount = decimal_amount(raw_position.tokens_owed1_raw, token1.decimals)
    fee0_usd = fee_usd(fee0_amount, token0.symbol, position)
    fee1_usd = fee_usd(fee1_amount, token1.symbol, position)

    FeeData.new(
      status: "detected",
      fee_source: SOURCE,
      token_id: position.external_id.to_s,
      pool_address: position.pool_address,
      fee0_symbol: token0.symbol,
      fee0_amount: fee0_amount,
      fee0_usd: fee0_usd,
      fee1_symbol: token1.symbol,
      fee1_amount: fee1_amount,
      fee1_usd: fee1_usd,
      total_fees_usd: total_fees_usd(fee0_usd, fee1_usd),
      warnings: [],
      blockers: []
    )
  end

  private

  def slipstream_service
    @slipstream_service ||= AerodromeSlipstreamService.new
  end

  def decimal_amount(raw, decimals)
    BigDecimal(raw.to_s) / (BigDecimal("10")**Integer(decimals))
  end

  def fee_usd(amount, symbol, position)
    price = price_for(symbol, position)
    return nil unless price

    amount * price
  end

  def total_fees_usd(fee0_usd, fee1_usd)
    return nil unless fee0_usd && fee1_usd

    fee0_usd + fee1_usd
  end

  def price_for(symbol, position)
    normalized = symbol.to_s.upcase
    return BigDecimal("1") if normalized == "USDC"

    return position.asset0_price_usd if normalized == position.asset0.to_s.upcase
    return position.asset1_price_usd if normalized == position.asset1.to_s.upcase

    nil
  end
end
