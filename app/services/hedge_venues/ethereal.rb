module HedgeVenues
  class Ethereal < Base
    def venue_name
      "Ethereal"
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

      probe.account_health
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

    def normalize_symbol(symbol)
      symbol.to_s.upcase == "WETH" ? "ETH" : symbol
    end
  end
end
