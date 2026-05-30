module HedgeVenueAutoAdapters
  class Ethereal < Base
    CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_ETHEREAL_REBALANCE_ORDER".freeze

    def initialize(env: ENV, ethereal_service: EtherealHedgeExecutionService.new(env: env),
                   extended_venue: HedgeVenues::Extended.new(env: env), nado_venue: HedgeVenues::Nado.new(env: env), **kwargs)
      super(env: env, **kwargs)
      @ethereal_service = ethereal_service
      @extended_venue = extended_venue
      @nado_venue = nado_venue
    end

    def readiness(position:)
      current = @ethereal_service.read_position
      account_state = ethereal_account_state
      report = base_report(
        position: position,
        venue: "ethereal",
        current_position: current,
        other_positions: {
          "extended" => @extended_venue.read_position(symbol: "ETH"),
          "nado" => @nado_venue.read_position(symbol: "ETH")
        },
        account_state: account_state,
        live_enabled: bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED"),
        auto_enabled: bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
        extra_blockers: ethereal_blockers(current: current, account_state: account_state),
        warnings: ethereal_warnings
      )
      report.merge(
        ethereal_current_short_eth: report[:current_short_eth],
        ethereal_auto_rebalance_enabled: report[:active_auto_enabled],
        ethereal_live_enabled: report[:active_live_enabled]
      )
    end

    private

    def ethereal_blockers(current:, account_state:)
      blockers = []
      blockers << "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true" unless bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
      blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" unless bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
      blockers << "current Ethereal readback is unavailable" if current == :unavailable
      blockers << "current Ethereal position is long; manual action required" if current.is_a?(Hash) && current[:side].to_s == "long"
      blockers << "Ethereal open orders readback unavailable; live auto fails closed" unless account_state.key?(:open_orders_count)
      blockers
    end

    def ethereal_account_state
      state = @ethereal_service.instance_variable_get(:@venue).account_state
      state.is_a?(Hash) ? state : {}
    rescue
      {}
    end

    def ethereal_warnings
      if bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
        [ "Ethereal continuous auto is enabled and gated by fresh target, open-order, signer, and readback checks." ]
      else
        [ "Ethereal continuous auto is disabled; inside-tolerance production health should be stable but manual." ]
      end
    end
  end
end
