class AerodromeRebalanceVolatilityGuard
  BANNER = "AERODROME REBALANCE VOLATILITY GUARD — READ ONLY"

  def initialize(clock: -> { Time.current })
    @clock = clock
    @samples = []
    @cooldown_until = nil
    @last_rebalance_at = nil
  end

  def report(lp_price_usd:, mark_price_usd: nil, target_short:, current_short:, last_rebalance_at: nil)
    now = @clock.call
    lp_price = decimal_or_nil(lp_price_usd)
    mark_price = decimal_or_nil(mark_price_usd)
    target = decimal_or_zero(target_short)
    current = decimal_or_zero(current_short)
    delta_eth = (target - current).abs
    delta_usd = lp_price ? delta_eth * lp_price : nil

    return pass_report(now, "disabled", lp_price, mark_price, delta_eth, delta_usd) unless enabled?

    blockers = []
    warnings = []
    if lp_price.nil? || lp_price <= 0
      blockers << "LP ETH price unavailable"
      return blocked_report(now, "price unavailable", lp_price, mark_price, delta_eth, delta_usd, blockers, warnings)
    end

    @samples << { at: now, price: lp_price }
    prune_samples(now)

    per_interval_move = price_move_bps(@samples[-2]&.fetch(:price, nil), lp_price)
    window_move = price_move_bps(@samples.first&.fetch(:price, nil), lp_price)
    divergence = price_move_bps(mark_price, lp_price)

    if per_interval_move && per_interval_move > max_move_bps_per_interval
      blockers << "price move since previous sample exceeds #{max_move_bps_per_interval.to_s('F')} bps"
    end
    if window_move && window_move > max_move_bps_window
      blockers << "price move over volatility window exceeds #{max_move_bps_window.to_s('F')} bps"
    end
    if mark_price && divergence && divergence > max_price_divergence_bps
      blockers << "Hyperliquid mark and LP price divergence exceeds #{max_price_divergence_bps.to_s('F')} bps"
    elsif mark_price.nil?
      warnings << "Hyperliquid mark price unavailable; divergence check skipped"
    end

    recent = last_rebalance_at || @last_rebalance_at
    if recent && now - recent < min_seconds_between_rebalances
      blockers << "last rebalance is within #{min_seconds_between_rebalances} seconds"
    end
    if @cooldown_until && now < @cooldown_until
      blockers << "volatility cooldown active until #{@cooldown_until.iso8601}"
    end

    if blockers.any?
      @cooldown_until = now + cooldown_seconds if volatility_blocker?(blockers)
      blocked_report(now, blockers.first, lp_price, mark_price, delta_eth, delta_usd, blockers, warnings, per_interval_move, window_move, divergence)
    else
      pass_report(now, "allowed", lp_price, mark_price, delta_eth, delta_usd, warnings: warnings, price_move_bps: per_interval_move, window_move_bps: window_move, price_divergence_bps: divergence)
    end
  end

  def record_rebalance!(at: @clock.call)
    @last_rebalance_at = at
  end

  def enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED"]) == true
  end

  def pass_report(now, reason, lp_price, mark_price, delta_eth, delta_usd, warnings: [], price_move_bps: nil, window_move_bps: nil, price_divergence_bps: nil)
    base_report(now, "pass", true, reason, lp_price, mark_price, delta_eth, delta_usd, [], warnings, price_move_bps, window_move_bps, price_divergence_bps)
  end

  private

  def blocked_report(now, reason, lp_price, mark_price, delta_eth, delta_usd, blockers, warnings, price_move_bps = nil, window_move_bps = nil, price_divergence_bps = nil)
    base_report(now, "blocked", false, reason, lp_price, mark_price, delta_eth, delta_usd, blockers, warnings, price_move_bps, window_move_bps, price_divergence_bps)
  end

  def base_report(now, status, allowed, reason, lp_price, mark_price, delta_eth, delta_usd, blockers, warnings, price_move_bps, window_move_bps, price_divergence_bps)
    {
      safety_banner: BANNER,
      status: status,
      allowed: allowed,
      reason: reason,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      lp_price_usd: lp_price&.to_s("F"),
      mark_price_usd: mark_price&.to_s("F"),
      proposed_delta_eth: delta_eth.to_s("F"),
      proposed_delta_usd: delta_usd&.to_s("F"),
      price_move_bps: price_move_bps&.to_s("F"),
      window_move_bps: window_move_bps&.to_s("F"),
      price_divergence_bps: price_divergence_bps&.to_s("F"),
      cooldown_until: @cooldown_until&.iso8601,
      blockers: blockers,
      warnings: warnings,
      checked_at: now.iso8601
    }
  end

  def volatility_blocker?(blockers)
    blockers.any? { |blocker| blocker.include?("price move") || blocker.include?("divergence") }
  end

  def prune_samples(now)
    cutoff = now - window_seconds
    @samples = @samples.select { |sample| sample.fetch(:at) >= cutoff }
  end

  def price_move_bps(from, to)
    from = decimal_or_nil(from)
    to = decimal_or_nil(to)
    return nil unless from && to && from.positive?

    ((to - from).abs / from) * 10_000
  end

  def max_move_bps_per_interval
    decimal_env("AERODROME_REBALANCE_MAX_MOVE_BPS_PER_INTERVAL", "100")
  end

  def max_move_bps_window
    decimal_env("AERODROME_REBALANCE_MAX_MOVE_BPS_WINDOW", "250")
  end

  def max_price_divergence_bps
    decimal_env("AERODROME_REBALANCE_MAX_PRICE_DIVERGENCE_BPS", "100")
  end

  def window_seconds
    integer_env("AERODROME_REBALANCE_VOLATILITY_WINDOW_SECONDS", 900)
  end

  def cooldown_seconds
    integer_env("AERODROME_REBALANCE_VOLATILITY_COOLDOWN_SECONDS", 600)
  end

  def min_seconds_between_rebalances
    integer_env("AERODROME_REBALANCE_MIN_SECONDS_BETWEEN_REBALANCES", 600)
  end

  def decimal_env(key, default)
    BigDecimal((ENV[key].presence || default).to_s)
  rescue ArgumentError
    BigDecimal(default)
  end

  def integer_env(key, default)
    Integer(ENV[key].presence || default)
  rescue ArgumentError
    default
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def decimal_or_zero(value)
    decimal_or_nil(value) || BigDecimal("0")
  end
end
