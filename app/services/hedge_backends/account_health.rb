module HedgeBackends
  class AccountHealth
    ATTRIBUTES = %i[
      backend account subaccount collateral account_value_usd withdrawable_usd
      margin_used_usd raw status
    ].freeze

    attr_reader(*ATTRIBUTES)

    def initialize(
      backend:, account: nil, subaccount: nil, collateral: nil,
      account_value_usd: nil, withdrawable_usd: nil, margin_used_usd: nil,
      raw: {}, status: "unknown"
    )
      @backend = backend
      @account = account
      @subaccount = subaccount
      @collateral = collateral
      @account_value_usd = decimal_or_nil(account_value_usd)
      @withdrawable_usd = decimal_or_nil(withdrawable_usd)
      @margin_used_usd = decimal_or_nil(margin_used_usd)
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
