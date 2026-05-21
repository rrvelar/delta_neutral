class AerodromeProductionDashboardStatus
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(position:, hyperliquid_service: nil)
    @position = position
    @hedge = position.hedge
    @hyperliquid_service = hyperliquid_service
    @errors = []
  end

  def report
    eth_position = current_eth_position
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
      current_hyperliquid_eth_position: serialize_position(eth_position),
      current_aerodrome_lp_weth_amount: weth_amount&.to_s("F"),
      target_hedge_eth: target&.to_s("F"),
      target_hedge_notional_usd: target && eth_price ? (target * eth_price).to_s("F") : nil,
      current_short_eth: current_short.to_s("F"),
      current_short_notional_usd: eth_price ? (current_short * eth_price).to_s("F") : nil,
      drift_eth: drift&.to_s("F"),
      drift_notional_usd: drift_usd&.to_s("F"),
      within_caps: blockers.empty?,
      blockers: blockers,
      warnings: @errors,
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
    blockers << "current Hyperliquid ETH position unavailable" if @errors.any?

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
      refresh_sync: "Use the dashboard Refresh Read-only Data action to update Aerodrome LP amounts. It does not call Hyperliquid.",
      approve_or_edit_hedge: @hedge ? "Edit the existing Hedge target/tolerance in the dashboard if the intended target changed." : "Create a Hedge for this position in the dashboard before any production live run.",
      open_or_rebalance: "Run production_live_run only through the explicitly gated production procedure. The dashboard status here is read-only and does not submit orders.",
      close_hedge: "Use the separately gated live emergency close procedure after checking current mainnet ETH. The dashboard status here does not close positions.",
      stop_close_plan: "Run aerodrome:production_live_stop_plan or the VPS close template for the exact manual stop/close sequence."
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

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def target_short
    return nil unless @hedge && weth_amount

    weth_amount * @hedge.target
  end

  def weth_amount
    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_amount
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_amount
    end
  end

  def eth_price
    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
    end
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
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

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end
end
