require "test_helper"
require "rake"

class DashboardTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dashboard:refresh_all_position_snapshots")
    Rake::Task["dashboard:refresh_all_position_snapshots"].reenable
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

  private

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
end
