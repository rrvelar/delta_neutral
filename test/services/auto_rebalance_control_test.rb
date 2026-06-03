require "test_helper"

class AutoRebalanceControlTest < ActiveSupport::TestCase
  setup do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
  end

  test "enable ethereal auto sets active venue true and disables other autos and migration" do
    position = ethereal_position

    with_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true") do
      result = AutoRebalanceControl.new(position: position, venue: "ethereal", updated_by: users(:one)).set!(
        enabled: true,
        confirmation: OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal")
      )

      assert_equal true, result.ok
      assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
      assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
      assert_operator OperationalSettingAudit.count, :>=, 5
      assert_equal 0, result.payload.fetch(:orders_submitted)
      assert_equal 0, result.payload.fetch(:signatures_created)
      assert_equal 0, result.payload.fetch(:cancels_submitted)
    end
  end

  test "disable ethereal auto requires exact disable confirmation" do
    position = ethereal_position
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true)

    wrong = AutoRebalanceControl.new(position: position, venue: "ethereal").set!(enabled: false, confirmation: "wrong")
    assert_equal false, wrong.ok
    assert_includes wrong.errors, "confirmation must equal #{OperationalSettings::DISABLE_CONFIRMATIONS.fetch('ethereal')}"

    right = AutoRebalanceControl.new(position: position, venue: "ethereal").set!(
      enabled: false,
      confirmation: OperationalSettings::DISABLE_CONFIRMATIONS.fetch("ethereal")
    )
    assert_equal true, right.ok
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal 0, right.payload.fetch(:orders_submitted)
    assert_equal 0, right.payload.fetch(:signatures_created)
  end

  test "rejects unsupported venue and inactive position" do
    unsupported = AutoRebalanceControl.new(position: ethereal_position, venue: "hyperliquid").set!(
      enabled: true,
      confirmation: "anything"
    )
    assert_equal false, unsupported.ok
    assert_includes unsupported.errors, "selected venue must be ethereal, nado, or extended"

    inactive = ethereal_position(active: false)
    result = AutoRebalanceControl.new(position: inactive, venue: "ethereal").set!(
      enabled: true,
      confirmation: OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal")
    )
    assert_equal false, result.ok
    assert_includes result.errors, "position must be active production position"
  end

  private

  def ethereal_position(active: true)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.6",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: active
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: active, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      tolerance_abs_eth: "0.048",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0",
      signer_status: "ok"
    )
    position
  end

  def with_env(values)
    old = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
