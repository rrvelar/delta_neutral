require "test_helper"

class ExtendedAutoAntiChurnPolicyTest < ActiveSupport::TestCase
  setup do
    @cache = ActiveSupport::Cache::MemoryStore.new
  end

  test "no-ops inside tolerance" do
    result = policy.evaluate(position: position, hedge: position.hedge, action: "no_op", drift: "0".to_d, tolerance: "0.01".to_d, order_size: nil, mark_price: "2000".to_d)

    assert_nil result.fetch(:action_suppressed_reason)
    assert_equal "no_op", result.fetch(:planned_auto_action)
  end

  test "suppresses tiny outside tolerance drift below min eth" do
    result = policy.evaluate(position: position, hedge: position.hedge, action: "increase_short", drift: "0.02".to_d, tolerance: "0.01".to_d, order_size: "0.02".to_d, mark_price: "3000".to_d)

    assert_match "below EXTENDED_AUTO_MIN_REBALANCE_SIZE_ETH", result.fetch(:action_suppressed_reason)
    assert_equal "0.03", result.fetch(:min_rebalance_size_eth)
  end

  test "suppresses outside tolerance drift below min notional" do
    result = policy(env: { "EXTENDED_AUTO_MIN_REBALANCE_SIZE_ETH" => "0.001", "EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD" => "50" }).evaluate(
      position: position,
      hedge: position.hedge,
      action: "increase_short",
      drift: "0.02".to_d,
      tolerance: "0.01".to_d,
      order_size: "0.02".to_d,
      mark_price: "2000".to_d
    )

    assert_match "below EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD", result.fetch(:action_suppressed_reason)
  end

  test "suppresses during cooldown" do
    position.hedge.short_rebalances.create!(venue: "extended", asset: "ETH", old_short_size: "0.8", new_short_size: "0.85", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: 1.minute.ago)

    result = policy(env: permissive_env).evaluate(position: position, hedge: position.hedge, action: "increase_short", drift: "0.05".to_d, tolerance: "0.01".to_d, order_size: "0.05".to_d, mark_price: "2000".to_d)

    assert_match "cooldown", result.fetch(:action_suppressed_reason)
    assert_operator result.fetch(:cooldown_remaining_seconds), :>, 0
  end

  test "requires consecutive outside tolerance readings unless strong drift" do
    first = policy(env: permissive_env.merge("EXTENDED_AUTO_REQUIRE_CONSECUTIVE_OUTSIDE_TOLERANCE" => "2")).evaluate(
      position: position,
      hedge: position.hedge,
      action: "increase_short",
      drift: "0.04".to_d,
      tolerance: "0.03".to_d,
      order_size: "0.04".to_d,
      mark_price: "2000".to_d,
      readonly: false
    )
    second = policy(env: permissive_env.merge("EXTENDED_AUTO_REQUIRE_CONSECUTIVE_OUTSIDE_TOLERANCE" => "2")).evaluate(
      position: position,
      hedge: position.hedge,
      action: "increase_short",
      drift: "0.04".to_d,
      tolerance: "0.03".to_d,
      order_size: "0.04".to_d,
      mark_price: "2000".to_d,
      readonly: false
    )

    assert_match "waiting for repeated reading", first.fetch(:action_suppressed_reason)
    assert_nil second.fetch(:action_suppressed_reason)
    assert_equal 2, second.fetch(:consecutive_outside_tolerance_count)
  end

  test "strong drift bypass allows action without consecutive confirmation" do
    result = policy(env: permissive_env.merge("EXTENDED_AUTO_REQUIRE_CONSECUTIVE_OUTSIDE_TOLERANCE" => "2", "EXTENDED_AUTO_STRONG_DRIFT_BYPASS_MULTIPLIER" => "2.0")).evaluate(
      position: position,
      hedge: position.hedge,
      action: "increase_short",
      drift: "0.07".to_d,
      tolerance: "0.03".to_d,
      order_size: "0.07".to_d,
      mark_price: "2000".to_d,
      readonly: false
    )

    assert_nil result.fetch(:action_suppressed_reason)
    assert_equal true, result.fetch(:strong_drift_bypass_used)
  end

  private

  def policy(env: {})
    @cache ||= ActiveSupport::Cache::MemoryStore.new
    ExtendedAutoAntiChurnPolicy.new(env: env, cache: @cache)
  end

  def permissive_env
    {
      "EXTENDED_AUTO_MIN_REBALANCE_SIZE_ETH" => "0.001",
      "EXTENDED_AUTO_MIN_REBALANCE_NOTIONAL_USD" => "1",
      "EXTENDED_AUTO_REBALANCE_COOLDOWN_SECONDS" => "900"
    }
  end

  def position
    @position ||= Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:#{SecureRandom.hex(4)}",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "100",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      active: true,
      mellow_metadata: { "hedge_ready" => true, "last_probe_confidence" => "current_share_token_resolver_high" }.to_json
    ).tap do |record|
      record.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end
end
