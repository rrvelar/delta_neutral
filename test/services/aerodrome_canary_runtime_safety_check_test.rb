require "test_helper"
require "tmpdir"

class AerodromeCanaryRuntimeSafetyCheckTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "AERODROME_PRODUCTION_CANARY_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => AerodromeLiveEmergencyClose::CONFIRMATION,
      "AERODROME_MAX_SHORT_ETH" => "0.02",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "50"
    }
  end

  test "passes with live canary env and ETH short within caps" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.011")).report

        assert_equal "PASS", report.fetch(:status)
        assert_empty report.fetch(:blockers)
        assert_equal false, report.fetch(:database_write)
      end
    end
  end

  test "blocks ETH short over max ETH" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.03")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "ETH short <= max ETH: 0.03"
      end
    end
  end

  test "blocks notional over max notional" do
    with_position_and_hedge do |hedge|
      with_env(@env.merge("AERODROME_MAX_SHORT_NOTIONAL_USD" => "20")) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.011")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "ETH notional <= max notional: 25.3"
      end
    end
  end

  test "blocks successful USDC rebalance" do
    with_position_and_hedge do |hedge|
      hedge.short_rebalances.create!(asset: "USDC", old_short_size: "0", new_short_size: "1", realized_pnl: "0", status: ShortRebalance::STATUS_SUCCESS, rebalanced_at: Time.current)

      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.011")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "No successful USDC during canary"
      end
    end
  end

  test "blocks failed WETH during run" do
    with_position_and_hedge do |hedge|
      hedge.short_rebalances.create!(asset: "WETH", old_short_size: "0", new_short_size: "0", realized_pnl: "0", status: ShortRebalance::STATUS_FAILED, message: "failed", rebalanced_at: Time.current)

      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.011")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "No failed WETH during canary"
      end
    end
  end

  test "blocks previous canary log with manual action required" do
    with_position_and_hedge do |hedge|
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, "20260510120000-test.jsonl"),
          { type: "finish", manual_action_required: true, final_position: nil }.to_json + "\n"
        )

        with_env(@env) do
          report = build_service(hedge: hedge, eth_position: eth_position("-0.011"), log_dir: dir).report

          assert_equal "BLOCKED", report.fetch(:status)
          assert_includes report.fetch(:blockers), "Previous canary manual_action_required false"
        end
      end
    end
  end

  test "blocks previous canary log with non nil final position" do
    with_position_and_hedge do |hedge|
      Dir.mktmpdir do |dir|
        File.write(
          File.join(dir, "20260510120000-test.jsonl"),
          { type: "finish", manual_action_required: false, final_position: { size: "-0.011" } }.to_json + "\n"
        )

        with_env(@env) do
          report = build_service(hedge: hedge, eth_position: eth_position("-0.011"), log_dir: dir).report

          assert_equal "BLOCKED", report.fetch(:status)
          assert report.fetch(:blockers).any? { |blocker| blocker.include?("Previous canary final position nil") }
        end
      end
    end
  end

  test "does not call execution methods or write DB" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        writes = capture_write_sql do
          build_service(hedge: hedge, eth_position: eth_position("-0.011")).report
        end

        assert_empty writes
      end
    end
  end

  private

  def build_service(hedge:, eth_position:, log_dir: Rails.root.join("tmp", "missing-canary-runtime-test-logs"))
    AerodromeCanaryRuntimeSafetyCheck.new(hedge: hedge, eth_position: eth_position, log_dir: log_dir)
  end

  def with_position_and_hedge
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.01", tolerance: "0.05", active: true)
    yield hedge
  ensure
    position&.destroy
  end

  def create_aerodrome_position
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
    Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.1",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
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

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
