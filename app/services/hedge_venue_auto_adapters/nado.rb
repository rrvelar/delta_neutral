module HedgeVenueAutoAdapters
  class Nado < Base
    MISSING_CAPABILITIES = [
      "Nado isolated live auto open/increase submit path is not proven in delta_neutral.",
      "Nado isolated reduce-only decrease/close live path is not proven in delta_neutral.",
      "Nado isolated readback confirmation and open-order gates are not fully wired for continuous auto."
    ].freeze

    def initialize(env: ENV, nado_venue: HedgeVenues::Nado.new(env: env),
                   extended_venue: HedgeVenues::Extended.new(env: env), ethereal_service: EtherealHedgeExecutionService.new(env: env), **kwargs)
      super(env: env, **kwargs)
      @nado_venue = nado_venue
      @extended_venue = extended_venue
      @ethereal_service = ethereal_service
    end

    def readiness(position:)
      current = @nado_venue.read_position(symbol: "ETH")
      account_state = @nado_venue.account_state
      base_report(
        position: position,
        venue: "nado",
        current_position: current,
        other_positions: {
          "extended" => @extended_venue.read_position(symbol: "ETH"),
          "ethereal" => @ethereal_service.read_position
        },
        account_state: account_state,
        live_enabled: bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED"),
        auto_enabled: bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
        extra_blockers: MISSING_CAPABILITIES + [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ].reject { bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED") },
        warnings: [ "Nado auto remains fail-closed until isolated lifecycle capabilities are proven and tested." ]
      ).merge(
        missing_capabilities: MISSING_CAPABILITIES,
        continuous_auto_ready: false,
        active_auto_ready: false
      )
    end
  end
end
