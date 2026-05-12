module HedgeBackends
  class PositionSnapshot
    ATTRIBUTES = %i[
      backend asset market signed_size short_size entry_price mark_price
      position_value margin_used unrealized_pnl liquidation_price account raw status
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(
      backend:, asset:, market:, signed_size: nil, short_size: nil,
      entry_price: nil, mark_price: nil, position_value: nil, margin_used: nil,
      unrealized_pnl: nil, liquidation_price: nil, account: nil, raw: {}, status: "unknown"
    )
      @backend = backend
      @asset = asset
      @market = market
      @signed_size = decimal_or_nil(signed_size)
      @short_size = decimal_or_nil(short_size)
      @entry_price = decimal_or_nil(entry_price)
      @mark_price = decimal_or_nil(mark_price)
      @position_value = decimal_or_nil(position_value)
      @margin_used = decimal_or_nil(margin_used)
      @unrealized_pnl = decimal_or_nil(unrealized_pnl)
      @liquidation_price = decimal_or_nil(liquidation_price)
      @account = account
      @raw = raw || {}
      @status = status
    end

    def to_h
      ATTRIBUTES.index_with { |attribute| public_send(attribute) }
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
