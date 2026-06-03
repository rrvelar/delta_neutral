require "test_helper"
require "rake"

class AutoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("auto:list")
    %w[auto:list auto:set auto:disable_all].each { |task| Rake::Task[task].reenable }
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
  end

  test "auto list reports current state and no live counters" do
    position = ethereal_position

    with_env("position_id" => position.id.to_s) do
      out, = capture_io { Rake::Task["auto:list"].invoke }
      payload = JSON.parse(out)

      assert_equal "auto_list", payload.fetch("action")
      assert_equal position.id, payload.fetch("position_id")
      assert_equal "ethereal", payload.fetch("selected_venue")
      assert_equal false, payload.fetch("selected_auto_enabled")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "auto set enables ethereal and disables other auto loops" do
    position = ethereal_position

    with_env(
      "position_id" => position.id.to_s,
      "venue" => "ethereal",
      "enabled" => "true",
      "confirmation" => OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal"),
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
    ) do
      out, = capture_io { Rake::Task["auto:set"].invoke }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
      assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
      assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "auto set rejects unsupported venue wrong confirmation and inactive position" do
    position = ethereal_position

    with_env("position_id" => position.id.to_s, "venue" => "hyperliquid", "enabled" => "true", "confirmation" => "anything") do
      out, = capture_io { Rake::Task["auto:set"].invoke }
      assert_equal false, JSON.parse(out).fetch("ok")
    end

    Rake::Task["auto:set"].reenable
    with_env("position_id" => position.id.to_s, "venue" => "ethereal", "enabled" => "true", "confirmation" => "wrong") do
      out, = capture_io { Rake::Task["auto:set"].invoke }
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_includes payload.fetch("errors"), "confirmation must equal #{OperationalSettings::ENABLE_CONFIRMATIONS.fetch('ethereal')}"
    end

    inactive = ethereal_position(active: false)
    Rake::Task["auto:set"].reenable
    with_env(
      "position_id" => inactive.id.to_s,
      "venue" => "ethereal",
      "enabled" => "true",
      "confirmation" => OperationalSettings::ENABLE_CONFIRMATIONS.fetch("ethereal"),
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
    ) do
      out, = capture_io { Rake::Task["auto:set"].invoke }
      payload = JSON.parse(out)
      assert_equal false, payload.fetch("ok")
      assert_includes payload.fetch("errors"), "position must be active production position"
    end
  end

  test "auto disable all clears auto and migration loops" do
    position = ethereal_position
    OperationalSettings::ALLOWED_KEYS.each { |key| OperationalSettings.set!(key: key, enabled: true) }

    with_env(
      "position_id" => position.id.to_s,
      "confirmation" => OperationalSettings::DISABLE_ALL_CONFIRMATION
    ) do
      out, = capture_io { Rake::Task["auto:disable_all"].invoke }
      payload = JSON.parse(out)

      assert_equal true, payload.fetch("ok")
      assert OperationalSettings::ALLOWED_KEYS.none? { |key| OperationalSettings.enabled?(key) }
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
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
