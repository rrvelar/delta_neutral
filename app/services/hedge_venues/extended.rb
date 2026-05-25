module HedgeVenues
  class Extended < Base
    REQUIRED_CONFIG = {
      "EXTENDED_API_BASE_URL" => "EXTENDED_API_BASE_URL missing",
      "EXTENDED_API_KEY" => "EXTENDED_API_KEY missing",
      "EXTENDED_ACCOUNT_ID" => "EXTENDED_ACCOUNT_ID missing",
      "EXTENDED_VAULT_NUMBER" => "EXTENDED_VAULT_NUMBER missing",
      "EXTENDED_CLIENT_ID" => "EXTENDED_CLIENT_ID missing",
      "EXTENDED_STARK_PUBLIC_KEY" => "EXTENDED_STARK_PUBLIC_KEY missing"
    }.freeze

    def venue_name
      "Extended"
    end

    def mode
      "read_only_scaffold"
    end

    def live_supported?
      false
    end

    def live_enabled?
      false
    end

    def live_flag_enabled?
      false
    end

    def live_confirmation_phrase
      nil
    end

    def read_position(symbol:)
      nil
    end

    def normalize_position(snapshot)
      source = snapshot.to_h.with_indifferent_access
      size = decimal_or_nil(source[:size])
      side = normalized_side(source[:side], size)
      short_size = side == "short" ? (size&.abs || decimal_or_nil(source[:short_size]) || BigDecimal("0")) : BigDecimal("0")
      notional = decimal_or_nil(source[:notional_usd] || source[:value])
      account_value = decimal_or_nil(source[:account_value_usd] || source[:collateral_usd] || source[:equity])
      effective = notional && account_value&.positive? ? notional.abs / account_value : decimal_or_nil(source[:effective_leverage])

      {
        venue: venue_name,
        symbol: "ETH-PERP",
        market_symbol: source[:market] || market_symbol,
        side: side,
        size: size&.to_s("F"),
        short_size: short_size.to_s("F"),
        notional_usd: decimal_string_or_value(notional),
        entry_price: decimal_string_or_value(decimal_or_nil(source[:entry_price] || source[:open_price])),
        mark_price: decimal_string_or_value(decimal_or_nil(source[:mark_price])),
        unrealized_pnl_usd: decimal_string_or_value(decimal_or_nil(source[:unrealized_pnl_usd] || source[:unrealised_pnl])),
        account_value_usd: decimal_string_or_value(account_value),
        collateral_usd: decimal_string_or_value(decimal_or_nil(source[:collateral_usd] || source[:balance])),
        effective_leverage: effective&.to_s("F"),
        margin_mode: source[:margin_mode] || "unverified",
        status: source[:status],
        raw: source[:raw]
      }.compact
    end

    def account_state
      {
        venue: venue_name,
        mode: mode,
        status: configured? ? "read_only_scaffold" : "not_configured",
        live_supported: false,
        live_enabled: false,
        market_symbol: market_symbol,
        margin_mode: "unverified",
        blockers: blockers,
        warnings: warnings
      }
    end

    def blockers
      (config_blockers + [
        "Extended live disabled.",
        "Extended signing/order submit not implemented.",
        "Extended auto-rebalance disabled."
      ]).uniq
    end

    def warnings
      [
        "Extended read-only scaffold.",
        "Live disabled.",
        "Signing/order submit not implemented.",
        "Extended requires a separate Stark signer sidecar before any Phase 3+ live test."
      ]
    end

    private

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      super.merge(
        schema: "extended_read_only_scaffold",
        endpoint: nil,
        body_shape: nil,
        market_symbol: market_symbol,
        margin_mode: "unverified",
        side: reduce_only ? "buy" : "sell",
        reduce_only: reduce_only,
        order_submission: false,
        signature_required: false,
        signing_implemented: false,
        submit_implemented: false
      )
    end

    def configured?
      config_blockers.empty?
    end

    def config_blockers
      REQUIRED_CONFIG.filter_map do |key, message|
        message if env[key].blank?
      end
    end

    def market_symbol
      env["EXTENDED_MARKET_SYMBOL"].presence || "ETH-USD"
    end

    def normalized_side(raw_side, size)
      return "short" if size&.negative?
      return "long" if size&.positive?

      text = raw_side.to_s.downcase
      return "short" if text.in?(%w[short sell])
      return "long" if text.in?(%w[long buy])

      "flat"
    end

    def decimal_or_nil(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def decimal_string_or_value(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value
    end
  end
end
