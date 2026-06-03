require "test_helper"

class RiskSettingsTest < ActiveSupport::TestCase
  setup do
    RiskSetting.delete_all
    RiskSettingAudit.delete_all
  end

  test "venue specific cap overrides generic cap" do
    RiskSettings.set!(
      key: "ETHEREAL_MAX_SHORT_ETH",
      value: "2.0",
      updated_by: users(:one),
      reason: "test",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    )

    with_env("AERODROME_MAX_SHORT_ETH" => "1.0") do
      cap = RiskSettings.cap_for(venue: "ethereal", kind: :short_eth)

      assert_equal "ETHEREAL_MAX_SHORT_ETH", cap.key
      assert_equal BigDecimal("2.0"), cap.value
      assert_equal "DB setting", cap.source
    end
  end

  test "generic cap fallback works" do
    with_env("AERODROME_MAX_SHORT_ETH" => "1.5") do
      cap = RiskSettings.cap_for(venue: "ethereal", kind: :short_eth)

      assert_equal "AERODROME_MAX_SHORT_ETH", cap.key
      assert_equal BigDecimal("1.5"), cap.value
      assert_equal "env", cap.source
    end
  end

  test "missing cap reports not configured" do
    with_env("ETHEREAL_MAX_SHORT_ETH" => nil, "AERODROME_MAX_SHORT_ETH" => nil) do
      cap = RiskSettings.cap_for(venue: "ethereal", kind: :short_eth)

      assert_equal "ETHEREAL_MAX_SHORT_ETH", cap.key
      assert_nil cap.value
      assert_equal "not configured", cap.source
    end
  end

  test "rejects invalid key and numeric value" do
    invalid_key = RiskSettings.set!(key: "HYPERLIQUID_MAX_SHORT_ETH", value: "1", confirmation: RiskSettings::INCREASE_CONFIRMATION)
    invalid_value = RiskSettings.set!(key: "ETHEREAL_MAX_SHORT_ETH", value: "-1", confirmation: RiskSettings::INCREASE_CONFIRMATION)

    assert_equal false, invalid_key.ok
    assert_includes invalid_key.errors, "invalid risk setting key"
    assert_equal false, invalid_value.ok
    assert_includes invalid_value.errors, "invalid risk setting value"
  end

  test "cap setting requires confirmation and creates audit" do
    failed = RiskSettings.set!(key: "ETHEREAL_MAX_SHORT_ETH", value: "2.0", updated_by: users(:one))
    ok = RiskSettings.set!(
      key: "ETHEREAL_MAX_SHORT_ETH",
      value: "2.0",
      updated_by: users(:one),
      reason: "raise for imported LP",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    )

    assert_equal false, failed.ok
    assert_includes failed.errors, "confirmation must equal #{RiskSettings::INCREASE_CONFIRMATION}"
    assert_equal true, ok.ok
    assert_equal "ETHEREAL_MAX_SHORT_ETH", ok.audit.key
    assert_equal "2.0", ok.audit.new_value
  end

  test "runtime cap above hard ceiling is rejected" do
    with_env("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5") do
      result = RiskSettings.set!(
        key: "AERODROME_MAX_SHORT_ETH",
        value: "3.5",
        confirmation: RiskSettings::INCREASE_CONFIRMATION
      )

      assert_equal false, result.ok
      assert_includes result.errors.first, "Cannot set Global max short size to 3.5 ETH because production hard max short size is 1.5 ETH"
      assert_nil RiskSetting.find_by(key: "AERODROME_MAX_SHORT_ETH")
    end
  end

  test "venue specific cap above hard ceiling is rejected" do
    with_env("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5") do
      result = RiskSettings.set!(
        key: "ETHEREAL_MAX_SHORT_ETH",
        value: "2.0",
        confirmation: RiskSettings::INCREASE_CONFIRMATION
      )

      assert_equal false, result.ok
      assert_includes result.errors.first, "Cannot set Ethereal max short size to 2.0 ETH because production hard max short size is 1.5 ETH"
    end
  end

  test "runtime cap below hard ceiling is accepted" do
    with_env("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "2.0") do
      result = RiskSettings.set!(
        key: "ETHEREAL_MAX_SHORT_ETH",
        value: "1.9",
        confirmation: RiskSettings::INCREASE_CONFIRMATION
      )

      assert_equal true, result.ok
      assert_equal "1.9", RiskSetting.find_by!(key: "ETHEREAL_MAX_SHORT_ETH").value
    end
  end

  test "hard ceiling increase and decrease require exact confirmations" do
    weak = RiskSettings.set!(
      key: "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH",
      value: "2.2",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    )
    strong = RiskSettings.set!(
      key: "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH",
      value: "2.2",
      confirmation: RiskSettings::HARD_INCREASE_CONFIRMATION
    )
    decrease = RiskSettings.set!(
      key: "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH",
      value: "1.8",
      confirmation: RiskSettings::DECREASE_CONFIRMATION
    )

    assert_equal false, weak.ok
    assert_includes weak.errors, "confirmation must equal #{RiskSettings::HARD_INCREASE_CONFIRMATION}"
    assert_equal true, strong.ok
    assert_equal true, decrease.ok
  end

  test "emergency close below max short is rejected" do
    RiskSetting.create!(key: "AERODROME_MAX_SHORT_ETH", value: "2.1")

    result = RiskSettings.set!(
      key: "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH",
      value: "1.6",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    )

    assert_equal false, result.ok
    assert_includes result.errors, "Cannot set Emergency close max ETH below AERODROME_MAX_SHORT_ETH. Emergency close limit must be at least the maximum hedge size."
  end

  test "emergency close above hard emergency ceiling is rejected" do
    RiskSetting.create!(key: "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH", value: "2.3")

    result = RiskSettings.set!(
      key: "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH",
      value: "2.4",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    )

    assert_equal false, result.ok
    assert_includes result.errors.first, "Cannot set Emergency close max ETH to 2.4 ETH because production hard emergency close max is 2.3 ETH"
  end

  private

  def with_env(overrides)
    old = overrides.to_h { |key, _value| [ key, ENV.fetch(key, nil) ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
