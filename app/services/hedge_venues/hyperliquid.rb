module HedgeVenues
  class Hyperliquid < Base
    def initialize(hyperliquid_service: nil, **kwargs)
      super(**kwargs)
      @hyperliquid_service = hyperliquid_service
    end

    def venue_name
      "Hyperliquid"
    end

    def mode
      "live"
    end

    def live_supported?
      true
    end

    def live_enabled?
      AerodromeDashboardHedgeAction.execution_gate_blockers.empty?
    end

    def read_position(symbol:)
      hyperliquid.get_position(HyperliquidService.normalize_symbol(symbol))
    end

    def account_state
      { venue: venue_name, mode: mode, status: "available", blockers: blockers, warnings: warnings }
    end

    def blockers
      AerodromeDashboardHedgeAction.execution_gate_blockers
    end

    private

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      super.merge(
        schema: "hyperliquid_dashboard_action",
        live_order_capable: true,
        normalized_symbol: HyperliquidService.normalize_symbol(symbol)
      )
    end

    def hyperliquid
      @hyperliquid_service ||= HyperliquidService.new(testnet: false)
    end
  end
end
