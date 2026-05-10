require "test_helper"

class AerodromeProductionSupervisedReadinessTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "false",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => nil,
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.025",
      "AERODROME_REWARDS_ENABLED" => "false",
      "AERODROME_FEES_ENABLED" => "false",
      "GIT_SHA" => "abc123"
    }
  end

  test "reports readiness data without writes" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge, id: 188)
      create_snapshot(hedge.position)
      summary = SummaryReport.new(status: "PASS")

      with_env(@env) do
        assert_no_data_changes do
          report = build_service(observation_summary: summary).report

          assert_equal "PASS", report.fetch(:status)
          assert_equal false, report.fetch(:database_write)
          assert_equal false, report.fetch(:orders_enabled)
          assert_equal false, report.fetch(:hyperliquid_execution)
          assert_equal "abc123", report.fetch(:git_sha)
          assert_empty report.fetch(:blockers)
          assert_equal "success", report.dig(:observation_summary, :final_close_status)
        end
      end
    end
  end

  test "blocks when safe env is not present" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)

      with_env(@env.merge("AERODROME_HEDGE_ENABLED" => "true")) do
        report = build_service.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert report.fetch(:blockers).any? { |blocker| blocker.include?("AERODROME_HEDGE_ENABLED is false") }
      end
    end
  end

  test "reports mainnet ETH open as blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)
      mainnet = HyperliquidReadMock.new(position: { asset: "ETH", size: BigDecimal("-0.011") })

      with_env(@env) do
        report = build_service(mainnet_hyperliquid_service: mainnet).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "Mainnet ETH position is nil: 0.011"
      end
    end
  end

  test "reports failed unacknowledged WETH as blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)
      hedge.short_rebalances.create!(
        asset: "WETH",
        old_short_size: "0",
        new_short_size: "0",
        realized_pnl: "0",
        status: ShortRebalance::STATUS_FAILED,
        message: "failed",
        rebalanced_at: Time.current
      )

      with_env(@env) do
        report = build_service.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert report.fetch(:blockers).any? { |blocker| blocker.include?("No unacknowledged failed WETH rebalances") }
      end
    end
  end

  test "does not call Hyperliquid execution methods" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)
      mainnet = HyperliquidReadMock.new(position: nil)
      testnet = HyperliquidReadMock.new(position: nil)

      with_env(@env) do
        build_service(mainnet_hyperliquid_service: mainnet, testnet_hyperliquid_service: testnet).report
      end

      assert_equal [ "ETH" ], mainnet.reads
      assert_equal [ "ETH" ], testnet.reads
      assert_empty mainnet.order_calls
      assert_empty testnet.order_calls
    end
  end

  private

  class HyperliquidReadMock
    attr_reader :reads, :order_calls

    def initialize(position:)
      @position = position
      @reads = []
      @order_calls = []
    end

    def get_position(asset)
      @reads << asset
      @position
    end

    def open_short(*)
      @order_calls << :open_short
      raise "open_short must not be called"
    end

    def close_short(*)
      @order_calls << :close_short
      raise "close_short must not be called"
    end

    def set_leverage(*)
      @order_calls << :set_leverage
      raise "set_leverage must not be called"
    end
  end

  class SummaryReport
    def initialize(status:)
      @status = status
    end

    def report
      {
        safety_banner: AerodromeLiveObservationSummary::BANNER,
        status: @status,
        database_write: false,
        orders_enabled: false,
        hyperliquid_execution: false,
        log_path: "storage/aerodrome_live_observation/test.jsonl",
        duration_seconds: 10_800,
        iterations: 36,
        first_timestamp: "2026-05-10T06:01:57Z",
        last_timestamp: "2026-05-10T09:01:57Z",
        max_observed_eth_short: "0.011",
        rebalances_count: 1,
        errors_count: 0,
        final_close_status: "success",
        final_position: nil,
        final_position_confirmed: true,
        manual_action_required: false,
        blockers: [],
        warnings: [],
        next_steps: []
      }
    end
  end

  def build_service(
    mainnet_hyperliquid_service: HyperliquidReadMock.new(position: nil),
    testnet_hyperliquid_service: HyperliquidReadMock.new(position: nil),
    observation_summary: SummaryReport.new(status: "PASS")
  )
    AerodromeProductionSupervisedReadiness.new(
      mainnet_hyperliquid_service: mainnet_hyperliquid_service,
      testnet_hyperliquid_service: testnet_hyperliquid_service,
      observation_summary: observation_summary,
      log_dir: Rails.root.join("tmp")
    )
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

  def create_success_rebalance(hedge, id: nil)
    attributes = {
      asset: "WETH",
      old_short_size: "0",
      new_short_size: "0.011",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    }
    attributes[:id] = id if id
    hedge.short_rebalances.create!(attributes)
  end

  def create_snapshot(position)
    position.pnl_snapshots.create!(
      asset0_amount: position.asset0_amount,
      asset1_amount: position.asset1_amount,
      asset0_price_usd: position.asset0_price_usd,
      asset1_price_usd: position.asset1_price_usd,
      pool_unrealized: "1",
      hedge_unrealized: "0",
      hedge_realized: "0",
      collected_fees0: "0",
      collected_fees1: "0",
      uncollected_fees0: "0",
      uncollected_fees1: "0",
      captured_at: Time.current
    )
  end

  def assert_no_data_changes(&block)
    assert_no_difference -> { Position.count } do
      assert_no_difference -> { Hedge.count } do
        assert_no_difference -> { ShortRebalance.count } do
          assert_no_difference -> { PnlSnapshot.count }, &block
        end
      end
    end
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
