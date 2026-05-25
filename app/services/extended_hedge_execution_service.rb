class ExtendedHedgeExecutionService
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  BLOCKERS = [
    "Extended live disabled.",
    "Extended submit endpoint integration not implemented."
  ].freeze

  def initialize(venue: HedgeVenues::Extended.new, signer_client: ExtendedStarkSignerClient.new)
    @venue = venue
    @signer_client = signer_client
  end

  def preflight(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:)
    preview = dry_run_preview(action: action, size_eth: size_eth, max_slippage: max_slippage)
    {
      venue: "Extended",
      mode: @venue.mode,
      live_supported: false,
      live_enabled: false,
      action: action.to_s,
      position_id: position.id,
      target_hedge_size_eth: decimal_string(size_eth),
      rounded_order_size_eth: preview.dig(:payload, :rounded_size_eth),
      estimated_notional_usd: nil,
      intended_side: intended_side(action: action, size_eth: size_eth),
      margin_mode: "unverified",
      current_venue_position: current_position,
      max_slippage: max_slippage.to_s,
      order_intent: preview[:payload],
      submitted: false,
      manual_action_required: true,
      next_action: "Extended is read-only scaffold only; do not submit orders.",
      signer_health: sanitized_signer_health,
      blockers: preflight_blockers,
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

  def open_short_preview(size_eth:, max_slippage: nil)
    @venue.open_short_preview(symbol: "ETH", size_eth: size_eth, max_slippage: max_slippage)
  end

  def increase_short_preview(size_eth:, max_slippage: nil)
    @venue.rebalance_preview(symbol: "ETH", delta_eth: size_eth, max_slippage: max_slippage)
  end

  def decrease_short_preview(size_eth:, max_slippage: nil)
    @venue.rebalance_preview(symbol: "ETH", delta_eth: -BigDecimal(size_eth.to_s), max_slippage: max_slippage)
  end

  def close_short_preview(size_eth:)
    @venue.close_preview(symbol: "ETH", size_eth: size_eth)
  end

  private

  def dry_run_preview(action:, size_eth:, max_slippage:)
    case action.to_s
    when "open"
      open_short_preview(size_eth: size_eth, max_slippage: max_slippage)
    when "close"
      close_short_preview(size_eth: size_eth)
    else
      value = BigDecimal(size_eth.to_s)
      value.negative? ? decrease_short_preview(size_eth: value.abs, max_slippage: max_slippage) : increase_short_preview(size_eth: value, max_slippage: max_slippage)
    end
  end

  def intended_side(action:, size_eth:)
    return "buy_reduce_only" if action.to_s == "close"

    BigDecimal(size_eth.to_s).negative? ? "buy_reduce_only" : "sell_short"
  rescue ArgumentError
    "unknown"
  end

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

  def preflight_blockers
    blockers = (@venue.blockers + BLOCKERS).uniq
    health = signer_health
    blockers << "EXTENDED_SIGNER_URL missing" if health[:reason] == "EXTENDED_SIGNER_URL missing"
    blockers << "Extended Stark signer unhealthy: #{health[:reason]}" unless ActiveModel::Type::Boolean.new.cast(health[:ok])
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    blockers.uniq
  end

  def signer_health
    @signer_health ||= @signer_client.health.with_indifferent_access
  end

  def sanitized_signer_health
    signer_health.to_h.except(:api_key, :private_key, :signature, "api_key", "private_key", "signature")
  end
end
