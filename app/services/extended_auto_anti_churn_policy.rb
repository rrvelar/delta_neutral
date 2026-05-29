class ExtendedAutoAntiChurnPolicy
  DEFAULT_MIN_REBALANCE_SIZE_ETH = "0.03"
  DEFAULT_MIN_REBALANCE_NOTIONAL_USD = "50"
  DEFAULT_COOLDOWN_SECONDS = 900
  DEFAULT_CONSECUTIVE_OUTSIDE_TOLERANCE = 2
  DEFAULT_STRONG_DRIFT_BYPASS_MULTIPLIER = "2.0"

  def initialize(env: ENV, now: -> { Time.current }, cache: Rails.cache)
    @env = env
    @now = now
    @cache = cache
  end

  def evaluate(position:, hedge:, action:, drift:, tolerance:, order_size:, mark_price:, readonly: true)
    base = {
      planned_auto_action: action,
      action_suppressed_reason: nil,
      min_rebalance_size_eth: min_rebalance_size_eth.to_s("F"),
      min_rebalance_notional_usd: min_rebalance_notional_usd.to_s("F"),
      rebalance_cooldown_seconds: cooldown_seconds,
      cooldown_remaining_seconds: 0,
      consecutive_outside_tolerance_required: consecutive_required,
      consecutive_outside_tolerance_count: 0,
      strong_drift_bypass_multiplier: strong_drift_bypass_multiplier.to_s("F"),
      strong_drift_threshold: nil,
      drift_to_tolerance_ratio: nil,
      strong_drift_bypass_used: false
    }
    return base if action == "no_op"
    return base.merge(action_suppressed_reason: "target short could not be computed") unless drift && tolerance && order_size

    threshold = tolerance.positive? ? tolerance * strong_drift_bypass_multiplier : nil
    ratio = tolerance.positive? ? drift.abs / tolerance : nil
    strong = threshold && drift.abs >= threshold
    count = outside_tolerance_count(position: position, action: action, readonly: readonly)
    remaining = cooldown_remaining_seconds(hedge)
    notional = mark_price ? order_size * mark_price : nil
    reason = suppression_reason(order_size: order_size, notional: notional, count: count, strong: strong, cooldown_remaining: remaining)

    base.merge(
      action_suppressed_reason: reason,
      cooldown_remaining_seconds: remaining,
      consecutive_outside_tolerance_count: count,
      strong_drift_threshold: threshold&.to_s("F"),
      drift_to_tolerance_ratio: ratio&.to_s("F"),
      strong_drift_bypass_used: strong == true
    )
  end

  private

  def suppression_reason(order_size:, notional:, count:, strong:, cooldown_remaining:)
    return "order size #{order_size.to_s('F')} ETH is below EXTENDED_AUTO_MIN_REBALANCE_SIZE_ETH #{min_rebalance_size_eth.to_s('F')}" if order_size < min_rebalance_size_eth
    if notional.nil?
      return "mark price unavailable for EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD check"
    end
    return "order notional #{notional.round(2).to_s('F')} USD is below EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD #{min_rebalance_notional_usd.to_s('F')}" if notional < min_rebalance_notional_usd
    return "last successful Extended rebalance is still in cooldown for #{cooldown_remaining}s" if !strong && cooldown_remaining.positive?
    return "outside tolerance confirmation #{count}/#{consecutive_required}; waiting for repeated reading" if !strong && count < consecutive_required

    nil
  end

  def outside_tolerance_count(position:, action:, readonly:)
    return 0 unless position&.id

    key = cache_key(position)
    previous = @cache.read(key).presence || {}
    count = previous[:action].to_s == action.to_s ? previous[:count].to_i + 1 : 1
    @cache.write(key, { action: action, count: count, at: @now.call.utc.iso8601 }, expires_in: 24.hours) unless readonly
    count
  rescue => e
    Rails.logger.warn("ExtendedAutoAntiChurnPolicy: cache unavailable for position #{position&.id}: #{e.class}: #{e.message}")
    1
  end

  def cache_key(position)
    "extended_auto:anti_churn:position:#{position.id}"
  end

  def cooldown_remaining_seconds(hedge)
    return 0 unless hedge&.respond_to?(:short_rebalances)

    recent = hedge.short_rebalances
      .where(venue: "extended", asset: [ nil, "ETH", "WETH" ], status: ShortRebalance::STATUS_SUCCESS)
      .order(rebalanced_at: :desc, created_at: :desc)
      .first
    timestamp = recent&.rebalanced_at || recent&.created_at
    return 0 unless timestamp

    elapsed = @now.call - timestamp
    remaining = cooldown_seconds - elapsed
    remaining.positive? ? remaining.ceil : 0
  end

  def min_rebalance_size_eth
    decimal_env("EXTENDED_AUTO_MIN_REBALANCE_SIZE_ETH", DEFAULT_MIN_REBALANCE_SIZE_ETH)
  end

  def min_rebalance_notional_usd
    decimal_env("EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD", DEFAULT_MIN_REBALANCE_NOTIONAL_USD)
  end

  def strong_drift_bypass_multiplier
    decimal_env("EXTENDED_AUTO_STRONG_DRIFT_BYPASS_MULTIPLIER", DEFAULT_STRONG_DRIFT_BYPASS_MULTIPLIER)
  end

  def cooldown_seconds
    integer_env("EXTENDED_AUTO_REBALANCE_COOLDOWN_SECONDS", DEFAULT_COOLDOWN_SECONDS)
  end

  def consecutive_required
    integer_env("EXTENDED_AUTO_REQUIRE_CONSECUTIVE_OUTSIDE_TOLERANCE", DEFAULT_CONSECUTIVE_OUTSIDE_TOLERANCE)
  end

  def decimal_env(key, fallback)
    BigDecimal((@env[key].presence || fallback).to_s)
  rescue ArgumentError
    BigDecimal(fallback.to_s)
  end

  def integer_env(key, fallback)
    Integer(@env.fetch(key, fallback.to_s))
  rescue ArgumentError
    fallback
  end
end
