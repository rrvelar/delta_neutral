require "test_helper"
require "rake"

class RiskTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("risk:list")
    %w[risk:list risk:set hedge:cap_diagnostics].each { |task| Rake::Task[task].reenable }
  end

  test "risk list prints whitelisted caps with no live counters" do
    out, = capture_io { Rake::Task["risk:list"].invoke }
    payload = JSON.parse(out)

    assert_equal "risk_list", payload.fetch("action")
    assert payload.fetch("settings").any? { |row| row.fetch("key") == "ETHEREAL_MAX_SHORT_ETH" }
    assert_equal false, payload.fetch("restart_required")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  end

  test "risk set updates cap with confirmation and no live counters" do
    with_env(
      "key" => "ETHEREAL_MAX_SHORT_ETH",
      "value" => "2.0",
      "confirmation" => RiskSettings::INCREASE_CONFIRMATION
    ) do
      out, = capture_io { Rake::Task["risk:set"].invoke }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert_equal "ETHEREAL_MAX_SHORT_ETH", payload.fetch("key")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "hedge cap diagnostics prints exact cap data without live counters" do
    position = aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")

    with_env(
      "position_id" => position.id.to_s,
      "venue" => "ethereal",
      "ETHEREAL_MAX_SHORT_ETH" => "1.0",
      "ETHEREAL_MAX_ORDER_SIZE_ETH" => "1.0",
      "ETHEREAL_MAX_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.0",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "2.0",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "2.0"
    ) do
      out, = capture_io { Rake::Task["hedge:cap_diagnostics"].invoke }
      payload = JSON.parse(out)

      assert_equal "hedge_cap_diagnostics", payload.fetch("action")
      assert_equal "ETHEREAL_MAX_SHORT_ETH", payload.dig("cap_diagnostics", "short_cap", "cap_key")
      assert_equal "1.25", payload.dig("cap_diagnostics", "short_cap", "target_short_eth")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  private

  def aerodrome_position
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: SecureRandom.hex(4),
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
  end

  def with_env(overrides)
    old = overrides.to_h { |key, _value| [ key, ENV.fetch(key, nil) ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
