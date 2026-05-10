require "test_helper"
require "tmpdir"

class AerodromeProductionLiveStatusTest < ActiveSupport::TestCase
  test "production live status is read-only" do
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, "20260510120000-test.jsonl")
      File.write(log_path, { type: "finish", status: "success", manual_action_required: false, final_position: { size: "-0.011" } }.to_json + "\n")
      hyperliquid = HyperliquidReadMock.new(position: { asset: "ETH", size: BigDecimal("-0.011") })

      writes = capture_write_sql do
        report = AerodromeProductionLiveStatus.new(hyperliquid_service: hyperliquid, log_dir: dir, lock_path: File.join(dir, "run.lock")).report

        assert_equal "PASS", report.fetch(:status)
        assert_equal false, report.fetch(:database_write)
        assert_equal false, report.fetch(:orders_enabled)
        assert_equal false, report.fetch(:hyperliquid_execution)
        assert_equal log_path, report.fetch(:latest_log_path)
      end

      assert_empty writes
      assert_empty hyperliquid.order_calls
    end
  end

  test "production live stop plan is read-only" do
    hyperliquid = HyperliquidReadMock.new(position: nil)

    writes = capture_write_sql do
      report = AerodromeProductionLiveStopPlan.new(hyperliquid_service: hyperliquid).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert report.fetch(:stop_steps).any? { |step| step.include?("live_emergency_close") }
    end

    assert_empty writes
    assert_empty hyperliquid.order_calls
  end

  private

  class HyperliquidReadMock
    attr_reader :order_calls

    def initialize(position:)
      @position = position
      @order_calls = []
    end

    def get_position(asset)
      raise "USDC must not be read" if asset == "USDC"

      @position
    end

    def open_short(*)
      @order_calls << :open_short
    end

    def close_short(*)
      @order_calls << :close_short
    end

    def set_leverage(*)
      @order_calls << :set_leverage
    end
  end

  def capture_write_sql
    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload.fetch(:sql)
      writes << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)\b/i)
    end
    yield
    writes
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
