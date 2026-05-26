class HedgeVenueAccounting
  COMPONENTS = %i[
    realized_pnl_usd
    unrealized_pnl_usd
    funding_pnl_usd
    trading_fees_usd
    borrow_interest_usd
    rebates_or_credits_usd
  ].freeze

  def initialize(position:, venue_key:, adapter:, current_position: nil, account_state: nil)
    @position = position
    @hedge = position.hedge
    @venue_key = HedgeVenues.normalize(venue_key)
    @adapter = adapter
    @current_position = current_position
    @account_state = account_state
  end

  def report
    position = @current_position || @adapter.read_position(symbol: "ETH")
    account = @account_state || @adapter.account_state
    components = component_values(position: position, account: account)

    {
      venue: @venue_key,
      venue_name: HedgeVenues.label(@venue_key),
      current_short_eth: short_size(position)&.to_s("F"),
      side: position&.dig(:side),
      margin_mode: position&.dig(:margin_mode),
      entry_price: decimal_string(position&.dig(:entry_price)),
      mark_price: decimal_string(position&.dig(:mark_price)),
      notional_usd: decimal_string(position&.dig(:notional_usd)),
      fee_rates: fee_rates(account),
      components: components,
      net_venue_pnl_usd: net_pnl(components)&.to_s("F"),
      unavailable_components: components.select { |_key, value| value[:state] == "unavailable" }.keys,
      history: history_rows
    }
  rescue => e
    {
      venue: @venue_key,
      venue_name: HedgeVenues.label(@venue_key),
      components: unavailable_components,
      net_venue_pnl_usd: nil,
      unavailable_components: COMPONENTS,
      warnings: [ "#{HedgeVenues.label(@venue_key)} accounting unavailable: #{e.class}: #{e.message}" ]
    }
  end

  private

  def component_values(position:, account:)
    {
      realized_pnl_usd: component(realized_from_history, source: "ShortRebalance history"),
      unrealized_pnl_usd: component(unrealized_from_position(position), source: "venue readback"),
      funding_pnl_usd: component(value_from(account, :funding_pnl_usd, :funding_total_usd), source: "venue account readback"),
      trading_fees_usd: component(value_from(account, :trading_fees_usd, :trading_fees_total_usd), source: "venue account readback"),
      borrow_interest_usd: component(value_from(account, :borrow_interest_usd, :borrow_interest_total_usd), source: "venue account readback"),
      rebates_or_credits_usd: component(value_from(account, :rebates_or_credits_usd, :rebates_total_usd), source: "venue account readback")
    }
  end

  def component(value, source:)
    decimal = decimal_or_nil(value)
    return { state: "unavailable", value: nil, source: source } unless decimal

    { state: "available", value: decimal.to_s("F"), source: source }
  end

  def net_pnl(components)
    realized = required_decimal(components, :realized_pnl_usd)
    unrealized = required_decimal(components, :unrealized_pnl_usd)
    return nil unless realized && unrealized

    funding = optional_decimal(components, :funding_pnl_usd)
    fees = optional_decimal(components, :trading_fees_usd)
    borrow = optional_decimal(components, :borrow_interest_usd)
    rebates = optional_decimal(components, :rebates_or_credits_usd)

    realized + unrealized + funding - fees - borrow + rebates
  end

  def required_decimal(components, key)
    decimal_or_nil(components.dig(key, :value))
  end

  def optional_decimal(components, key)
    decimal_or_nil(components.dig(key, :value)) || BigDecimal("0")
  end

  def realized_from_history
    return nil unless @hedge

    @hedge.short_rebalances.where(venue: @venue_key, status: ShortRebalance::STATUS_SUCCESS).sum(:realized_pnl)
  end

  def unrealized_from_position(position)
    return nil unless position&.dig(:side) == "short"
    return position[:unrealized_pnl_usd] if position[:unrealized_pnl_usd].present?

    entry = decimal_or_nil(position[:entry_price])
    mark = decimal_or_nil(position[:mark_price])
    size = short_size(position)
    return nil unless entry && mark && size&.positive?

    (entry - mark) * size
  end

  def short_size(position)
    return BigDecimal("0") unless position
    return decimal_or_nil(position[:short_size]) if position[:short_size].present?

    size = decimal_or_nil(position[:size])
    size&.negative? ? size.abs : BigDecimal("0")
  end

  def fee_rates(account)
    rates = value_from(account, :fee_rates)
    return rates if rates.present?

    {}
  end

  def history_rows
    return [] unless @hedge

    @hedge.short_rebalances.where(venue: @venue_key).order(rebalanced_at: :desc).limit(10).map do |rebalance|
      {
        id: rebalance.id,
        time: rebalance.rebalanced_at,
        side: rebalance.order_side,
        reduce_only: rebalance.reduce_only,
        old_short_size: rebalance.old_short_size&.to_s("F"),
        new_short_size: rebalance.new_short_size&.to_s("F"),
        realized_pnl: rebalance.realized_pnl&.to_s("F"),
        status: rebalance.status,
        exchange_order_id: rebalance.exchange_order_id,
        message: rebalance.message
      }
    end
  end

  def unavailable_components
    COMPONENTS.index_with { { state: "unavailable", value: nil, source: "unavailable" } }
  end

  def value_from(source, *keys)
    return nil unless source.respond_to?(:[])

    keys.each do |key|
      return source[key] if source.respond_to?(:key?) && source.key?(key)
      return source[key.to_s] if source.respond_to?(:key?) && source.key?(key.to_s)
    end
    nil
  end

  def decimal_string(value)
    decimal_or_nil(value)&.to_s("F")
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end
end
