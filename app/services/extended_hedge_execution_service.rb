class ExtendedHedgeExecutionService
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  BLOCKERS = [
    "Extended live disabled.",
    "Extended signing/order submit not implemented."
  ].freeze

  def initialize(venue: HedgeVenues::Extended.new)
    @venue = venue
  end

  def preflight(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:)
    {
      venue: "Extended",
      mode: @venue.mode,
      live_supported: false,
      live_enabled: false,
      action: action.to_s,
      position_id: position.id,
      target_hedge_size_eth: decimal_string(size_eth),
      rounded_order_size_eth: decimal_string(@venue.round_order_size(size_eth)),
      estimated_notional_usd: nil,
      intended_side: action.to_s == "close" || BigDecimal(size_eth.to_s).negative? ? "buy_reduce_only" : "sell_short",
      margin_mode: "unverified",
      current_venue_position: current_position,
      max_slippage: max_slippage.to_s,
      submitted: false,
      manual_action_required: true,
      next_action: "Extended is read-only scaffold only; do not submit orders.",
      blockers: (@venue.blockers + BLOCKERS).uniq,
      warnings: @venue.warnings
    }
  end

  def open_short(**)
    blocked_result("open")
  end

  def rebalance_short(**)
    blocked_result("rebalance")
  end

  def close_short(**)
    blocked_result("close")
  end

  private

  def blocked_result(action)
    Result.new(
      "blocked_before_submit",
      (@venue.blockers + BLOCKERS).uniq,
      @venue.warnings,
      {
        venue: "extended",
        action: action,
        submitted: false,
        orders_submitted: 0,
        signatures_created: 0,
        final_status: "blocked_before_submit",
        blockers: (@venue.blockers + BLOCKERS).uniq
      }
    )
  end

  def decimal_string(value)
    BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError
    nil
  end
end
