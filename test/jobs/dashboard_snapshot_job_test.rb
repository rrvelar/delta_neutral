require "test_helper"

class DashboardSnapshotJobTest < ActiveSupport::TestCase
  test "recurring schedule includes dashboard snapshot refresh" do
    config = YAML.safe_load_file(Rails.root.join("config", "recurring.yml"), aliases: true)
    default = config.fetch("default")
    entry = default.fetch("dashboard_snapshot_refresh")

    assert_equal "DashboardSnapshotJob", entry.fetch("class")
    assert_equal "every minute", entry.fetch("schedule")
  end

  test "recurring schedule includes daily random rotation dry run job" do
    config = YAML.safe_load_file(Rails.root.join("config", "recurring.yml"), aliases: true)
    default = config.fetch("default")
    entry = default.fetch("migration_random_rotation_daily")

    assert_equal "MigrationRandomRotationDailyJob", entry.fetch("class")
    assert_equal "every day at 03:30", entry.fetch("schedule")
  end

  test "refreshes all snapshot types for active Aerodrome positions" do
    position = aerodrome_position(active: true)
    inactive = aerodrome_position(active: false)
    calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:, **) { refresher(calls, [ :position, position.id ], SnapshotResult.new("ok")) }) do
      RewardsFeesSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, [ :rewards, position.id ], SnapshotResult.new("ok")) }) do
        HedgeAccountingSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, [ :accounting, position.id ], SnapshotResult.new("ok")) }) do
          DashboardSnapshotJob.perform_now
        end
      end
    end

    assert_includes calls, [ :position, position.id ]
    assert_includes calls, [ :rewards, position.id ]
    assert_includes calls, [ :accounting, position.id ]
    refute_includes calls, [ :position, inactive.id ]
  end

  test "explicit position refreshes all three snapshot types" do
    position = aerodrome_position(active: true)
    calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:, **) { refresher(calls, :position, SnapshotResult.new("ok")) }) do
      RewardsFeesSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :rewards, SnapshotResult.new("ok")) }) do
        HedgeAccountingSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :accounting, SnapshotResult.new("ok")) }) do
          DashboardSnapshotJob.perform_now(position.id)
        end
      end
    end

    assert_equal %i[position rewards accounting], calls
  end

  test "skips refresh when per-position lock is already held" do
    position = aerodrome_position(active: true)
    calls = []

    JobConcurrencyGuard.with_lock("dashboard_snapshot:position:#{position.id}") do
      DashboardSnapshotRefresh.stub(:new, ->(position:, **) { refresher(calls, :position, SnapshotResult.new("ok")) }) do
        DashboardSnapshotJob.perform_now(position.id, force: true)
      end
    end

    assert_empty calls
  end

  test "skips recent snapshot unless forced" do
    position = aerodrome_position(active: true)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended"
    )
    calls = []

    with_env("DASHBOARD_SNAPSHOT_MIN_REFRESH_INTERVAL_SECONDS" => "30") do
      DashboardSnapshotRefresh.stub(:new, ->(position:, **) { refresher(calls, :position, SnapshotResult.new("ok")) }) do
        RewardsFeesSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :rewards, SnapshotResult.new("ok")) }) do
          HedgeAccountingSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :accounting, SnapshotResult.new("ok")) }) do
            DashboardSnapshotJob.perform_now(position.id)
            DashboardSnapshotJob.perform_now(position.id, force: true)
          end
        end
      end
    end

    assert_equal %i[position rewards accounting], calls
  end

  private

  SnapshotResult = Struct.new(:refresh_status)

  def refresher(calls, marker, result)
    Object.new.tap do |object|
      object.define_singleton_method(:refresh) do
        calls << marker
        result
      end
    end
  end

  def aerodrome_position(active:)
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.random_number(1_000_000).to_s,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: active
    ).tap do |position|
      Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end

  def with_env(values)
    old = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
