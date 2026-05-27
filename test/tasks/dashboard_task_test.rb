require "test_helper"
require "rake"

class DashboardTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dashboard:refresh_all_position_snapshots")
    Rake::Task["dashboard:refresh_all_position_snapshots"].reenable
    Rake::Task["dashboard:production_health"].reenable if Rake::Task.task_defined?("dashboard:production_health")
  end

  test "refresh all position snapshots runs all read-only refreshers" do
    position = Position.create!(
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
      active: true
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :position, snapshot_result(11)) }) do
      RewardsFeesSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :rewards_fees, snapshot_result(12)) }) do
        HedgeAccountingSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :hedge_accounting, snapshot_result(13)) }) do
          original_position_id = ENV["position_id"]
          ENV["position_id"] = position.id.to_s
          begin
            out, = capture_io { Rake::Task["dashboard:refresh_all_position_snapshots"].invoke }

            assert_equal %i[position rewards_fees hedge_accounting], calls
            assert_match '"orders_submitted": 0', out
            assert_match '"signatures_created": 0', out
          ensure
            ENV["position_id"] = original_position_id
          end
        end
      end
    end
  end

  test "production health task outputs read-only counters" do
    position = aerodrome_position
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      extended_auto_enabled: true,
      signer_status: "ok",
      signer_checked_at: Time.current,
      open_orders_count_extended: 0
    )
    position.create_position_rewards_fees_snapshot!(refreshed_at: Time.current, refresh_status: "ok")
    position.create_position_hedge_accounting_snapshot!(refreshed_at: Time.current, refresh_status: "ok", venue: "extended")

    with_position_id(position.id) do
      out, = capture_io { Rake::Task["dashboard:production_health"].invoke }
      payload = JSON.parse(out)

      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
      assert_equal "active", payload.dig("current_snapshot_summary", "exposure", "extended_status")
    end
  end

  private

  def aerodrome_position
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
      active: true
    ).tap do |position|
      Hedge.create!(position: position, target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end

  SnapshotResult = Struct.new(:id, :refresh_status, keyword_init: true)

  def snapshot_result(id)
    SnapshotResult.new(id: id, refresh_status: "ok")
  end

  def refresher(calls, name, snapshot)
    Object.new.tap do |object|
      object.define_singleton_method(:refresh) do
        calls << name
        snapshot
      end
    end
  end

  def with_position_id(position_id)
    original_position_id = ENV["position_id"]
    ENV["position_id"] = position_id.to_s
    yield
  ensure
    original_position_id.nil? ? ENV.delete("position_id") : ENV["position_id"] = original_position_id
  end
end
