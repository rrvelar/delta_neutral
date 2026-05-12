module HedgeBackends
  class MarketMetadata
    ATTRIBUTES = %i[
      backend asset market status size_decimals lot_size tick_size min_order_size
      min_notional_usd max_leverage collateral raw result_status
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(
      backend:, asset:, market:, status: nil, size_decimals: nil, lot_size: nil,
      tick_size: nil, min_order_size: nil, min_notional_usd: nil,
      max_leverage: nil, collateral: nil, raw: {}, result_status: "unknown"
    )
      @backend = backend
      @asset = asset
      @market = market
      @status = status
      @size_decimals = size_decimals
      @lot_size = decimal_or_nil(lot_size)
      @tick_size = decimal_or_nil(tick_size)
      @min_order_size = decimal_or_nil(min_order_size)
      @min_notional_usd = decimal_or_nil(min_notional_usd)
      @max_leverage = decimal_or_nil(max_leverage)
      @collateral = collateral
      @raw = raw || {}
      @result_status = result_status
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }.merge(status: result_status, exchange_status: status)
    end

    def as_json(*)
      to_h.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
    end

    private

    def decimal_or_nil(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end
  end
end
