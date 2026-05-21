require "test_helper"

class AerodromeDashboardHedgeActionTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "1.6",
      "AERODROME_MAX_SHORT_ETH" => "1.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "1.6",
      "AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED" => "true",
      "AERODROME_DASHBOARD_HEDGE_CONFIRMATION" => AerodromeDashboardHedgeAction::CONFIRMATION,
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "HYPERLIQUID_TESTNET" => "false"
    }
    @log_dir = Rails.root.join("tmp", "dashboard_hedge_action_test", SecureRandom.hex(4))
  end

  teardown do
    FileUtils.rm_rf(@log_dir)
  end

  test "open preview computes expected short for LP WETH amount" do
    position = create_position(asset0_amount: "1.25", target: "1.0")

    with_env(@env) do
      report = build_action(position: position, action: "open", execute: false, positions: [ nil ]).report

      assert_equal "preview", report.fetch(:status)
      assert_equal "1.25", report.fetch(:target_short_eth)
      assert_equal "1.25", report.fetch(:submitted_delta_eth)
      assert_equal false, report.fetch(:orders_enabled)
      assert File.exist?(report.fetch(:receipt_path))
    end
  end

  test "open live action is blocked without submitted confirmation" do
    position = create_position
    runner = CallRecorder.new

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: "wrong",
        positions: [ nil ],
        hedge_sync_runner: runner
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "submitted confirmation must equal #{AerodromeDashboardHedgeAction::CONFIRMATION}"
      assert_empty runner.calls
    end
  end

  test "open live action calls hedge sync only when all gates are enabled" do
    position = create_position
    runner = CallRecorder.new

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::CONFIRMATION,
        positions: [ nil, eth_position("-1.25") ],
        hedge_sync_runner: runner
      ).report

      assert_equal "submitted", report.fetch(:status)
      assert_equal [ position.hedge.id ], runner.calls
      assert_equal true, report.fetch(:orders_enabled)
    end
  end

  test "rebalance blocks when drift is within tolerance" do
    position = create_position(asset0_amount: "1.25", target: "1.0", tolerance: "0.05")

    with_env(@env) do
      report = build_action(position: position, action: "rebalance", positions: [ eth_position("-1.22") ]).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "drift is within hedge tolerance"
    end
  end

  test "close uses emergency close path" do
    position = create_position
    emergency = EmergencyCloseStub.new(status: "success")

    with_env(@env.merge(
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => AerodromeLiveEmergencyClose::CONFIRMATION
    )) do
      report = build_action(
        position: position,
        action: "close",
        execute: true,
        confirmation: AerodromeLiveEmergencyClose::CONFIRMATION,
        positions: [ eth_position("-0.5"), nil ],
        emergency_close_factory: -> { emergency }
      ).report

      assert_equal "submitted", report.fetch(:status)
      assert_equal true, emergency.called
      assert_equal "success", report.fetch(:result).fetch(:status)
    end
  end

  test "caps are enforced" do
    position = create_position(asset0_amount: "1.6", target: "1.0")

    with_env(@env) do
      report = build_action(position: position, action: "open", positions: [ nil ]).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "target hedge exceeds AERODROME_MAX_SHORT_ETH"
    end
  end

  private

  class HyperliquidReadMock
    attr_reader :open_short_called, :close_short_called, :set_leverage_called

    def initialize(positions)
      @positions = positions
      @open_short_called = false
      @close_short_called = false
      @set_leverage_called = false
    end

    def get_position(asset)
      raise "USDC must not be read" if asset == "USDC"

      @positions.empty? ? nil : @positions.shift
    end

    def open_short(*)
      @open_short_called = true
      raise "open_short must not be called by dashboard action service"
    end

    def close_short(*)
      @close_short_called = true
      raise "close_short must not be called directly by dashboard action service"
    end

    def set_leverage(*)
      @set_leverage_called = true
      raise "set_leverage must not be called directly by dashboard action service"
    end
  end

  class CallRecorder
    attr_reader :calls

    def initialize
      @calls = []
    end

    def call(hedge_id)
      @calls << hedge_id
    end
  end

  class EmergencyCloseStub
    attr_reader :called

    def initialize(status:)
      @status = status
      @called = false
    end

    def report
      @called = true
      { status: @status, before_position: { asset: "ETH", size: "-0.5" }, after_position: nil }
    end
  end

  def build_action(position:, action:, positions:, execute: false, confirmation: nil, hedge_sync_runner: CallRecorder.new, emergency_close_factory: nil)
    AerodromeDashboardHedgeAction.new(
      position: position,
      action: action,
      execute: execute,
      confirmation: confirmation,
      hyperliquid_service: HyperliquidReadMock.new(positions),
      hedge_sync_runner: hedge_sync_runner,
      emergency_close_factory: emergency_close_factory,
      log_dir: @log_dir
    )
  end

  def create_position(asset0_amount: "1.25", target: "1.0", tolerance: "0.05")
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
    position = Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: asset0_amount,
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: SecureRandom.hex(4),
      pool_address: "0xpool",
      active: true
    )
    Hedge.create!(position: position, target: target, tolerance: tolerance, active: true)
    position
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size), mark_price: BigDecimal("2300") }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
