require "test_helper"

class AerodromeLiveObservationWindowTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "AERODROME_LIVE_OBSERVATION_ENABLED" => "true",
      "AERODROME_LIVE_OBSERVATION_CONFIRM" => AerodromeLiveObservationWindow::CONFIRMATION,
      "AERODROME_LIVE_OBSERVATION_DURATION_SECONDS" => "60",
      "AERODROME_LIVE_OBSERVATION_INTERVAL_SECONDS" => "60",
      "AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH" => "true",
      "AERODROME_MAX_LEVERAGE" => "1",
      "AERODROME_MAX_SHORT_ETH" => "0.02",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "50",
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
      assert_nil report.fetch(:log_path)
    end
  end

  test "blocks on testnet" do
    with_position_and_hedge do
      with_env(@env.merge("HYPERLIQUID_TESTNET" => "true")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "HYPERLIQUID_TESTNET must be false"
      end
    end
  end

  test "blocks if live approved false" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_APPROVED" => "false")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "AERODROME_LIVE_APPROVED must be true"
      end
    end
  end

  test "blocks if hedge disabled or paused" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_HEDGE_ENABLED" => "false")) do
        report = build_service.report
        assert_includes report.fetch(:errors), "AERODROME_HEDGE_ENABLED must be true"
      end

      with_env(@env.merge("AERODROME_HEDGE_PAUSED" => "true")) do
        report = build_service.report
        assert_includes report.fetch(:errors), "AERODROME_HEDGE_PAUSED must be false"
      end
    end
  end

  test "blocks if confirmation missing or wrong" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_CONFIRM" => "wrong")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "AERODROME_LIVE_OBSERVATION_CONFIRM must equal #{AerodromeLiveObservationWindow::CONFIRMATION}"
      end
    end
  end

  test "blocks if duration exceeds maximum" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_DURATION_SECONDS" => "3601")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "duration must be <= 3600 seconds"
      end
    end
  end

  test "allows duration up to one hour when all gates pass" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011"), nil ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }

      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_DURATION_SECONDS" => "3600", "AERODROME_LIVE_OBSERVATION_INTERVAL_SECONDS" => "3600")) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync).report

        assert_equal "success", report.fetch(:status)
        assert_equal 3600, report.dig(:gates, :duration_seconds)
      end
    end
  end

  test "blocks if interval below minimum" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_INTERVAL_SECONDS" => "59")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "interval must be >= 60 seconds"
      end
    end
  end

  test "blocks if close on finish is not true" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH" => "false")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH must be true"
      end
    end
  end

  test "blocks if max ETH or max notional are too high" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "0.021")) do
        report = build_service.report
        assert_includes report.fetch(:errors), "AERODROME_MAX_SHORT_ETH must be configured and <= 0.02"
      end

      with_env(@env.merge("AERODROME_MAX_SHORT_NOTIONAL_USD" => "51")) do
        report = build_service.report
        assert_includes report.fetch(:errors), "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= 50.0"
      end
    end
  end

  test "blocks if emergency close gates are missing" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => nil)) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true"
      end
    end
  end

  test "blocks if emergency close max is below max short" do
    with_position_and_hedge do
      with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.01")) do
        report = build_service.report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH"
      end
    end
  end

  test "blocks if mainnet ETH short exists before start" do
    with_position_and_hedge do
      service = HyperliquidReadMock.new(positions: [ eth_position("-0.01") ])

      with_env(@env) do
        report = build_service(hyperliquid_service: service).report

        assert_equal "blocked", report.fetch(:status)
        assert_includes report.fetch(:errors), "mainnet ETH position must be nil before observation window"
      end
    end
  end

  test "runs mocked loop successfully and closes on finish" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011"), nil ])
      position_sync = ->(position_id) { @position_sync_id = position_id }
      hedge_sync = ->(hedge_id) { create_success_rebalance(hedge); @hedge_sync_id = hedge_id }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(
          hyperliquid_service: hyperliquid,
          position_sync: position_sync,
          hedge_sync: hedge_sync,
          emergency_close_factory: -> { emergency }
        ).report

        assert_equal "success", report.fetch(:status)
        assert_equal hedge.position_id, @position_sync_id
        assert_equal hedge.id, @hedge_sync_id
        assert_equal 1, report.fetch(:iterations).size
        assert_equal "success", report.dig(:final_close, :status)
        assert_nil report.fetch(:final_position)
        assert_equal true, File.exist?(report.fetch(:log_path))
        assert_equal [ "ETH", "ETH", "ETH", "ETH" ], hyperliquid.reads
        assert_equal true, emergency.called
      end
    end
  end

  test "stops and closes on failed rebalance" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011"), nil ])
      hedge_sync = ->(_) { create_failed_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "failed", report.fetch(:status)
        assert_includes report.fetch(:errors), "failed ShortRebalance created during observation window"
        assert_equal true, emergency.called
      end
    end
  end

  test "stops and closes if actual ETH exceeds max" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.03"), eth_position("-0.03"), nil ])
      hedge_sync = ->(_) { create_success_rebalance(hedge, new_short_size: "0.03") }
      emergency = EmergencyCloseReport.new(status: "success")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "failed", report.fetch(:status)
        assert_includes report.fetch(:errors), "actual ETH short exceeds AERODROME_MAX_SHORT_ETH"
        assert_equal true, emergency.called
      end
    end
  end

  test "success requires final ETH nil" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011"), eth_position("-0.011") ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }
      emergency = EmergencyCloseReport.new(status: "failed")

      with_env(@env) do
        report = build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync, emergency_close_factory: -> { emergency }).report

        assert_equal "failed", report.fetch(:status)
        assert_equal "failed", report.dig(:final_close, :status)
        assert_equal "-0.011", report.fetch(:final_position).fetch(:size)
      end
    end
  end

  test "never touches USDC or calls direct order methods" do
    with_position_and_hedge do |hedge|
      hyperliquid = HyperliquidReadMock.new(positions: [ nil, eth_position("-0.011"), eth_position("-0.011"), nil ])
      hedge_sync = ->(_) { create_success_rebalance(hedge) }

      with_env(@env) do
        build_service(hyperliquid_service: hyperliquid, hedge_sync: hedge_sync).report
      end

      assert_equal [ "ETH", "ETH", "ETH", "ETH" ], hyperliquid.reads
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
      @positions.empty? ? nil : @positions.shift
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

  def build_service(
    hyperliquid_service: HyperliquidReadMock.new(positions: []),
    position_sync: ->(_) { },
    hedge_sync: ->(_) { },
    emergency_close_factory: -> { EmergencyCloseReport.new(status: "success") }
  )
    AerodromeLiveObservationWindow.new(
      hyperliquid_service: hyperliquid_service,
      position_sync: position_sync,
      hedge_sync: hedge_sync,
      emergency_close_factory: emergency_close_factory,
      sleeper: ->(_) { },
      log_dir: Rails.root.join("tmp", "aerodrome_live_observation_test"),
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

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
