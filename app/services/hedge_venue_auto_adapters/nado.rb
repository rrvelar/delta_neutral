module HedgeVenueAutoAdapters
  class Nado < Base
    def initialize(env: ENV, nado_venue: HedgeVenues::Nado.new(env: env),
                   extended_venue: HedgeVenues::Extended.new(env: env), ethereal_service: EtherealHedgeExecutionService.new(env: env),
                   nado_service: nil, **kwargs)
      super(env: env, **kwargs)
      @nado_venue = nado_venue
      @extended_venue = extended_venue
      @ethereal_service = ethereal_service
      @nado_service = nado_service || NadoHedgeExecutionService.new(env: env, venue: nado_venue)
    end

    def readiness(position:, mode: :continuous_auto)
      mode = mode.to_sym
      current = @nado_venue.read_position(symbol: "ETH")
      account_state = @nado_venue.account_state
      market_metadata = @nado_service.market_metadata(position: position)
      report = base_report(
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
        extra_blockers: nado_blockers(current: current, account_state: account_state, market_metadata: market_metadata, mode: mode),
        warnings: nado_warnings(mode: mode)
      )
      report.merge(
        readiness_mode: mode.to_s,
        manual_one_shot_ready: mode == :manual_one_shot && report[:blockers].blank? && report[:planned_auto_action].to_s != "no_op",
        manual_one_shot_blockers: mode == :manual_one_shot ? report[:blockers] : nil,
        nado_current_short_eth: report[:current_short_eth],
        nado_auto_rebalance_enabled: bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
        nado_live_enabled: bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED"),
        nado_market_metadata_status: market_metadata[:status],
        nado_market_price: market_metadata[:market_price],
        nado_market_price_source: market_metadata[:market_price_source],
        nado_market_metadata_source: market_metadata[:source],
        nado_price_increment: market_metadata[:price_increment],
        nado_size_increment: market_metadata[:size_increment]
      )
    end

    private

    def nado_blockers(current:, account_state:, market_metadata:, mode:)
      blockers = []
      blockers << "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" if mode == :continuous_auto && !bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
      blockers << "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true" unless bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
      blockers << "current Nado readback is unavailable" if current == :unavailable
      blockers << "current Nado position is long; manual action required" if current.is_a?(Hash) && current[:side].to_s == "long"
      blockers << "Nado open orders readback unavailable; live auto fails closed" if account_state[:open_orders_count].nil?
      blockers.concat(Array(market_metadata[:blockers]))
      blockers
    end

    def nado_warnings(mode:)
      if mode == :manual_one_shot
        [ "Nado manual one-shot rebalance uses the Nado live gate and exact phrase; continuous auto does not need to be enabled." ]
      elsif bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
        [ "Nado one-shot auto is enabled and gated by fresh target, flat source venues, open-order, signer, and readback checks." ]
      else
        [ "Nado continuous auto is disabled; one-shot dry-run can prove the active-venue path without submitting." ]
      end
    end
  end
end
