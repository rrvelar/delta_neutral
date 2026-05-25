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
    REQUIRED_MARKET_METADATA = {
      "EXTENDED_MARKET_SYMBOL" => "EXTENDED_MARKET_SYMBOL missing",
      "EXTENDED_SIZE_INCREMENT" => "EXTENDED_SIZE_INCREMENT missing",
      "EXTENDED_PRICE_INCREMENT" => "EXTENDED_PRICE_INCREMENT missing"
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

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      dry_run_preview(action: "open_short", symbol: symbol, size_eth: size_eth, max_slippage: max_slippage, reduce_only: false)
    end

    def rebalance_preview(symbol:, delta_eth:, max_slippage:)
      delta = BigDecimal(delta_eth.to_s)
      if delta.negative?
        dry_run_preview(action: "decrease_short", symbol: symbol, size_eth: delta.abs, max_slippage: max_slippage, reduce_only: true)
      else
        dry_run_preview(action: "increase_short", symbol: symbol, size_eth: delta, max_slippage: max_slippage, reduce_only: false)
      end
    end

    def close_preview(symbol:, size_eth:)
      dry_run_preview(action: "close_short", symbol: symbol, size_eth: size_eth, max_slippage: nil, reduce_only: true)
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
        market_metadata_available: market_metadata_available?,
        blockers: blockers,
        warnings: warnings
      }
    end

    def blockers
      (config_blockers + market_metadata_blockers + [
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

    def dry_run_preview(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      requested_size = decimal_or_nil(size_eth)
      rounded_size = rounded_order_size_or_nil(requested_size)
      {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        action: action,
        symbol: symbol,
        requested_size_eth: decimal_string_or_unknown(requested_size),
        rounded_size_eth: rounded_size ? rounded_size.to_s("F") : "unknown",
        max_slippage: max_slippage&.to_s,
        reduce_only: reduce_only,
        submit_enabled: false,
        signature_required: false,
        order_submission: false,
        payload: order_intent_payload(
          action: action,
          symbol: symbol,
          requested_size: requested_size,
          rounded_size: rounded_size,
          max_slippage: max_slippage,
          reduce_only: reduce_only
        ),
        blockers: blockers,
        warnings: warnings
      }
    end

    def configured?
      config_blockers.empty?
    end

    def config_blockers
      REQUIRED_CONFIG.filter_map do |key, message|
        message if env[key].blank?
      end
    end

    def market_metadata_available?
      market_metadata_blockers.empty?
    end

    def market_metadata_blockers
      REQUIRED_MARKET_METADATA.filter_map do |key, message|
        message if env[key].blank?
      end
    end

    def market_symbol
      env["EXTENDED_MARKET_SYMBOL"].presence || "ETH-USD"
    end

    def order_intent_payload(action:, symbol:, requested_size:, rounded_size:, max_slippage:, reduce_only:)
      side = reduce_only ? "buy" : "sell"
      {
        schema: "extended_dry_run_order_intent",
        body_shape: "extended_order_intent_summary",
        venue: venue_name,
        market_symbol: market_symbol,
        symbol: symbol,
        action: action,
        side: side,
        extended_side: side.upcase,
        reduce_only: reduce_only,
        requested_size_eth: decimal_string_or_unknown(requested_size),
        rounded_size_eth: rounded_size ? rounded_size.to_s("F") : "unknown",
        size_increment: env["EXTENDED_SIZE_INCREMENT"].presence || "required_later",
        price_increment: env["EXTENDED_PRICE_INCREMENT"].presence || "required_later",
        price: "required_later",
        crossing_price: "required_later",
        order_type_assumption: "market-like crossing IOC limit; Extended requires an explicit worst accepted price",
        time_in_force: "IOC_required_later",
        expiration: "required_later",
        fee: "required_later",
        max_slippage: max_slippage&.to_s,
        margin_mode: "unverified",
        submit_endpoint: nil,
        future_submit_endpoint: "POST /user/order",
        order_submission: false,
        signature_required: false,
        stark_signature_created: false,
        signing_implemented: false,
        submit_implemented: false,
        cancel_implemented: false
      }
    end

    def rounded_order_size_or_nil(size)
      increment = decimal_or_nil(env["EXTENDED_SIZE_INCREMENT"])
      return nil unless size && increment&.positive?

      (size / increment).floor * increment
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

    def decimal_string_or_unknown(value)
      value ? value.to_s("F") : "unknown"
    end
  end
end
