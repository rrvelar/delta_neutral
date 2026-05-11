require "test_helper"

class AerodromeProductionTargetStepTestTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "AERODROME_TARGET_STEP_TEST_ENABLED" => "true",
      "AERODROME_TARGET_STEP_TEST_CONFIRM" => AerodromeProductionTargetStepTest::CONFIRMATION,
      "AERODROME_TARGET_STEP_TEST_UP_TARGET" => "0.015",
      "AERODROME_TARGET_STEP_TEST_DOWN_TARGET" => "0.01",
      "AERODROME_TARGET_STEP_TEST_RESTORE_TARGET" => "true",
      "AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH" => "true",
      "AERODROME_TARGET_STEP_TEST_STEP_SLEEP_SECONDS" => "0",
      "AERODROME_TARGET_STEP_TEST_READBACK_ATTEMPTS" => "1",
      "AERODROME_TARGET_STEP_TEST_READBACK_SLEEP_SECONDS" => "0",
      "AERODROME_MAX_LEVERAGE" => "1",
      "AERODROME_MAX_SHORT_ETH" => "0.02",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "50",
      "AERODROME_MIN_ORDER_NOTIONAL_USD" => "10",
      "AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED" => "true",
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

  test "blocks wrong confirmation and testnet true" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_TARGET_STEP_TEST_CONFIRM" => "wrong")) do
        assert_equal "blocked", build_service.report.fetch(:status)
      end

      with_env(@env.merge("HYPERLIQUID_TESTNET" => "true")) do
        assert_equal "blocked", build_service.report.fetch(:status)
      end
    end
  end

  test "blocks missing emergency close gates and min order below ten" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "false")) do
        assert_equal "blocked", build_service.report.fetch(:status)
      end

      with_env(@env.merge("AERODROME_MIN_ORDER_NOTIONAL_USD" => "9")) do
        assert_equal "blocked", build_service.report.fetch(:status)
      end
    end
  end

  test "blocks up or down target above target cap" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_TARGET_STEP_TEST_UP_TARGET" => "0.021")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "target step targets must be > 0 and <= 0.02"
      end
    end
  end

  test "blocks current ETH existing before start" do
    with_position_and_hedge do
      with_env(@env) do
        report = build_service(hyperliquid_service: HyperliquidReadMock.new(positions: [ eth_position("-0.01") ])).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "mainnet ETH position must be nil before target-step start"
      end
    end
  end

  test "blocks target step when implied short exceeds caps" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "0.01")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_match(/implies ETH short/, report.fetch(:errors).join("\n"))
      end
    end
  end

  test "saves and restores original target" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_success_service(hedge).report

        assert_equal "success", report.fetch(:status)
        assert_equal "0.01", hedge.reload.target.to_s("F")
        assert_equal true, report.fetch(:target_restored)
      end
    end
  end

  test "up and down steps create mocked WETH rebalances" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_success_service(hedge).report

        assert_equal "success", report.fetch(:status)
        assert_equal 2, report.fetch(:rebalance_rows).size
        assert_equal [ "WETH", "WETH" ], report.fetch(:rebalance_rows).map { |row| row.fetch(:asset) }
        assert_equal [ "0.015", "0.01" ], report.fetch(:rebalance_rows).map { |row| row.fetch(:new_short_size) }
      end
    end
  end

  test "guard blocked step skips HedgeSyncJob and records reason" do
    with_position_and_hedge do |hedge|
      guard = GuardDouble.new(allowed_sequence: [ false, false ])
      hedge_sync_calls = 0

      with_env(@env) do
        report = build_service(
          hyperliquid_service: HyperliquidReadMock.new(positions: [ nil, nil, nil, nil ]),
          hedge_sync: ->(_) { hedge_sync_calls += 1; create_success_rebalance(hedge) },
          volatility_guard: guard,
          emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") }
        ).report

        assert_equal "warn", report.fetch(:status)
        assert_equal 0, hedge_sync_calls
        assert_equal 2, report.fetch(:guard_results).size
        assert_equal false, report.fetch(:guard_results).first.fetch(:allowed)
        assert_equal false, report.fetch(:manual_action_required)
        assert_equal true, report.fetch(:target_restored)
      end
    end
  end

  test "close on finish closes ETH and nil readback succeeds" do
    with_position_and_hedge do |hedge|
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_success_service(hedge, emergency_close_factory: -> { emergency }).report

        assert_equal "success", report.fetch(:status)
        assert_equal true, emergency.called
        assert_nil report.fetch(:final_position)
        assert_equal true, report.fetch(:final_position_confirmed)
        assert_equal false, report.fetch(:manual_action_required)
      end
    end
  end

  test "errors restore target and close" do
    with_position_and_hedge do |hedge|
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(
          hyperliquid_service: HyperliquidReadMock.new(positions: [ nil, nil ]),
          position_sync: ->(_) { raise "sync failed" },
          emergency_close_factory: -> { emergency }
        ).report

        assert_equal "success", report.fetch(:status)
        assert_match(/sync failed/, report.fetch(:errors).join("\n"))
        assert_equal "0.01", hedge.reload.target.to_s("F")
        assert_equal true, emergency.called
        assert_equal false, report.fetch(:manual_action_required)
      end
    end
  end

  test "does not touch USDC or call direct order methods" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, nil, eth_position("-0.015"), nil ])

      with_env(@env) do
        report = build_success_service(hedge, hyperliquid_service: hyperliquid).report

        assert_equal "success", report.fetch(:status)
        assert_equal [ "ETH", "ETH", "ETH", "ETH" ], hyperliquid.position_assets
        assert_empty hyperliquid.order_calls
      end
    end
  end

  test "JSON report is serializable" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_success_service(hedge).report

        assert JSON.parse(JSON.generate(report))
      end
    end
  end

  private

  def build_success_service(hedge, hyperliquid_service: HyperliquidReadMock.new(positions: [ nil, nil, eth_position("-0.015"), nil ]), emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") })
    guard = GuardDouble.new(allowed_sequence: [ true, true ])
    step_sizes = [ "0.015", "0.01" ]
    hedge_sync = lambda do |_|
      create_success_rebalance(hedge, old_short_size: step_sizes.first == "0.015" ? "0" : "0.015", new_short_size: step_sizes.shift)
    end

    build_service(
      hyperliquid_service: hyperliquid_service,
      hedge_sync: hedge_sync,
      volatility_guard: guard,
      emergency_close_factory: emergency_close_factory
    )
  end

  def build_service(
    hyperliquid_service: HyperliquidReadMock.new(positions: []),
    position_sync: ->(_) { },
    hedge_sync: ->(_) { },
    volatility_guard: GuardDouble.new(allowed_sequence: [ true, true ]),
    emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") },
    log_dir: tmp_path("logs")
  )
    AerodromeProductionTargetStepTest.new(
      hyperliquid_service: hyperliquid_service,
      position_sync: position_sync,
      hedge_sync: hedge_sync,
      volatility_guard: volatility_guard,
      emergency_close_factory: emergency_close_factory,
      sleeper: ->(_) { },
      log_dir: log_dir,
      clock: -> { Time.zone.local(2026, 5, 10, 12, 0, 0) }
    )
  end

  class GuardDouble
    attr_reader :recorded_rebalances

    def initialize(allowed_sequence:)
      @allowed_sequence = allowed_sequence
      @recorded_rebalances = []
    end

    def report(**)
      allowed = @allowed_sequence.shift
      {
        status: allowed ? "pass" : "blocked",
        allowed: allowed,
        reason: allowed ? "test allowed" : "test blocked",
        price_move_bps: nil,
        window_move_bps: nil,
        price_divergence_bps: nil,
        cooldown_until: nil,
        blockers: allowed ? [] : [ "test blocked" ],
        warnings: [],
        proposed_delta_eth: "0.005",
        proposed_delta_usd: "11.5"
      }
    end

    def record_rebalance!(at:)
      @recorded_rebalances << at
    end
  end

  class HyperliquidReadMock
    attr_reader :position_assets, :order_calls

    def initialize(positions:)
      @positions = positions
      @position_assets = []
      @order_calls = []
    end

    def get_position(asset)
      @position_assets << asset
      value = @positions.shift
      raise value if value.is_a?(Exception)

      value
    end

    def open_short(*)
      @order_calls << :open_short
      raise "unexpected open_short"
    end

    def close_short(*)
      @order_calls << :close_short
      raise "unexpected close_short"
    end

    def set_leverage(*)
      @order_calls << :set_leverage
      raise "unexpected set_leverage"
    end
  end

  class EmergencyCloseReport
    attr_reader :called

    def initialize(status:)
      @status = status
      @called = false
    end

    def report
      @called = true
      {
        status: @status,
        attempts: [ { submitted_size: "0.015" } ],
        errors: [],
        before_position: { asset: "ETH", size: "-0.015" },
        after_position: nil
      }
    end
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
      asset0_amount: "1.0",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def create_success_rebalance(hedge, old_short_size: "0", new_short_size: "0.015")
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short_size,
      new_short_size: new_short_size,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size), mark_price: BigDecimal("2300.0") }
  end

  def tmp_path(name)
    Rails.root.join("tmp", "aerodrome_target_step_test", SecureRandom.hex(4), name)
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
