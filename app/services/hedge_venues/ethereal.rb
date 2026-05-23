module HedgeVenues
  class Ethereal < Base
    def initialize(probe: nil, **kwargs)
      super(**kwargs)
      @probe = probe
    end

    def venue_name
      "Ethereal"
    end

    def live_flag_enabled?
      bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    end

    def live_confirmation_phrase
      env["AERODROME_ETHEREAL_HEDGE_CONFIRMATION"].to_s
    end

    def read_position(symbol:)
      return nil if config_blockers.any?

      snapshot = probe.get_position(normalize_symbol(symbol))
      return nil if snapshot.is_a?(Hash) && snapshot[:status] == "unsupported"

      snapshot
    rescue => e
      @warnings = warnings + [ "Ethereal position readback unavailable: #{e.class}: #{e.message}" ]
      nil
    end

    def account_state
      return super if config_blockers.any?

      normalize_account_state(probe.account_health)
    rescue => e
      { venue: venue_name, mode: mode, status: "unavailable", blockers: blockers, warnings: warnings + [ e.message ] }
    end

    def blockers
      [ "Dry-run/read-only only; live submit not enabled for Ethereal." ] + config_blockers
    end

    def warnings
      @warnings ||= [ "Ethereal previews build unsigned payload metadata only; no signing or order submission is available." ]
    end

    private

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      side = reduce_only ? "buy" : "sell"
      super.merge(
        schema: "ethereal_eip712_trade_order_preview",
        endpoint: "POST /v1/order",
        market_symbol: env.fetch("ETHEREAL_MARKET_SYMBOL", "ETH-USD").presence || "ETH-USD",
        side: side,
        reduce_only: reduce_only,
        order_type: "LIMIT_IOC",
        quantity: decimal_string(size_eth),
        signature: nil,
        typed_data_available: false,
        blocker: "Ethereal live submit is intentionally disabled in delta_neutral"
      )
    end

    def config_blockers
      blockers = []
      blockers << "ETHEREAL_READ_ONLY_ENABLED is not true" unless bool_env("ETHEREAL_READ_ONLY_ENABLED")
      blockers << "ETHEREAL_API_BASE_URL is required for Ethereal read-only account/position checks" if env["ETHEREAL_API_BASE_URL"].blank?
      blockers << "ETHEREAL_SUBACCOUNT_ID is required for Ethereal position readback" if env["ETHEREAL_SUBACCOUNT_ID"].blank?
      blockers
    end

    def probe
      @probe ||= HedgeBackends::EtherealReadOnlyProbe.new(env: env)
    end

    def normalize_account_state(value)
      source = if value.respond_to?(:to_h)
        value.to_h
      elsif value.respond_to?(:as_json)
        value.as_json
      else
        {}
      end
      source = source.to_h.with_indifferent_access

      {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        status: source[:status],
        backend: source[:backend],
        collateral: source[:collateral],
        account_value_usd: decimal_string_or_value(source[:account_value_usd]),
        withdrawable_usd: decimal_string_or_value(source[:withdrawable_usd]),
        margin_used_usd: decimal_string_or_value(source[:margin_used_usd]),
        blockers: blockers,
        warnings: warnings
      }.compact
    end

    def decimal_string_or_value(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value
    end

    def normalize_symbol(symbol)
      symbol.to_s.upcase == "WETH" ? "ETH" : symbol
    end
  end
end
