module HedgeVenues
  class SingleVenuePreflight
    CONFLICTING_POSITION_BLOCKER = "current venue readback has a conflicting ETH position".freeze

    def initialize(venue:, position:, action:, target_size_eth:, current_position:, confirmation:, max_slippage:, env: ENV)
      @venue = venue
      @position = position
      @action = action.to_s
      @target_size_eth = decimal_or_zero(target_size_eth)
      @current_position = current_position
      @confirmation = confirmation.to_s
      @max_slippage = max_slippage
      @env = env
    end

    def report
      {
        venue: @venue.venue_name,
        mode: @venue.mode,
        live_mode_state: @venue.live_mode_state,
        live_supported: @venue.live_supported?,
        live_enabled: @venue.live_enabled?,
        action: @action,
        position_id: @position.id,
        position_source: @position.position_source,
        source_external_id: @position.external_id,
        target_hedge_size_eth: decimal_string(@target_size_eth),
        rounded_order_size_eth: decimal_string(@venue.round_order_size(@target_size_eth)),
        estimated_notional_usd: estimated_notional_usd,
        intended_side: intended_side,
        symbol: "ETH-PERP",
        reduce_only_close_available: @venue.close_reduce_only_available?,
        current_venue_position: serialize_current_position,
        current_venue_open_orders: "not_available",
        max_slippage: @max_slippage&.to_s,
        submitted: false,
        manual_action_required: blockers.any?,
        next_action: next_action,
        blockers: blockers,
        warnings: warnings
      }
    end

    private

    def blockers
      @blockers ||= begin
        items = []
        items << "#{@venue.venue_name} live env flag is not true" unless @venue.live_flag_enabled?
        items << "#{@venue.venue_name} live submit adapter is not wired in delta_neutral"
        items << "submitted confirmation must equal #{@venue.live_confirmation_phrase}" unless confirmation_matches?
        items << "active Mellow Autopilot position is required for non-Hyperliquid single-venue live preflight" unless @position.mellow_autopilot? && @position.active?
        items << "Mellow Autopilot pro-rata exposure is not hedge-ready" if @position.mellow_autopilot? && !@position.hedge_ready?
        items << "target hedge size must be positive" unless @target_size_eth.positive?
        items << "close/reduce-only path is unavailable" unless @venue.close_reduce_only_available?
        items << "current venue open orders readback is unavailable"
        items << "Hyperliquid conflicting hedge check is not wired for non-Hyperliquid live submit"
        items << CONFLICTING_POSITION_BLOCKER if conflicting_position?
        items << "AERODROME_HEDGE_PAUSED must be false" if bool_env("AERODROME_HEDGE_PAUSED", default: true)
        items << "AERODROME_HEDGE_ENABLED must be true" unless bool_env("AERODROME_HEDGE_ENABLED")
        items.compact.uniq
      end
    end

    def warnings
      [
        "#{@venue.venue_name} single-venue live preflight is design-only in delta_neutral; no order is signed or submitted.",
        "Source of truth for #{@venue.venue_name} payload/signing semantics remains perp-hedge-research-bot execution adapter tests."
      ]
    end

    def next_action
      return "No live action available in delta_neutral for #{@venue.venue_name}." if blockers.any?

      "Review preflight receipt and keep live submit disabled until a separately audited adapter is wired."
    end

    def intended_side
      @action == "close" ? "buy_reduce_only" : "sell_short"
    end

    def estimated_notional_usd
      price = eth_price
      return nil unless price&.positive?

      decimal_string(@venue.round_order_size(@target_size_eth) * price)
    end

    def eth_price
      if @position.mellow_autopilot? && @position.mellow_weth_exposure&.positive? && @position.mellow_current_value_usd
        usdc = @position.mellow_usdc_exposure || BigDecimal("0")
        return (@position.mellow_current_value_usd - usdc) / @position.mellow_weth_exposure
      end

      @position.asset0_price_usd if @position.asset0.to_s.upcase.in?(%w[ETH WETH])
    end

    def confirmation_matches?
      @venue.live_confirmation_phrase.present? && @confirmation == @venue.live_confirmation_phrase
    end

    def conflicting_position?
      size = current_position_size
      return false if size.zero?

      return true if size.positive?
      return true if @action == "open"

      false
    end

    def current_position_size
      return BigDecimal("0") unless @current_position
      return BigDecimal(@current_position.size.to_s) if @current_position.respond_to?(:size) && !@current_position.is_a?(Hash)

      BigDecimal(@current_position.fetch(:size, 0).to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def serialize_current_position
      return nil unless @current_position
      return @current_position.as_json if @current_position.respond_to?(:as_json) && !@current_position.is_a?(Hash)

      @current_position.merge(size: decimal_string(current_position_size))
    end

    def decimal_or_zero(value)
      BigDecimal(value.to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def decimal_string(value)
      BigDecimal(value.to_s).to_s("F")
    end

    def bool_env(key, default: false)
      ActiveModel::Type::Boolean.new.cast(@env.fetch(key, default.to_s))
    end
  end
end
