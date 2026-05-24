class AerodromeProductionDashboardStatus
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(position:, hyperliquid_service: nil, hedge_venue_adapter: nil)
    @position = position
    @hedge = position.hedge
    @hyperliquid_service = hyperliquid_service
    @hedge_venue_adapter = hedge_venue_adapter
    @errors = []
  end

  def report
    eth_position = current_venue_position
    current_short = short_size(eth_position)
    target = target_short
    drift = target ? target - current_short : nil
    drift_usd = drift && eth_price ? drift * eth_price : nil
    blockers = cap_blockers(target: target, current_short: current_short)

    {
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      current_configured_hedge_cap_eth: max_short_eth&.to_s("F"),
      current_configured_hedge_cap_notional_usd: max_short_notional_usd&.to_s("F"),
      configured_emergency_close_max_eth: emergency_close_max_eth&.to_s("F"),
      hard_ceiling: AerodromeProductionRiskLimits.to_h,
      execution_venue: execution_venue,
      execution_venue_name: HedgeVenues.label(execution_venue),
      current_position_label: current_position_label,
      current_short_label: current_short_label,
      current_venue_position: serialize_position(eth_position),
      current_hyperliquid_eth_position: execution_venue == HedgeVenues::DEFAULT ? serialize_position(eth_position) : nil,
      current_aerodrome_lp_weth_amount: weth_amount&.to_s("F"),
      target_hedge_eth: target&.to_s("F"),
      target_hedge_notional_usd: target && eth_price ? (target * eth_price).to_s("F") : nil,
      current_short_eth: current_short.to_s("F"),
      current_venue_short_eth: current_short.to_s("F"),
      current_short_notional_usd: decimal_to_plain_string(current_notional_usd(eth_position, current_short)),
      current_venue_notional_usd: decimal_to_plain_string(current_notional_usd(eth_position, current_short)),
      drift_eth: drift&.to_s("F"),
      drift_notional_usd: drift_usd&.to_s("F"),
      margin_mode: eth_position&.dig(:margin_mode),
      isolated_margin_usd: decimal_to_plain_string(eth_position&.dig(:isolated_margin_usd)),
      entry_price: decimal_to_plain_string(eth_position&.dig(:entry_price)),
      mark_price: decimal_to_plain_string(eth_position&.dig(:mark_price)),
      venue_hedge_unrealized_pnl_usd: venue_hedge_unrealized_pnl(eth_position)&.to_s("F"),
      venue_hedge_pnl_available: venue_hedge_unrealized_pnl(eth_position).present?,
      venue_hedge_pnl_message: venue_hedge_pnl_message(eth_position),
      rebalance_needed_now: rebalance_needed?(target: target, drift: drift),
      within_caps: blockers.empty?,
      blockers: blockers,
      warnings: @errors,
      dashboard_actions: dashboard_actions(target: target, current_short: current_short, drift: drift),
      action_plan: action_plan
    }
  end

  private

  def cap_blockers(target:, current_short:)
    blockers = AerodromeProductionRiskLimits.runtime_cap_errors(
      max_short_eth: max_short_eth,
      max_short_notional_usd: max_short_notional_usd,
      emergency_close_max_eth: emergency_close_max_eth
    )
    blockers << "current #{HedgeVenues.label(execution_venue)} ETH position unavailable" if @errors.any?

    if target && max_short_eth && target > max_short_eth
      blockers << "target hedge exceeds AERODROME_MAX_SHORT_ETH"
    end
    if target && eth_price && max_short_notional_usd && target * eth_price > max_short_notional_usd
      blockers << "target hedge notional exceeds AERODROME_MAX_SHORT_NOTIONAL_USD"
    end
    if max_short_eth && current_short > max_short_eth
      blockers << "current ETH short exceeds AERODROME_MAX_SHORT_ETH"
    end
    if eth_price && max_short_notional_usd && current_short * eth_price > max_short_notional_usd
      blockers << "current ETH notional exceeds AERODROME_MAX_SHORT_NOTIONAL_USD"
    end

    blockers.uniq
  end

  def action_plan
    {
      refresh_sync: "Use the dashboard Refresh Read-only Data action to update Aerodrome LP amounts. It does not submit hedge orders.",
      approve_or_edit_hedge: @hedge ? "Edit the existing Hedge target/tolerance in the dashboard if the intended target changed." : "Create a Hedge for this position in the dashboard before any production live run.",
      open_or_rebalance: "Use dashboard preview first. Live open/rebalance requires explicit env gates and typed confirmation.",
      close_hedge: "Use dashboard close preview first. Live close uses the selected venue close gate.",
      stop_close_plan: "Run aerodrome:production_live_stop_plan or the VPS close template for the exact manual stop/close sequence."
    }
  end

  def dashboard_actions(target:, current_short:, drift:)
    tolerance = target && @hedge ? target * @hedge.tolerance : nil
    gate_blockers = AerodromeDashboardHedgeAction.execution_gate_blockers
    {
      open: {
        visible: current_short.zero? && target&.positive? && tolerance && target > tolerance,
        live_enabled: gate_blockers.empty?,
        blockers: gate_blockers,
        label: "Open Hedge"
      },
      rebalance: {
        visible: drift && tolerance && drift.abs > tolerance,
        live_enabled: gate_blockers.empty?,
        blockers: gate_blockers,
        label: "Rebalance Hedge"
      },
      close: {
        visible: current_short.positive?,
        live_enabled: gate_blockers.empty?,
        blockers: gate_blockers,
        label: "Close Hedge"
      }
    }
  end

  def current_eth_position
    if @hyperliquid_service.nil? && Rails.env.test?
      @errors << "current ETH readback unavailable: skipped in test without injected Hyperliquid service"
      return nil
    end

    hyperliquid.get_position("ETH")
  rescue => e
    @errors << "current ETH readback unavailable: #{e.class}: #{e.message}"
    nil
  end

  def current_venue_position
    return current_eth_position if execution_venue == HedgeVenues::DEFAULT

    venue_adapter.read_position(symbol: "ETH")
  rescue => e
    @errors << "current #{HedgeVenues.label(execution_venue)} ETH readback unavailable: #{e.class}: #{e.message}"
    nil
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def venue_adapter
    @hedge_venue_adapter ||= HedgeVenues.build(execution_venue)
  end

  def execution_venue
    HedgeVenues.normalize(@hedge&.execution_venue)
  end

  def target_short
    return nil unless @hedge && weth_amount

    weth_amount * @hedge.target
  end

  def weth_amount
    return @position.mellow_weth_exposure if @position.mellow_autopilot? && @position.mellow_weth_exposure

    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_amount
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_amount
    end
  end

  def eth_price
    if @position.mellow_autopilot? && @position.mellow_weth_exposure&.positive? && @position.mellow_current_value_usd
      usdc = @position.mellow_usdc_exposure || BigDecimal("0")
      return (@position.mellow_current_value_usd - usdc) / @position.mellow_weth_exposure
    end

    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
    end
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal((position[:short_size] || position.fetch(:size)).to_s)
    return size if size.positive?

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def current_notional_usd(position, current_short)
    return position[:notional_usd] if position&.dig(:notional_usd).present?
    return unless eth_price

    current_short * eth_price
  end

  def venue_hedge_unrealized_pnl(position)
    return nil unless execution_venue.in?(%w[nado ethereal]) && position&.dig(:side) == "short"
    return decimal_hash_value(position, :unrealized_pnl_usd) if execution_venue == "ethereal" && position[:unrealized_pnl_usd].present?

    entry_price = decimal_hash_value(position, :entry_price)
    mark_price = decimal_hash_value(position, :mark_price)
    size = short_size(position)
    return nil unless entry_price && mark_price && size.positive?

    (entry_price - mark_price) * size
  end

  def venue_hedge_pnl_message(position)
    return nil unless execution_venue.in?(%w[nado ethereal])

    venue = HedgeVenues.label(execution_venue)
    return "#{venue} hedge PnL unavailable: no ETH-PERP position readback." unless position
    return nil if execution_venue == "ethereal" && position[:unrealized_pnl_usd].present?
    return "#{venue} hedge PnL unavailable: readback missing entry price." if position[:entry_price].blank?
    return "#{venue} hedge PnL unavailable: readback missing mark price." if position[:mark_price].blank?

    nil
  end

  def decimal_hash_value(hash, key)
    raw = hash[key]
    return nil if raw.blank?

    BigDecimal(raw.to_s)
  rescue ArgumentError
    nil
  end

  def decimal_to_plain_string(value)
    return nil if value.blank?

    BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError
    nil
  end

  def rebalance_needed?(target:, drift:)
    tolerance = target && @hedge ? target * @hedge.tolerance : nil
    drift && tolerance ? drift.abs > tolerance : false
  end

  def current_position_label
    execution_venue == HedgeVenues::DEFAULT ? "Current Hyperliquid ETH position" : "Current #{HedgeVenues.label(execution_venue)} ETH-PERP position"
  end

  def current_short_label
    execution_venue == HedgeVenues::DEFAULT ? "Current ETH short" : "Current #{HedgeVenues.label(execution_venue)} ETH short"
  end

  def max_short_eth
    decimal_env("AERODROME_MAX_SHORT_ETH")
  end

  def max_short_notional_usd
    decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
  end

  def emergency_close_max_eth
    decimal_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
  end

  def decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def serialize_position(position)
    return nil unless position

    {
      venue: position[:venue],
      asset: position[:asset],
      symbol: position[:symbol],
      product_id: position[:product_id],
      side: position[:side],
      size: decimal_to_plain_string(position.fetch(:size)),
      short_size: decimal_to_plain_string(position[:short_size]),
      margin_mode: position[:margin_mode],
      entry_price: decimal_hash_value(position, :entry_price)&.to_s("F"),
      mark_price: decimal_hash_value(position, :mark_price)&.to_s("F"),
      notional_usd: decimal_hash_value(position, :notional_usd)&.to_s("F"),
      isolated_margin_usd: decimal_hash_value(position, :isolated_margin_usd)&.to_s("F"),
      account_value_usd: decimal_hash_value(position, :account_value_usd)&.to_s("F"),
      effective_leverage: decimal_hash_value(position, :effective_leverage)&.to_s("F"),
      status: position[:status]
    }.compact
  end
end
