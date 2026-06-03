require "test_helper"
require "rake"

class RiskTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("risk:list")
    RiskSetting.delete_all
    RiskSettingAudit.delete_all
    %w[risk:list risk:set risk:recommend risk:apply_recommended hedge:cap_diagnostics].each { |task| Rake::Task[task].reenable }
  end

  test "risk list prints whitelisted caps with no live counters" do
    out, = capture_io { Rake::Task["risk:list"].invoke }
    payload = JSON.parse(out)

    assert_equal "risk_list", payload.fetch("action")
    assert payload.fetch("settings").any? { |row| row.fetch("key") == "ETHEREAL_MAX_SHORT_ETH" }
    assert payload.fetch("runtime_caps").any? { |row| row.fetch("key") == "ETHEREAL_MAX_SHORT_ETH" }
    assert payload.fetch("hard_ceilings").any? { |row| row.fetch("key") == "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" }
    assert_equal false, payload.fetch("restart_required")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  end

  test "risk list flags invalid legacy cap above hard ceiling" do
    RiskSetting.create!(key: "AERODROME_MAX_SHORT_ETH", value: "3.5")

    with_env("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5") do
      out, = capture_io { Rake::Task["risk:list"].invoke }
      row = JSON.parse(out).fetch("runtime_caps").find { |entry| entry.fetch("key") == "AERODROME_MAX_SHORT_ETH" }

      assert_equal false, row.fetch("valid")
      assert row.fetch("validation_errors").first.include?("Cannot set Global max short size")
    end
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
      assert_equal "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH", payload.dig("cap_diagnostics", "emergency_close", "emergency_close_key")
      assert_equal "AERODROME_MAX_SHORT_ETH", payload.dig("cap_diagnostics", "emergency_close", "compared_against_key")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "risk recommend prints requirements without live counters" do
    position = aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")

    with_env("position_id" => position.id.to_s, "venue" => "ethereal") do
      out, = capture_io { Rake::Task["risk:recommend"].invoke }
      payload = JSON.parse(out)

      assert_equal "risk_recommend", payload.fetch("action")
      keys = payload.fetch("required_changes").map { |change| change.fetch("key") }
      assert_includes keys, "ETHEREAL_MAX_SHORT_ETH"
      assert_includes keys, "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "risk apply recommended refuses weak confirmation and succeeds with hard confirmation" do
    position = aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")

    with_env(
      "position_id" => position.id.to_s,
      "venue" => "ethereal",
      "confirmation" => RiskSettings::INCREASE_CONFIRMATION
    ) do
      out, = capture_io { Rake::Task["risk:apply_recommended"].invoke }
      payload = JSON.parse(out)

      assert_equal false, payload.fetch("ok")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end

    Rake::Task["risk:apply_recommended"].reenable
    with_env(
      "position_id" => position.id.to_s,
      "venue" => "ethereal",
      "confirmation" => RiskSettings::HARD_INCREASE_CONFIRMATION
    ) do
      out, = capture_io { Rake::Task["risk:apply_recommended"].invoke }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert RiskSetting.find_by(key: "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "risk apply recommended normalizes emergency close dependency in one command" do
    position = aerodrome_position
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.66",
      combined_short_eth: "0",
      drift_eth: "1.66",
      inside_tolerance: false
    )
    incident_settings.each { |key, value| RiskSetting.create!(key: key, value: value) }

    with_env(
      "position_id" => position.id.to_s,
      "venue" => "ethereal",
      "confirmation" => RiskSettings::INCREASE_CONFIRMATION,
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "1.6"
    ) do
      out, = capture_io { Rake::Task["risk:apply_recommended"].invoke }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      applied_keys = payload.fetch("applied").map { |row| row.fetch("key") }
      assert_includes applied_keys, "AERODROME_MAX_SHORT_ETH"
      assert_includes applied_keys, "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      assert_equal "2.1", RiskSetting.find_by!(key: "AERODROME_MAX_SHORT_ETH").value
      assert_equal "2.1", RiskSetting.find_by!(key: "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH").value
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  private

  def incident_settings
    {
      "ETHEREAL_MAX_SHORT_ETH" => "2.3",
      "ETHEREAL_MAX_ORDER_SIZE_ETH" => "2.3",
      "ETHEREAL_MAX_NOTIONAL_USD" => "4200",
      "AERODROME_MAX_SHORT_ETH" => "3.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4200",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "2.3",
      "AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD" => "4200",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "4200"
    }
  end

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
