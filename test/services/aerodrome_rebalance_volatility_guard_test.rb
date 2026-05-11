require "test_helper"

class AerodromeRebalanceVolatilityGuardTest < ActiveSupport::TestCase
  setup do
    @base_env = {
      "AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED" => "true",
      "AERODROME_REBALANCE_MAX_MOVE_BPS_PER_INTERVAL" => "100",
      "AERODROME_REBALANCE_MAX_MOVE_BPS_WINDOW" => "250",
      "AERODROME_REBALANCE_VOLATILITY_WINDOW_SECONDS" => "900",
      "AERODROME_REBALANCE_VOLATILITY_COOLDOWN_SECONDS" => "600",
      "AERODROME_REBALANCE_MAX_PRICE_DIVERGENCE_BPS" => "100",
      "AERODROME_REBALANCE_MIN_SECONDS_BETWEEN_REBALANCES" => "600"
    }
  end

  test "disabled returns allowed pass" do
    with_env(@base_env.merge("AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED" => "false")) do
      report = build_guard.report(lp_price_usd: "2300", target_short: "0.011", current_short: "0")

      assert_equal "pass", report.fetch(:status)
      assert_equal true, report.fetch(:allowed)
      assert_equal "disabled", report.fetch(:reason)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "price move over per interval threshold blocks" do
    with_env(@base_env) do
      guard = build_guard
      guard.report(lp_price_usd: "2300", mark_price_usd: "2300", target_short: "0.011", current_short: "0")
      report = guard.report(lp_price_usd: "2330", mark_price_usd: "2330", target_short: "0.011", current_short: "0")

      assert_equal "blocked", report.fetch(:status)
      assert_equal false, report.fetch(:allowed)
      assert report.fetch(:blockers).any? { |blocker| blocker.include?("price move since previous sample") }
    end
  end

  test "window move over threshold blocks" do
    with_env(@base_env.merge("AERODROME_REBALANCE_MAX_MOVE_BPS_PER_INTERVAL" => "1000")) do
      guard = build_guard
      guard.report(lp_price_usd: "2300", mark_price_usd: "2300", target_short: "0.011", current_short: "0")
      report = guard.report(lp_price_usd: "2370", mark_price_usd: "2370", target_short: "0.011", current_short: "0")

      assert_equal "blocked", report.fetch(:status)
      assert report.fetch(:blockers).any? { |blocker| blocker.include?("price move over volatility window") }
    end
  end

  test "price divergence over threshold blocks" do
    with_env(@base_env) do
      report = build_guard.report(lp_price_usd: "2300", mark_price_usd: "2260", target_short: "0.011", current_short: "0")

      assert_equal "blocked", report.fetch(:status)
      assert report.fetch(:blockers).any? { |blocker| blocker.include?("divergence") }
    end
  end

  test "cooldown blocks after volatility breach" do
    with_env(@base_env) do
      guard = build_guard
      guard.report(lp_price_usd: "2300", mark_price_usd: "2300", target_short: "0.011", current_short: "0")
      guard.report(lp_price_usd: "2330", mark_price_usd: "2330", target_short: "0.011", current_short: "0")
      report = guard.report(lp_price_usd: "2330", mark_price_usd: "2330", target_short: "0.011", current_short: "0")

      assert_equal "blocked", report.fetch(:status)
      assert report.fetch(:blockers).any? { |blocker| blocker.include?("cooldown active") }
    end
  end

  test "min seconds between rebalances blocks" do
    now = Time.zone.local(2026, 5, 10, 12, 0, 0)
    with_env(@base_env) do
      report = build_guard(now: now).report(
        lp_price_usd: "2300",
        mark_price_usd: "2300",
        target_short: "0.011",
        current_short: "0",
        last_rebalance_at: now - 30.seconds
      )

      assert_equal "blocked", report.fetch(:status)
      assert report.fetch(:blockers).any? { |blocker| blocker.include?("last rebalance") }
    end
  end

  private

  def build_guard(now: Time.zone.local(2026, 5, 10, 12, 0, 0))
    AerodromeRebalanceVolatilityGuard.new(clock: -> { now })
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
