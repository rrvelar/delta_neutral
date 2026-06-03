require "test_helper"

class RiskSettingsTest < ActiveSupport::TestCase
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

  private

  def with_env(overrides)
    old = overrides.to_h { |key, _value| [ key, ENV.fetch(key, nil) ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
