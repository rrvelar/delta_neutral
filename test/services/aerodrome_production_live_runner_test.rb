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
        "AERODROME_MAX_SHORT_ETH" => "0.751",
        "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2001",
        "AERODROME_MIN_ORDER_NOTIONAL_USD" => "9",
        "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "false"
      }.each do |key, value|
        with_env(@env.merge(key => value)) do
          assert_equal "blocked", build_service.report.fetch(:status), key
        end
      end
    end
  end

  test "allows supervised production cap tier" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.40"), eth_position("-0.40") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge, new_short_size: "0.40") }
      production_env = @env.merge(
        "AERODROME_MAX_SHORT_ETH" => "0.55",
        "AERODROME_MAX_SHORT_NOTIONAL_USD" => "1300",
        "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.60"
      )

      with_env(production_env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync).report

        assert_equal "success", report.fetch(:status)
        assert_equal true, report.fetch(:position_left_open)
        assert_equal "0.55", report.dig(:gates, :max_short_eth)
        assert_equal "1300.0", report.dig(:gates, :max_short_notional_usd)
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
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.011" })
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.011"), eth_position("-0.011"), eth_position("-0.011") ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "success", report.fetch(:status)
        assert_equal true, report.fetch(:position_left_open)
        assert_equal false, report.fetch(:manual_action_required)
        assert_equal({ asset: "ETH", size: "-0.011" }, report.fetch(:adopted_position).slice(:asset, :size))
      end
    end
  end

  test "adopt existing suppresses only strict readiness mainnet ETH blocker" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.011" })
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.011"), eth_position("-0.011"), eth_position("-0.011") ])
      readiness = ReportDouble.new(status: "BLOCKED", blockers: [ "Mainnet ETH position is nil: 0.011" ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid, readiness: readiness, log_dir: log_dir).report

        assert_equal "success", report.fetch(:status)
        assert_includes report.fetch(:warnings), "mainnet ETH is approved open hedge and is being adopted"
        assert_empty report.fetch(:errors)
      end
    end
  end

  test "adopt existing keeps unrelated readiness blocker" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.011" })
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.011") ])
      readiness = ReportDouble.new(status: "BLOCKED", blockers: [ "Mainnet ETH position is nil: 0.011", "unrelated blocker" ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid, readiness: readiness, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "production supervised readiness blocker: unrelated blocker"
        refute_includes report.fetch(:errors), "production supervised readiness blocker: Mainnet ETH position is nil: 0.011"
      end
    end
  end

  test "adopt existing blocks when approved open detector is not approved" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.011" }, manual_action_required: true)
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.011") ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "previous production live/canary log has manual_action_required=true"
      end
    end
  end

  test "adopt existing blocks current ETH over caps" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.011" })
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.021") ])

      with_env(@env.merge("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT" => "true")) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "existing mainnet ETH position exceeds caps"
      end
    end
  end

  test "previous approved open final position with current ETH nil allows run with warning" do
    with_position_and_hedge do |hedge|
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.0101" })
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.0108"), eth_position("-0.0108") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge, new_short_size: "0.0108") }

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, log_dir: log_dir).report

        assert_equal "success", report.fetch(:status)
        assert_includes report.fetch(:warnings), "previous approved open hedge is no longer open / current readback nil"
        assert_equal true, report.fetch(:position_left_open)
      end
    end
  end

  test "previous approved open final position with current ETH matching still requires explicit adopt" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.0101" })
      hyperliquid = HyperliquidReadMock.new(positions: [ eth_position("-0.0101") ])

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "mainnet ETH position must be nil before live run start unless adopt existing is true"
      end
    end
  end

  test "previous manual action required still blocks even when current ETH nil" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, manual_action_required: true)
      hyperliquid = HyperliquidReadMock.new(positions: [ nil ])

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "previous production live/canary log has manual_action_required=true"
      end
    end
  end

  test "current ETH readback error blocks when previous final position exists" do
    with_position_and_hedge do
      log_dir = tmp_path("logs")
      write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.0101" })
      hyperliquid = HyperliquidReadMock.new(positions: [ OpenSSL::SSL::SSLError.new("SSL_read") ])

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, log_dir: log_dir).report

        assert_equal "blocked", report.fetch(:status)
        assert_match(/mainnet ETH readback failed before live run: OpenSSL::SSL::SSLError: SSL_read/, report.fetch(:errors).join("\n"))
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
      lock_path = tmp_path("run.lock")
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }, lock_path: lock_path).report

        assert_equal "success", report.fetch(:status)
        assert_equal "duration complete", report.fetch(:stop_reason)
        assert_equal true, report.fetch(:position_left_open)
        assert_equal false, report.fetch(:manual_action_required)
        assert_equal "not_run_leave_position_open", report.dig(:close_result, :status)
        assert_equal false, emergency.called
        assert_not_predicate lock_path, :exist?
      end
    end
  end

  test "error stop calls emergency close when close_on_error true" do
    with_position_and_hedge do |hedge|
      lock_path = tmp_path("run.lock")
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), nil ])
      hedge_sync = ->(_) { create_failed_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }, lock_path: lock_path).report

        assert_equal "success", report.fetch(:status)
        assert_equal "failed WETH rebalance", report.fetch(:stop_reason)
        assert_equal true, emergency.called
        assert_nil report.fetch(:final_position)
        assert_not_predicate lock_path, :exist?
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

  test "guard blocked skips hedge sync for that iteration" do
    with_position_and_hedge do
      guard = GuardDouble.new(enabled: true, allowed: false)
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, nil, nil ])
      hedge_sync_called = false

      with_env(@env) do
        report = build_service(
          hyperliquid_service: hyperliquid,
          hedge_sync: ->(_) { hedge_sync_called = true },
          volatility_guard: guard
        ).report

        assert_equal "failed", report.fetch(:status)
        assert_equal true, report.fetch(:manual_action_required)
        assert_equal false, hedge_sync_called
        assert_equal "blocked", report.fetch(:iteration_events).first.fetch(:rebalance_guard_status)
        assert_equal false, report.fetch(:iteration_events).first.fetch(:rebalance_guard_allowed)
      end
    end
  end

  test "guard allowed calls hedge sync" do
    with_position_and_hedge do |hedge|
      guard = GuardDouble.new(enabled: true, allowed: true)
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, nil, eth_position("-0.011"), eth_position("-0.011") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }

      with_env(@env) do
        report = build_service(
          hyperliquid_service: hyperliquid,
          hedge_sync: hedge_sync,
          volatility_guard: guard
        ).report

        assert_equal "success", report.fetch(:status)
        assert_equal "pass", report.fetch(:iteration_events).first.fetch(:rebalance_guard_status)
        assert_equal true, report.fetch(:iteration_events).first.fetch(:rebalance_guard_allowed)
      end
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

  class GuardDouble
    attr_reader :recorded_rebalance

    def initialize(enabled:, allowed:)
      @enabled = enabled
      @allowed = allowed
      @recorded_rebalance = false
    end

    def enabled?
      @enabled
    end

    def report(*)
      {
        status: @allowed ? "pass" : "blocked",
        allowed: @allowed,
        reason: @allowed ? "allowed" : "test blocked",
        blockers: @allowed ? [] : [ "test blocked" ],
        warnings: [],
        proposed_delta_eth: "0.001",
        proposed_delta_usd: "2.3"
      }
    end

    def record_rebalance!(at:)
      @recorded_rebalance = true
    end
  end

  def build_service(
    hyperliquid_service: HyperliquidReadMock.new(positions: []),
    position_sync: ->(_) { },
    hedge_sync: ->(_) { },
    emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") },
    volatility_guard: AerodromeRebalanceVolatilityGuard.new(clock: -> { Time.zone.local(2026, 5, 10, 12, 0, 0) }),
    readiness: ReportDouble.new(status: "PASS"),
    log_dir: tmp_path("logs"),
    lock_path: tmp_path("run.lock")
  )
    AerodromeProductionLiveRunner.new(
      hyperliquid_service: hyperliquid_service,
      position_sync: position_sync,
      hedge_sync: hedge_sync,
      volatility_guard: volatility_guard,
      emergency_close_factory: emergency_close_factory,
      readiness: readiness,
      sleeper: ->(_) { },
      log_dir: log_dir,
      lock_path: lock_path,
      clock: -> { Time.zone.local(2026, 5, 10, 12, 0, 0) }
    )
  end

  def write_previous_live_log(log_dir, final_position: { asset: "ETH", size: "-0.0101" }, manual_action_required: false, confirmed: true)
    FileUtils.mkdir_p(log_dir)
    File.write(
      Pathname(log_dir).join("20260510110000-previous.jsonl"),
      [
        {
          type: "start",
          gates: {
            max_short_eth: "0.02",
            max_short_notional_usd: "50"
          }
        }.to_json,
        {
          type: "finish",
          status: "success",
          stop_reason: "duration complete",
          position_left_open: true,
          final_position: final_position,
          final_position_confirmed: confirmed,
          manual_action_required: manual_action_required,
          errors: []
        }.to_json
      ].join("\n")
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
