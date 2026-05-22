module ApplicationHelper
  def format_usd(value, precision: 2)
    n = number_with_delimiter(number_with_precision(value.to_f.abs, precision: precision))
    value.to_f < 0 ? "-$#{n}" : "$#{n}"
  end

  def aerodrome_position?(position)
    position.dex.name == "aerodrome_slipstream"
  end

  def dex_display_name(position)
    aerodrome_position?(position) ? "Aerodrome Slipstream" : position.dex.name.capitalize
  end

  def chain_display_name(position)
    position.wallet.network.name.capitalize
  end

  def amount_display(amount, precision:)
    amount.nil? ? "Unavailable" : number_with_precision(amount, precision: precision)
  end

  def format_token_amount(value, decimals: 6)
    return "unavailable" if value.blank?

    number_with_precision(BigDecimal(value.to_s), precision: decimals, strip_insignificant_zeros: true, delimiter: ",")
  rescue ArgumentError
    value.to_s
  end

  def format_usd_amount(value)
    return "unavailable" if value.blank?

    number_with_precision(BigDecimal(value.to_s), precision: 2, strip_insignificant_zeros: false, delimiter: ",")
  rescue ArgumentError
    value.to_s
  end

  def format_percent_amount(value)
    return "unavailable" if value.blank?

    "#{number_with_precision(BigDecimal(value.to_s), precision: 6, strip_insignificant_zeros: true, delimiter: ',')}%"
  rescue ArgumentError
    "#{value}%"
  end

  def format_share_balance(value)
    return "unavailable" if value.blank?

    number_with_precision(BigDecimal(value.to_s), precision: 12, strip_insignificant_zeros: true, delimiter: ",")
  rescue ArgumentError
    value.to_s
  end

  def price_display(price)
    price.nil? ? "Unavailable" : "#{format_usd(price)}/unit"
  end

  def asset_value_usd(amount, price)
    return nil if amount.nil? || price.nil?

    amount * price
  end

  def asset_value_display(amount, price)
    value = asset_value_usd(amount, price)
    value.nil? ? "Unavailable" : format_usd(value)
  end

  def rebalance_status_class(status)
    case status.to_s
    when ShortRebalance::STATUS_SUCCESS
      "bg-green-950/60 text-green-300 border-green-800"
    when ShortRebalance::STATUS_FAILED, "error"
      "bg-red-950/60 text-red-200 border-red-800"
    when "skipped", "pending"
      "bg-yellow-950/60 text-yellow-200 border-yellow-800"
    else
      "bg-gray-800 text-gray-300 border-gray-700"
    end
  end

  def signed_eth_delta(delta)
    return "—" if delta.nil?

    "#{delta.negative? ? '-' : '+'}#{number_with_precision(delta.abs, precision: 6)}"
  end

  def auto_rebalance_status_class(status)
    case status.to_s
    when "active"
      "bg-green-950/60 text-green-300 border-green-800"
    when "blocked"
      "bg-red-950/60 text-red-200 border-red-800"
    else
      "bg-yellow-950/60 text-yellow-200 border-yellow-800"
    end
  end

  def aerodrome_hedge_preview_for(position)
    return nil unless aerodrome_position?(position)

    weth_address = ENV["AERODROME_WETH_ADDRESS"].presence
    usdc_address = ENV["AERODROME_USDC_ADDRESS"].presence
    return unavailable_hedge_preview("AERODROME_WETH_ADDRESS is not configured") if weth_address.blank?
    return unavailable_hedge_preview("AERODROME_USDC_ADDRESS is not configured") if usdc_address.blank?

    token_addresses = configured_token_addresses_for(position, weth_address, usdc_address)
    return unavailable_hedge_preview("position token identity is not a configured WETH/USDC pair") if token_addresses.nil?

    if [ position.asset0_amount, position.asset1_amount, position.asset0_price_usd, position.asset1_price_usd ].any?(&:nil?)
      return unavailable_hedge_preview("amount or USD price is missing")
    end

    AerodromeHedgePreview.new(weth_address: weth_address).preview_fields(
      token0_address: token_addresses.fetch(:token0_address),
      token1_address: token_addresses.fetch(:token1_address),
      amount0_decimal: position.asset0_amount,
      amount1_decimal: position.asset1_amount,
      token0_price_usd: position.asset0_price_usd,
      token1_price_usd: position.asset1_price_usd,
      total_value_usd: position.total_value_usd,
      amount_verified: true,
      valuation_supported: true
    )
  end

  private

  def unavailable_hedge_preview(reason)
    AerodromeHedgePreview::Result.new(
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

  def configured_token_addresses_for(position, weth_address, usdc_address)
    symbols = [ position.asset0.to_s.upcase, position.asset1.to_s.upcase ]
    return unless symbols.sort == [ "USDC", "WETH" ]

    {
      token0_address: symbols[0] == "WETH" ? weth_address : usdc_address,
      token1_address: symbols[1] == "WETH" ? weth_address : usdc_address
    }
  end
end
