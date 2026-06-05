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

  test "active venue auto policy enables only Extended for Extended production venue" do
    position = ethereal_position
    position.hedge.update!(execution_venue: "extended")
    position.position_dashboard_snapshot.update!(
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: "1.6",
      ethereal_short_eth: "0"
    )

    result = ActiveVenueAutoPolicy.new(position: position, updated_by: users(:one)).enable_current!

    assert_equal true, result.ok
    assert_equal true, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal 0, result.payload.fetch(:orders_submitted)
    assert_equal 0, result.payload.fetch(:signatures_created)
    assert_equal 0, result.payload.fetch(:cancels_submitted)
  end

  test "active venue auto policy enables only Nado for Nado production venue" do
    position = ethereal_position
    position.hedge.update!(execution_venue: "nado")
    position.position_dashboard_snapshot.update!(
      production_venue: "nado",
      selected_venue: "nado",
      nado_short_eth: "1.6",
      ethereal_short_eth: "0"
    )

    result = ActiveVenueAutoPolicy.new(position: position, updated_by: users(:one)).enable_current!

    assert_equal true, result.ok
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal 0, result.payload.fetch(:orders_submitted)
    assert_equal 0, result.payload.fetch(:signatures_created)
    assert_equal 0, result.payload.fetch(:cancels_submitted)
  end

  test "active venue auto policy enables only Ethereal for Ethereal production venue" do
    position = ethereal_position

    result = ActiveVenueAutoPolicy.new(position: position, updated_by: users(:one)).enable_current!

    assert_equal true, result.ok
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal 0, result.payload.fetch(:orders_submitted)
    assert_equal 0, result.payload.fetch(:signatures_created)
    assert_equal 0, result.payload.fetch(:cancels_submitted)
  end

  test "auto readiness blocks while migration lock is held for position" do
    position = ethereal_position
    adapter = TestAutoAdapter.new

    MigrationExecutionLock.with_lock(position) do
      report = adapter.readiness(position: position)

      assert_equal false, report.fetch(:active_auto_ready)
      assert_includes report.fetch(:blockers), "migration is in progress for this position; continuous auto is paused"
      assert_equal 0, report.fetch(:orders_submitted)
      assert_equal 0, report.fetch(:signatures_created)
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

  test "DB operational override false beats env true and env fallback works without DB row" do
    with_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "true") do
      assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")

      OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: false)

      assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
      value = OperationalSettings.get("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
      assert_equal "DB setting", value.source
      assert_equal false, value.enabled
    end
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

  class TestAutoAdapter < HedgeVenueAutoAdapters::Base
    def initialize
      super(
        env: {},
        fresh_target_factory: ->(_position) do
          Object.new.tap do |target|
            target.define_singleton_method(:resolve) do |refresh_if_stale:|
              {
                status: "ok",
                target_short_eth: "1.6",
                target_source: "test",
                exposure_source: "test",
                exposure_refreshed_at: Time.current,
                exposure_stale: false,
                blockers: []
              }
            end
          end
        end
      )
    end

    def readiness(position:)
      base_report(
        position: position,
        venue: "ethereal",
        current_position: { size: "-1.6" },
        other_positions: { "extended" => { size: "0" }, "nado" => { size: "0" } },
        account_state: { open_orders_count: 0 },
        live_enabled: true,
        auto_enabled: true
      )
    end
  end
end
