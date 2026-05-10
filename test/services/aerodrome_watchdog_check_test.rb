require "test_helper"

class AerodromeWatchdogCheckTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true",
      "APP_GIT_SHA" => "abc123",
      "AERODROME_REWARDS_ENABLED" => "false",
      "AERODROME_FEES_ENABLED" => "false"
    }
  end

  test "read-only task produces no DB writes" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)

      with_env(@env) do
        assert_no_data_changes do
          report = build_service.report

          assert_equal "PASS", report.fetch(:status)
          assert_equal false, report.fetch(:database_write)
          assert_equal false, report.fetch(:orders_enabled)
          assert_equal false, report.fetch(:hyperliquid_execution)
        end
      end
    end
  end

  test "mainnet ETH open while safe env creates blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service(mainnet_hyperliquid_service: HyperliquidReadMock.new(position: eth_position("-0.011"))).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:alerts), "mainnet ETH position exists while Aerodrome hedge is disabled/paused"
      end
    end
  end

  test "manual action required creates blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service(observation_summary: SummaryReport.new(manual_action_required: true)).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:alerts), "latest observation requires manual action"
      end
    end
  end

  test "final position not nil creates blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service(observation_summary: SummaryReport.new(final_position: { "size" => "-0.011" })).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:alerts), "latest observation final position is not nil"
      end
    end
  end

  test "unacknowledged failed WETH creates blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge, old_short_size: "0.011", new_short_size: "0")
      create_failed_rebalance(hedge, message: "failed")
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:alerts), "unacknowledged failed WETH rebalance exists"
      end
    end
  end

  test "successful USDC rebalance creates blocker" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_success_rebalance(hedge, asset: "USDC")
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:alerts), "unexpected successful USDC rebalance exists"
      end
    end
  end

  test "stale PnL creates warning" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position, captured_at: 30.minutes.ago)

      with_env(@env) do
        report = build_service.report

        assert_equal "WARN", report.fetch(:status)
        assert report.fetch(:warnings).any? { |warning| warning.include?("Latest PnL snapshot fresh") }
      end
    end
  end

  test "acknowledged failed WETH is warning only" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_failed_rebalance(hedge, message: "failed #{AerodromeFailedRebalanceAcknowledgment::MARKER}")
      create_snapshot(hedge.position)

      with_env(@env) do
        report = build_service.report

        assert_equal "WARN", report.fetch(:status)
        assert_empty report.fetch(:blockers)
        assert report.fetch(:warnings).any? { |warning| warning.include?("Acknowledged failed WETH rows") }
      end
    end
  end

  test "does not call Hyperliquid execution methods" do
    with_position_and_hedge do |hedge|
      create_success_rebalance(hedge)
      create_snapshot(hedge.position)
      mainnet = HyperliquidReadMock.new(position: nil)

      with_env(@env) do
        build_service(mainnet_hyperliquid_service: mainnet).report
      end

      assert_equal [ "ETH" ], mainnet.reads
      assert_empty mainnet.order_calls
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
    def initialize(status: "PASS", final_position: nil, manual_action_required: false, warnings: [])
      @status = status
      @final_position = final_position
      @manual_action_required = manual_action_required
      @warnings = warnings
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
        final_position: @final_position,
        final_position_confirmed: true,
        manual_action_required: @manual_action_required,
        blockers: [],
        warnings: @warnings,
        next_steps: []
      }
    end
  end

  class ReadinessReport
    def initialize(status: "PASS", blockers: [])
      @status = status
      @blockers = blockers
    end

    def report
      {
        status: @status,
        blockers: @blockers,
        warnings: []
      }
    end
  end

  def build_service(
    mainnet_hyperliquid_service: HyperliquidReadMock.new(position: nil),
    testnet_hyperliquid_service: HyperliquidReadMock.new(position: nil),
    observation_summary: SummaryReport.new,
    production_readiness: ReadinessReport.new
  )
    AerodromeWatchdogCheck.new(
      mainnet_hyperliquid_service: mainnet_hyperliquid_service,
      testnet_hyperliquid_service: testnet_hyperliquid_service,
      observation_summary: observation_summary,
      production_readiness: production_readiness,
      log_dir: Rails.root.join("tmp"),
      clock: -> { Time.current }
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

  def create_success_rebalance(hedge, asset: "WETH", old_short_size: "0", new_short_size: "0.011")
    hedge.short_rebalances.create!(
      asset: asset,
      old_short_size: old_short_size,
      new_short_size: new_short_size,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )
  end

  def create_failed_rebalance(hedge, message:)
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0",
      new_short_size: "0",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_FAILED,
      message: message,
      rebalanced_at: Time.current
    )
  end

  def create_snapshot(position, captured_at: Time.current)
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
      captured_at: captured_at
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
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
