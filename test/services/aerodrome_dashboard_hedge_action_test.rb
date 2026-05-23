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

  test "ethereal live action is blocked before any Hyperliquid write path" do
    position = create_position
    runner = CallRecorder.new

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::CONFIRMATION,
        positions: [],
        hedge_sync_runner: runner,
        venue: "ethereal"
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_equal "ethereal", report.fetch(:hedge_venue)
      assert_includes report.fetch(:blockers), "Ethereal is read-only/dry-run only; live dashboard actions are only routed to Hyperliquid"
      assert_empty runner.calls
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal "ethereal_eip712_trade_order_preview", report.fetch(:hedge_venue_preview).fetch(:payload).fetch(:schema)
    end
  end

  test "nado dry-run preview returns structured payload without Hyperliquid writes" do
    position = create_position

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: false,
        positions: [],
        venue: "nado"
      ).report

      assert_equal "preview", report.fetch(:status)
      assert_equal "nado", report.fetch(:hedge_venue)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal false, report.fetch(:hedge_venue_preview).fetch(:order_submission)
      assert_equal "nado_eip712_order_preview", report.fetch(:hedge_venue_preview).fetch(:payload).fetch(:schema)
    end
  end

  test "ethereal preview on inactive position is informational and allowed" do
    position = create_position(active: false)

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: false,
        positions: [],
        venue: "ethereal"
      ).report

      assert_equal "preview", report.fetch(:status)
      assert_equal "ethereal", report.fetch(:hedge_venue)
      assert_empty report.fetch(:blockers)
      assert_includes report.fetch(:warnings), "Position is inactive; preview is informational only."
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal "ethereal_eip712_trade_order_preview", report.fetch(:hedge_venue_preview).fetch(:payload).fetch(:schema)
    end
  end

  test "nado preview on inactive position is informational and allowed" do
    position = create_position(active: false)

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: false,
        positions: [],
        venue: "nado"
      ).report

      assert_equal "preview", report.fetch(:status)
      assert_equal "nado", report.fetch(:hedge_venue)
      assert_empty report.fetch(:blockers)
      assert_includes report.fetch(:warnings), "Position is inactive; preview is informational only."
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal "nado_eip712_order_preview", report.fetch(:hedge_venue_preview).fetch(:payload).fetch(:schema)
    end
  end

  test "nado live action remains blocked for read only venue" do
    position = create_position(active: false)
    runner = CallRecorder.new

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::CONFIRMATION,
        positions: [],
        hedge_sync_runner: runner,
        venue: "nado"
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "position is inactive"
      assert_includes report.fetch(:blockers), "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true"
      assert_empty runner.calls
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "nado live action is blocked when venue live env is false" do
    position = create_mellow_position(weth_exposure: "1.09")
    runner = CallRecorder.new

    with_env(@env.merge(
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "false",
      "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO"
    )) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: "CONFIRM_NADO",
        positions: [],
        hedge_sync_runner: runner,
        venue: "nado"
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true"
      assert_empty runner.calls
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "ethereal live action is blocked without exact venue confirmation" do
    position = create_mellow_position(weth_exposure: "1.09")
    runner = CallRecorder.new

    with_env(@env.merge(
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_CONFIRMATION" => "CONFIRM_ETHEREAL"
    )) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: "wrong",
        positions: [],
        hedge_sync_runner: runner,
        venue: "ethereal"
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "submitted confirmation must equal CONFIRM_ETHEREAL"
      assert_includes report.fetch(:blockers), "Ethereal live submit adapter is not wired in delta_neutral"
      assert_empty runner.calls
    end
  end

  test "nado selected venue uses Mellow target exposure from valuation" do
    position = create_mellow_position(weth_exposure: "1.16", target: "0.95")

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: false,
        positions: [],
        venue: "nado"
      ).report

      assert_equal "preview", report.fetch(:status)
      assert_equal "1.102", report.fetch(:target_short_eth)
      assert_equal "1.102", report.fetch(:hedge_venue_live_preflight).fetch(:target_hedge_size_eth)
      assert_equal "1.102", report.fetch(:hedge_venue_preview).fetch(:requested_size_eth)
    end
  end

  test "nado live action calls Nado service with Mellow target exposure" do
    position = create_mellow_position(weth_exposure: "1.0934")
    service = NadoServiceStub.new(status: "submitted_but_readback_pending")

    with_env(@env.merge(
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO"
    )) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: "CONFIRM_NADO",
        positions: [],
        venue: "nado",
        nado_service_factory: -> { service }
      ).report

      assert_equal "submitted", report.fetch(:status)
      assert_equal BigDecimal("1.0934"), service.open_calls.first.fetch(:size_eth)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "nado manual rebalance calls Nado service with signed delta" do
    position = create_mellow_position(weth_exposure: "1.2")
    service = NadoServiceStub.new(status: "submitted_and_confirmed", read_position: { asset: "ETH", size: BigDecimal("-0.5"), mark_price: BigDecimal("2300") })

    with_env(@env.merge(
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO"
    )) do
      report = build_action(
        position: position,
        action: "rebalance",
        execute: true,
        confirmation: "CONFIRM_NADO",
        positions: [],
        venue: "nado",
        nado_service_factory: -> { service }
      ).report

      assert_equal "submitted", report.fetch(:status)
      assert_equal BigDecimal("0.7"), service.rebalance_calls.first.fetch(:delta_eth)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "nado manual close uses nado confirmation and ignores global hedge pause" do
    position = create_mellow_position(weth_exposure: "1.2")
    service = NadoServiceStub.new(status: "submitted_and_confirmed", read_position: { asset: "ETH", size: BigDecimal("-0.955"), mark_price: BigDecimal("2300"), margin_mode: "cross" })

    with_env(@env.merge(
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_CONFIRMATION" => AerodromeDashboardHedgeAction::NADO_CONFIRMATION
    )) do
      report = build_action(
        position: position,
        action: "close",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::NADO_CONFIRMATION,
        positions: [],
        venue: "nado",
        nado_service_factory: -> { service }
      ).report

      assert_equal "submitted", report.fetch(:status)
      assert_empty report.fetch(:blockers)
      assert_equal BigDecimal("0.955"), service.close_calls.first.fetch(:size_eth)
      assert_equal AerodromeDashboardHedgeAction::NADO_CONFIRMATION, service.close_calls.first.fetch(:confirmation)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "nado manual close is blocked when nado live flag is false" do
    position = create_mellow_position(weth_exposure: "1.2")
    service = NadoServiceStub.new(status: "submitted_and_confirmed", read_position: { asset: "ETH", size: BigDecimal("-0.955"), mark_price: BigDecimal("2300"), margin_mode: "cross" }, preflight_blockers: [ "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true" ])

    with_env(@env.merge(
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "false",
      "AERODROME_NADO_HEDGE_CONFIRMATION" => AerodromeDashboardHedgeAction::NADO_CONFIRMATION
    )) do
      report = build_action(
        position: position,
        action: "close",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::NADO_CONFIRMATION,
        positions: [],
        venue: "nado",
        nado_service_factory: -> { service }
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true"
      assert_empty service.close_calls
      assert_not_includes report.fetch(:blockers), "AERODROME_HEDGE_PAUSED must be false"
    end
  end

  test "hyperliquid preview still blocks inactive position" do
    position = create_position(active: false)

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: false,
        positions: [ nil ],
        venue: "hyperliquid"
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), "position is inactive"
      assert_equal "hyperliquid", report.fetch(:hedge_venue)
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

  test "live dashboard actions block when multiple active hedgeable positions exist" do
    position = create_position
    other = create_position(asset0_amount: "0.5")

    with_env(@env) do
      report = build_action(
        position: position,
        action: "open",
        execute: true,
        confirmation: AerodromeDashboardHedgeAction::CONFIRMATION,
        positions: [ nil ],
        hedge_sync_runner: CallRecorder.new
      ).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:blockers), Position::MULTIPLE_ACTIVE_HEDGEABLE_MESSAGE
    end
  ensure
    other&.destroy
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

    def initialize(status:, read_position: nil)
      @status = status
      @read_position = read_position
      @called = false
    end

    def report
      @called = true
      { status: @status, before_position: { asset: "ETH", size: "-0.5" }, after_position: nil }
    end
  end

  class NadoServiceStub
    attr_reader :open_calls, :rebalance_calls, :close_calls

    def initialize(status:, read_position: nil, preflight_blockers: [])
      @status = status
      @read_position = read_position
      @preflight_blockers = preflight_blockers
      @open_calls = []
      @rebalance_calls = []
      @close_calls = []
    end

    def preflight(*)
      { blockers: @preflight_blockers, warnings: [] }
    end

    def read_position
      @read_position
    end

    def open_short(**kwargs)
      @open_calls << kwargs
      NadoHedgeExecutionService::Result.new(@status, [], [], {
        final_status: @status,
        rounded_size_eth: kwargs.fetch(:size_eth).to_s("F"),
        submitted_order_summary: { signature: "<redacted>" }
      })
    end

    def close_short(**kwargs)
      @close_calls << kwargs
      NadoHedgeExecutionService::Result.new(@status, [], [], {
        final_status: @status,
        rounded_size_eth: kwargs.fetch(:size_eth).to_s("F"),
        submitted_order_summary: {
          signature: "<redacted>",
          side: "buy",
          reduce_only: true
        }
      })
    end

    def rebalance_short(**kwargs)
      @rebalance_calls << kwargs
      NadoHedgeExecutionService::Result.new(@status, [], [], {
        final_status: @status,
        rounded_size_eth: kwargs.fetch(:delta_eth).abs.to_s("F"),
        submitted_order_summary: {
          signature: "<redacted>",
          side: kwargs.fetch(:delta_eth).negative? ? "buy" : "sell",
          reduce_only: kwargs.fetch(:delta_eth).negative?
        }
      })
    end
  end

  def build_action(position:, action:, positions:, execute: false, confirmation: nil, hedge_sync_runner: CallRecorder.new, emergency_close_factory: nil, nado_service_factory: nil, venue: "hyperliquid")
    AerodromeDashboardHedgeAction.new(
      position: position,
      action: action,
      execute: execute,
      confirmation: confirmation,
      venue: venue,
      hyperliquid_service: HyperliquidReadMock.new(positions),
      hedge_sync_runner: hedge_sync_runner,
      emergency_close_factory: emergency_close_factory,
      nado_service_factory: nado_service_factory,
      log_dir: @log_dir
    )
  end

  def create_position(asset0_amount: "1.25", target: "1.0", tolerance: "0.05", active: true)
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
      active: active
    )
    Hedge.create!(position: position, target: target, tolerance: tolerance, active: true)
    position
  end

  def create_mellow_position(weth_exposure:, target: "1.0", tolerance: "0.05", active: true)
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
    total_value = BigDecimal(weth_exposure) * BigDecimal("2300") + BigDecimal("240")
    position = Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:#{SecureRandom.hex(4)}",
      pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: weth_exposure,
      asset1_amount: "240.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      entry_value_usd: total_value.to_s("F"),
      active: active,
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: weth_exposure,
        user_usdc_exposure: "240.0",
        user_total_value_usd: total_value.to_s("F")
      }.to_json
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
