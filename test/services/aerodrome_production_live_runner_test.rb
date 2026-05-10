require "test_helper"

class AerodromeProductionLiveRunnerTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "AERODROME_PRODUCTION_LIVE_ENABLED" => "true",
      "AERODROME_PRODUCTION_LIVE_CONFIRM" => AerodromeProductionLiveRunner::CONFIRMATION,
      "AERODROME_PRODUCTION_LIVE_DURATION_SECONDS" => "180",
      "AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS" => "180",
      "AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN" => "true",
      "AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR" => "true",
      "AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL" => "true",
      "AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "false",
      "AERODROME_MAX_LEVERAGE" => "1",
      "AERODROME_MAX_SHORT_ETH" => "0.02",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "50",
      "AERODROME_MIN_ORDER_NOTIONAL_USD" => "10",
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => AerodromeLiveEmergencyClose::CONFIRMATION,
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.02"
    }
  end

  test "blocks by default" do
    with_env(@env.keys.to_h { |key| [ key, nil ] }) do
      report = build_service.report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "HYPERLIQUID_TESTNET must be false"
      assert_equal false, report.fetch(:orders_enabled)
    end
  end

  test "blocks individual gate failures" do
    with_position_and_hedge do
      {
        "AERODROME_LIVE_APPROVED" => "false",
        "AERODROME_HEDGE_ENABLED" => "false",
        "AERODROME_HEDGE_PAUSED" => "true",
        "AERODROME_PRODUCTION_LIVE_CONFIRM" => "wrong",
        "AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN" => "false",
        "AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR" => "false"
      }.each do |key, value|
        with_env(@env.merge(key => value)) do
          assert_equal "blocked", build_service.report.fetch(:status), key
        end
      end
    end
  end

  test "blocks hard risk limits" do
    with_position_and_hedge do
      {
        "AERODROME_PRODUCTION_LIVE_DURATION_SECONDS" => "21601",
        "AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS" => "179",
        "AERODROME_MAX_SHORT_ETH" => "0.021",
        "AERODROME_MAX_SHORT_NOTIONAL_USD" => "51",
        "AERODROME_MIN_ORDER_NOTIONAL_USD" => "9",
        "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "false"
      }.each do |key, value|
        with_env(@env.merge(key => value)) do
          assert_equal "blocked", build_service.report.fetch(:status), key
        end
      end
    end
  end

  test "blocks if mainnet ETH exists before start and adopt false" do
    with_position_and_hedge do
      with_env(@env) do
        report = build_service(hyperliquid_service: HyperliquidReadMock.new(positions: [ eth_position("-0.011") ])).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "mainnet ETH position must be nil before live run start unless adopt existing is true"
      end
    end
  end

  test "allows existing ETH within caps only when adopt existing true" do
    with_position_and_hedge do
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.011"), eth_position("-0.011"), eth_position("-0.011") ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid).report

        assert_equal "success", report.fetch(:status)
        assert_equal true, report.fetch(:position_left_open)
        assert_equal false, report.fetch(:manual_action_required)
      end
    end
  end

  test "blocks if readiness has blockers" do
    with_position_and_hedge do
      with_env(@env) do
        report = build_service(readiness: ReportDouble.new(status: "BLOCKED", blockers: [ "real blocker" ])).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "production supervised readiness blocker: real blocker"
      end
    end
  end

  test "single-instance lock prevents second run" do
    with_position_and_hedge do
      lock_path = tmp_path("run.lock")
      FileUtils.mkdir_p(lock_path.dirname)
      File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |file|
        file.flock(File::LOCK_EX | File::LOCK_NB)
        with_env(@env) do
          report = build_service(lock_path: lock_path).report

          assert_equal "blocked", report.fetch(:status)
          assert_includes report.fetch(:errors), "another production live runner is active"
        end
      end
    end
  end

  test "successful mocked production live run completes duration and leaves ETH open" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "success", report.fetch(:status)
        assert_equal "duration complete", report.fetch(:stop_reason)
        assert_equal true, report.fetch(:position_left_open)
        assert_equal false, report.fetch(:manual_action_required)
        assert_equal "not_run_leave_position_open", report.dig(:close_result, :status)
        assert_equal false, emergency.called
      end
    end
  end

  test "error stop calls emergency close when close_on_error true" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), nil ])
      hedge_sync = ->(_) { create_failed_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "success", report.fetch(:status)
        assert_equal "failed WETH rebalance", report.fetch(:stop_reason)
        assert_equal true, emergency.called
        assert_nil report.fetch(:final_position)
      end
    end
  end

  test "interrupt calls emergency close when close_on_signal true" do
    with_position_and_hedge do
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, nil ])
      position_sync = ->(_) { raise Interrupt }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, position_sync: position_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "success", report.fetch(:status)
        assert_equal "signal INT", report.fetch(:stop_reason)
        assert_equal true, emergency.called
      end
    end
  end

  test "final readback unknown returns close unknown and manual action" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), OpenSSL::SSL::SSLError.new("SSL_read") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }

      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_FINAL_READBACK_ATTEMPTS" => "1")) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync).report

        assert_equal "close_unknown", report.fetch(:status)
        assert_equal true, report.fetch(:manual_action_required)
      end
    end
  end

  test "never touches USDC or calls direct order methods" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }

      with_env(@env) do
        build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync).report
      end

      assert_equal [ "ETH", "ETH", "ETH" ], hyperliquid.reads
      assert_empty hyperliquid.order_calls
    end
  end

  private

  class HyperliquidReadMock
    attr_reader :reads, :order_calls

    def initialize(positions:)
      @positions = positions
      @reads = []
      @order_calls = []
    end

    def get_position(asset)
      raise "USDC must not be read" if asset == "USDC"

      @reads << asset
      position = @positions.empty? ? nil : @positions.shift
      raise position if position.is_a?(Exception)

      position
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

  class EmergencyCloseReport
    attr_reader :called

    def initialize(status:)
      @status = status
      @called = false
    end

    def report
      raise "emergency close should temporarily pause hedge" unless ENV["AERODROME_HEDGE_PAUSED"] == "true"

      @called = true
      { status: @status, errors: [], attempts: [] }
    end
  end

  class ReportDouble
    def initialize(status:, blockers: [])
      @status = status
      @blockers = blockers
    end

    def report
      {
        status: @status,
        blockers: @blockers,
        alerts: [],
        warnings: [],
        checks: {},
        next_steps: []
      }
    end
  end

  def build_service(
    hyperliquid_service: HyperliquidReadMock.new(positions: []),
    position_sync: ->(_) { },
    hedge_sync: ->(_) { },
    emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") },
    readiness: ReportDouble.new(status: "PASS"),
    lock_path: tmp_path("run.lock")
  )
    AerodromeProductionLiveRunner.new(
      hyperliquid_service: hyperliquid_service,
      position_sync: position_sync,
      hedge_sync: hedge_sync,
      emergency_close_factory: emergency_close_factory,
      readiness: readiness,
      sleeper: ->(_) { },
      log_dir: tmp_path("logs"),
      lock_path: lock_path,
      clock: -> { Time.zone.local(2026, 5, 10, 12, 0, 0) }
    )
  end

  def with_position_and_hedge
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.01", tolerance: "0.05", active: true)
    yield hedge if block_given?
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

  def create_success_rebalance(hedge, new_short_size: "0.011")
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0",
      new_short_size: new_short_size,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )
  end

  def create_failed_rebalance(hedge)
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0",
      new_short_size: "0",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_FAILED,
      message: "failed",
      rebalanced_at: Time.current
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
  end

  def tmp_path(name)
    Rails.root.join("tmp", "aerodrome_live_runner_test", SecureRandom.hex(4), name)
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
