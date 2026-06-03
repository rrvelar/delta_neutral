module HedgeVenues
  class Base
    DRY_RUN_BLOCKER = "Dry-run/read-only only; live submit not enabled".freeze

    attr_reader :env

    def initialize(env: ENV, close_reduce_only_available: true, **)
      @env = env
      @close_reduce_only_available = close_reduce_only_available
    end

    def venue_name
      self.class.name.demodulize
    end

    def mode
      "read_only_dry_run"
    end

    def live_supported?
      false
    end

    def live_enabled?
      false
    end

    def live_mode_state
      live_flag_enabled? ? "live_configured_but_disabled" : mode
    end

    def live_flag_enabled?
      false
    end

    def live_confirmation_phrase
      nil
    end

    def close_reduce_only_available?
      @close_reduce_only_available
    end

    def read_position(symbol:)
      nil
    end

    def account_state
      { venue: venue_name, mode: mode, status: "not_configured", blockers: blockers, warnings: warnings }
    end

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      preview(action: "open_short", symbol: symbol, size_eth: size_eth, max_slippage: max_slippage, reduce_only: false)
    end

    def rebalance_preview(symbol:, delta_eth:, max_slippage:)
      action = BigDecimal(delta_eth.to_s).negative? ? "reduce_short" : "open_short"
      preview(action: action, symbol: symbol, size_eth: BigDecimal(delta_eth.to_s).abs, max_slippage: max_slippage, reduce_only: action == "reduce_short")
    end

    def close_preview(symbol:, size_eth:)
      preview(action: "close_short", symbol: symbol, size_eth: size_eth, max_slippage: nil, reduce_only: true)
    end

    def single_venue_preflight(position:, action:, target_size_eth:, current_position:, confirmation:, max_slippage:)
      SingleVenuePreflight.new(
        venue: self,
        position: position,
        action: action,
        target_size_eth: target_size_eth,
        current_position: current_position,
        confirmation: confirmation,
        max_slippage: max_slippage,
        env: env
      ).report
    end

    def round_order_size(value)
      round_size(value)
    end

    def blockers
      [ "#{DRY_RUN_BLOCKER} for #{venue_name}." ]
    end

    def warnings
      []
    end

    private

    def preview(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      rounded_size = round_size(size_eth)
      {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        action: action,
        symbol: symbol,
        requested_size_eth: decimal_string(size_eth),
        rounded_size_eth: decimal_string(rounded_size),
        max_slippage: max_slippage&.to_s,
        reduce_only: reduce_only,
        submit_enabled: false,
        signature_required: false,
        order_submission: false,
        payload: payload(action: action, symbol: symbol, size_eth: rounded_size, max_slippage: max_slippage, reduce_only: reduce_only),
        blockers: blockers,
        warnings: warnings
      }
    end

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      {
        schema: "dry_run_preview",
        action: action,
        symbol: symbol,
        size_eth: decimal_string(size_eth),
        reduce_only: reduce_only,
        max_slippage: max_slippage&.to_s
      }
    end

    def round_size(value)
      BigDecimal(value.to_s)
    end

    def decimal_string(value)
      return nil unless value

      BigDecimal(value.to_s).to_s("F")
    end

    def bool_env(key)
      OperationalSettings.enabled?(key, env: env)
    end
  end
end
