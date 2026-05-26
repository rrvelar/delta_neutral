require "test_helper"

class HedgeSyncJobTest < ActiveSupport::TestCase
  include ActionMailer::TestHelper

  setup do
    ENV["HYPERLIQUID_PRIVATE_KEY"] ||= "0xtest"
    ENV["HYPERLIQUID_WALLET_ADDRESS"] ||= "0xwallet"
    ENV["HYPERLIQUID_TESTNET"] ||= "true"
  end

  private

  class NadoAutoServiceStub
    attr_reader :rebalance_calls

    def initialize(current_position:, result: nil)
      @current_position = current_position
      @rebalance_calls = []
      @result = result
    end

    def read_position
      @current_position
    end

    def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position: nil)
      {
        summary: {
          rounded_size_eth: BigDecimal(size_eth.to_s).abs.to_s("F"),
          side: BigDecimal(size_eth.to_s).negative? ? "buy" : "sell",
          reduce_only: BigDecimal(size_eth.to_s).negative?,
          estimated_notional_usd: "100"
        },
        warnings: []
      }
    end

    def plan_rebalance(target_size_eth:, current_position:, tolerance_eth:)
      current = current_short
      target = BigDecimal(target_size_eth.to_s)
      delta = target - current
      action = if delta.abs <= BigDecimal(tolerance_eth.to_s)
        "no_op"
      elsif delta.positive?
        "isolated_increase"
      elsif current_position[:margin_mode] == "isolated"
        "isolated_decrease"
      else
        "isolated_decrease"
      end
      { action: action, target_size_eth: target.to_s("F"), current_size_eth: current.to_s("F"), delta_eth: delta.to_s("F"), strategy: action == "isolated_decrease" ? "delta_only" : action, partial_isolated_reduce_supported: true }
    end

    def auto_rebalance_short(**kwargs)
      @rebalance_calls << kwargs
      return @result if @result

      delta = BigDecimal(kwargs.fetch(:delta_eth).to_s)
      old_short = current_short
      new_short = old_short + delta
      NadoHedgeExecutionService::Result.new("submitted_and_confirmed", [], [], {
        final_status: "submitted_and_confirmed",
        submitted_order_summary: {
          side: delta.negative? ? "buy" : "sell",
          reduce_only: delta.negative?,
          rounded_size_eth: delta.abs.to_s("F"),
          estimated_notional_usd: "100"
        },
        exchange_order_id: "0x#{"ab" * 32}",
        post_submit_readback: { size: -new_short.abs }
      })
    end

    def reconcile_pending_result(result)
      result
    end

    private

    def current_short
      size = BigDecimal(@current_position.fetch(:size).to_s)
      size.negative? ? size.abs : BigDecimal("0")
    end
  end

  def nado_mellow_hedge(weth_exposure: "1.2", target: "1.0", tolerance: "0.05")
    Position.update_all(active: false)
    position = aerodrome_position(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:#{SecureRandom.hex(4)}",
      asset0_amount: BigDecimal(weth_exposure),
      asset1_amount: BigDecimal("240"),
      entry_value_usd: BigDecimal(weth_exposure) * BigDecimal("2300") + BigDecimal("240"),
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: weth_exposure,
        user_usdc_exposure: "240",
        user_total_value_usd: (BigDecimal(weth_exposure) * BigDecimal("2300") + BigDecimal("240")).to_s("F")
      }.to_json
    )
    Hedge.create!(position: position, target: target, tolerance: tolerance, active: true, execution_venue: "nado")
  end

  def build_mock_service(positions:, fills: [], fills_error: nil, subaccounts: [], subaccount_states: {},
                         market_close_result: { "status" => "ok" }, market_close_error: nil,
                         market_order_result: { "status" => "ok" }, market_order_error: nil,
                         positions_after_close_error: nil, positions_after_open_error: nil,
                         market_order_calls: nil, update_leverage_calls: nil)
    user_states = {}

    # Main account state
    user_states[nil] = build_user_state(positions)

    # Subaccount states
    subaccount_states.each do |addr, state|
      user_states[addr] = build_user_state(state[:positions] || [])
    end

    service = HyperliquidService.new(private_key: "0xtest", wallet_address: "0xwallet", testnet: true)

    meta = {
      "universe" => [
        { "name" => "ETH", "szDecimals" => 4 },
        { "name" => "BTC", "szDecimals" => 5 },
        { "name" => "USDC", "szDecimals" => 2 }
      ]
    }

    mock_info = Object.new
    mock_info.define_singleton_method(:user_state) do |addr|
      user_states[addr] || user_states[nil]
    end
    mock_info.define_singleton_method(:meta) { meta }
    mock_info.define_singleton_method(:user_subaccounts) { |_| subaccounts }
    if fills_error
      mock_info.define_singleton_method(:user_fills_by_time) { |_addr, _start_time| raise fills_error }
    else
      mock_info.define_singleton_method(:user_fills_by_time) { |_addr, _start_time| fills }
    end

    build_state = method(:build_user_state)
    mock_exchange = Object.new
    mock_exchange.define_singleton_method(:market_close) do |**_|
      raise market_close_error if market_close_error

      market_close_result
    end
    mock_exchange.define_singleton_method(:market_order) do |**args|
      market_order_calls&.push(args)
      if args[:is_buy]
        user_states[nil] = build_state.call(positions_after_close_error) if market_close_error && positions_after_close_error
        raise market_close_error if market_close_error

        market_close_result
      else
        user_states[nil] = build_state.call(positions_after_open_error) if market_order_error && positions_after_open_error
        raise market_order_error if market_order_error

        market_order_result
      end
    end
    mock_exchange.define_singleton_method(:update_leverage) do |**args|
      update_leverage_calls&.push(args)
      { "status" => "ok" }
    end
    mock_exchange.define_singleton_method(:create_sub_account) { |**_| { "subAccountUser" => "0xnewsub" } }
    mock_exchange.define_singleton_method(:sub_account_transfer) { |**_| { "status" => "ok" } }

    mock_sdk = Object.new
    mock_sdk.define_singleton_method(:info) { mock_info }
    mock_sdk.define_singleton_method(:exchange) { mock_exchange }

    service.instance_variable_set(:@sdk, mock_sdk)
    service
  end

  def build_user_state(positions)
    {
      "assetPositions" => positions.map do |p|
        { "position" => { "coin" => p[:coin], "szi" => p[:szi],
                          "entryPx" => "2000", "positionValue" => "1000",
                          "marginUsed" => "100", "unrealizedPnl" => "-10",
                          "returnOnEquity" => "-0.01", "liquidationPx" => nil } }
      end,
      "marginSummary" => { "accountValue" => "10000", "totalRawUsd" => "10000" }
    }
  end

  public

  test "enqueues job without error" do
    assert_nothing_raised do
      HedgeSyncJob.perform_later
    end
  end

  test "hedge venue defaults to hyperliquid" do
    assert_equal "hyperliquid", Hedge.new.execution_venue
  end

  test "nado hedge sync does not instantiate Hyperliquid when auto gate disabled" do
    hedge = nado_mellow_hedge

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false") do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  end

  test "extended hedge sync skips without Hyperliquid or Extended order execution" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      assert_no_difference "ShortRebalance.count" do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end
  end

  test "extended hedge sync skips when readiness blocks continuous auto" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    readiness = Struct.new(:report_payload) do
      def report(position:)
        report_payload
      end
    end.new({ continuous_auto_ready: false, blockers: [ "Ethereal must be flat before Extended continuous auto" ] })

    ExtendedAutoReadiness.stub(:new, readiness) do
      ExtendedAutoRebalanceOnce.stub(:new, ->(*) { raise "ExtendedAutoRebalanceOnce should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  end

  test "extended hedge sync invokes Extended branch only when readiness passes" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    readiness = Struct.new(:report_payload) do
      def report(position:)
        report_payload
      end
    end.new({ continuous_auto_ready: true, blockers: [] })
    calls = []
    runner = Struct.new(:calls) do
      def run(position:, dry_run:, one_shot:, max_slippage:)
        calls << { position: position, dry_run: dry_run, one_shot: one_shot, max_slippage: max_slippage }
        ExtendedAutoRebalanceOnce::Result.new("no_op", [], [], { final_status: "no_op", current_short_eth: "0", target_short_eth: "0", readback_attempts: [] })
      end
    end.new(calls)

    ExtendedAutoReadiness.stub(:new, readiness) do
      ExtendedAutoRebalanceOnce.stub(:new, runner) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_equal 1, calls.size
    assert_equal false, calls.first.fetch(:dry_run)
    assert_equal false, calls.first.fetch(:one_shot)
  end

  test "nado hedge sync increases short from Mellow target and readback" do
    hedge = nado_mellow_hedge(weth_exposure: "1.2")
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" })

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
          assert_difference "ShortRebalance.count", 1 do
            HedgeSyncJob.perform_now(hedge.id)
          end
        end
      end
    end

    assert_equal BigDecimal("0.7"), service.rebalance_calls.first.fetch(:delta_eth)
    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal "nado", rebalance.venue
    assert_equal "sell", rebalance.order_side
    assert_equal false, rebalance.reduce_only
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.status
  end

  test "nado hedge sync reduces short with reduce only order" do
    hedge = nado_mellow_hedge(weth_exposure: "1.0")
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-1.4"), symbol: "ETH-PERP" })

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    assert_equal BigDecimal("-0.4"), service.rebalance_calls.first.fetch(:delta_eth)
    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal "buy", rebalance.order_side
    assert_equal true, rebalance.reduce_only
  end

  test "nado hedge sync records isolated delta reduce strategy for target decrease" do
    hedge = nado_mellow_hedge(weth_exposure: "0.8")
    result = NadoHedgeExecutionService::Result.new("submitted_and_confirmed", [], [], {
      final_status: "submitted_and_confirmed",
      final_message: "Nado execute_place_orders accepted order.",
      action_plan: {
        action: "isolated_decrease",
        strategy: "delta_only",
        current_size_eth: "0.936",
        target_size_eth: "0.8",
        delta_eth: "-0.136",
        expected_after_short_eth: "0.8"
      },
      submitted_order_summary: {
        side: "buy",
        reduce_only: true,
        rounded_size_eth: "0.136",
        estimated_notional_usd: "100",
        appendix: "2817",
        order_sender_kind: "default_1",
        delta_only: true
      },
      exchange_order_id: "0x#{"11" * 32}",
      post_submit_readback: { size: BigDecimal("-0.8") }
    })
    service = NadoAutoServiceStub.new(
      current_position: { size: BigDecimal("-0.936"), symbol: "ETH-PERP", margin_mode: "isolated" },
      result: result
    )

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_difference "ShortRebalance.count", 1 do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.status
    assert_equal "buy", rebalance.order_side
    assert_equal true, rebalance.reduce_only
    assert_equal BigDecimal("0.8"), rebalance.new_short_size
    assert_equal "0x#{"11" * 32}", rebalance.exchange_order_id
    assert_equal BigDecimal("-0.136"), service.rebalance_calls.first.fetch(:delta_eth)
  end

  test "nado hedge sync skips within tolerance" do
    hedge = nado_mellow_hedge(weth_exposure: "1.0", tolerance: "0.05")
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-0.98"), symbol: "ETH-PERP" })

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_empty service.rebalance_calls
  end

  test "nado hedge sync blocks conflicting long readback" do
    hedge = nado_mellow_hedge
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("0.2"), symbol: "ETH-PERP" })

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_difference "ShortRebalance.count", 1 do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_match "current Nado position is long", rebalance.message
    assert_empty service.rebalance_calls
  end

  test "nado hedge sync records rejected recv_time exchange response message" do
    hedge = nado_mellow_hedge(weth_exposure: "1.2")
    result = NadoHedgeExecutionService::Result.new("failed_before_submit", [], [], {
      final_status: "failed_before_submit",
      submitted_order_summary: {
        side: "sell",
        reduce_only: false,
        rounded_size_eth: "0.7",
        estimated_notional_usd: "100",
        signature: "<redacted>"
      },
      submit_response_classification: {
        status: "rejected",
        message: "Nado execute_place_orders rejected order: error_code=2012 Request received more than 100 seconds before the 'recv_time'.",
        response_summary: {
          status: "failure",
          data: [ { error_code: 2012, error: "Request received more than 100 seconds before the 'recv_time'." } ]
        }
      },
      raw_submit_response_summary: {
        status: "failure",
        data: [ { error_code: 2012, error: "Request received more than 100 seconds before the 'recv_time'." } ]
      },
      exchange_order_id: nil,
      post_submit_readback: nil
    })
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" }, result: result)

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_difference "ShortRebalance.count", 1 do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_match "Nado execute_place_orders rejected order", rebalance.message
    assert_match "error_code=2012", rebalance.message
    assert_match "more than 100 seconds", rebalance.message
    assert_nil rebalance.exchange_order_id
    assert_no_match(/signature|private/i, rebalance.message)
  end

  test "nado hedge sync records accepted submit without confirmed readback as pending" do
    hedge = nado_mellow_hedge(weth_exposure: "1.2")
    result = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      final_status: "submitted_but_readback_pending",
      final_message: "Nado submit accepted but readback did not confirm ETH-PERP position.",
      submitted_order_summary: {
        side: "sell",
        reduce_only: false,
        rounded_size_eth: "0.7",
        estimated_notional_usd: "100",
        signature: "<redacted>"
      },
      submit_response_classification: {
        status: "submitted",
        message: "Nado execute_place_orders accepted order."
      },
      exchange_order_id: "0x#{"28" * 32}",
      post_submit_readback_poll_attempts: [
        { attempt: 1, position_present: false, confirmed: false },
        { attempt: 2, position_present: false, confirmed: false },
        { attempt: 3, position_present: false, confirmed: false }
      ],
      post_submit_readback: nil
    })
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" }, result: result)

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_difference "ShortRebalance.count", 1 do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = hedge.short_rebalances.order(:id).last
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.new_short_size
    assert_equal "0x#{"28" * 32}", rebalance.exchange_order_id
    assert_match "readback did not confirm", rebalance.message
  end

  test "nado hedge sync reconciles pending rebalances before auto gate" do
    hedge = nado_mellow_hedge(weth_exposure: "1.2")
    receipt_path = Rails.root.join("tmp", "nado-pending-sync-#{SecureRandom.hex(6)}.jsonl")
    exchange_order_id = "0x#{"29" * 32}"
    File.write(receipt_path, "#{JSON.generate({
      venue: "nado",
      hedge_id: hedge.id,
      exchange_order_id: exchange_order_id,
      action_plan: { expected_after_short_eth: "0.7", delta_eth: "0.2" }
    })}\n")
    pending = hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0.5",
      new_short_size: "0.5",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_PENDING,
      message: "Nado submit accepted but readback did not confirm ETH-PERP position.",
      rebalanced_at: 5.minutes.ago,
      venue: "nado",
      order_side: "sell",
      reduce_only: false,
      exchange_order_id: exchange_order_id,
      receipt_path: receipt_path.to_s
    )
    service = NadoAutoServiceStub.new(current_position: { size: BigDecimal("-0.7"), symbol: "ETH-PERP" })

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false") do
      NadoHedgeExecutionService.stub(:new, service) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_equal ShortRebalance::STATUS_SUCCESS, pending.reload.status
    assert_equal BigDecimal("0.7"), pending.new_short_size
    assert_equal "Confirmed by later Nado readback", pending.message
  end

  test "creates rebalance records with realized PnL from fills" do
    hedge = hedges(:eth_hedge)

    close_fills = [
      { "coin" => "ETH", "closedPnl" => "-8.50", "px" => "2010", "sz" => "0.3", "side" => "B", "time" => Time.current.to_i * 1000 }
    ]

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-1.0" } ],
      fills: close_fills
    )

    assert_difference "ShortRebalance.count", 2 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    weth_rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal BigDecimal("-8.50"), weth_rebalance.realized_pnl
  end

  test "realized PnL defaults to zero when fills fetch fails" do
    hedge = hedges(:eth_hedge)

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-1.0" } ],
      fills_error: Hyperliquid::NetworkError.new("connection refused")
    )

    assert_difference "ShortRebalance.count", 2 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    weth_rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal BigDecimal("0"), weth_rebalance.realized_pnl
  end

  test "skips order when rounded target equals current short despite raw tolerance deviation" do
    hedge = hedges(:eth_hedge)
    hedge.update!(tolerance: "0.0001")
    hedge.position.update!(asset0_amount: BigDecimal("0.023219"), asset1_amount: BigDecimal("0"))
    market_order_calls = []
    update_leverage_calls = []

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.0116" } ],
      market_order_calls: market_order_calls,
      update_leverage_calls: update_leverage_calls
    )

    assert hedge.needs_rebalance?(hedge.position.asset0_amount, BigDecimal("0.0116"))
    assert_no_emails do
      assert_no_difference "ShortRebalance.count" do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_empty market_order_calls
    assert_empty update_leverage_calls
  end

  test "rebalances when rounded target differs from current short" do
    hedge = hedges(:eth_hedge)
    hedge.update!(tolerance: "0.0001")
    hedge.position.update!(asset0_amount: BigDecimal("0.0234"), asset1_amount: BigDecimal("0"))
    market_order_calls = []
    update_leverage_calls = []

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.0116" } ],
      market_order_calls: market_order_calls,
      update_leverage_calls: update_leverage_calls
    )

    assert_difference "ShortRebalance.count", 1 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal BigDecimal("0.0116"), rebalance.old_short_size
    assert_equal BigDecimal("0.0117"), rebalance.new_short_size
    assert_equal 1, market_order_calls.size
    assert_equal false, market_order_calls.first[:is_buy]
    assert_equal BigDecimal("0.0001"), market_order_calls.first[:size]
    assert_equal 1, update_leverage_calls.size
  end

  test "current zero to target opens target size only" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))
    market_order_calls = []

    mock_service = build_mock_service(
      positions: [],
      market_order_calls: market_order_calls
    )

    assert_difference "ShortRebalance.count", 1 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    assert_equal 1, market_order_calls.size
    assert_equal false, market_order_calls.first[:is_buy]
    assert_equal BigDecimal("0.5"), market_order_calls.first[:size]
  end

  test "larger target increases short by delta only" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))
    market_order_calls = []

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.25" } ],
      market_order_calls: market_order_calls
    )

    assert_difference "ShortRebalance.count", 1 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    assert_equal 1, market_order_calls.size
    assert_equal false, market_order_calls.first[:is_buy]
    assert_equal BigDecimal("0.25"), market_order_calls.first[:size]
  end

  test "smaller target reduces short by delta only" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))
    market_order_calls = []

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.75" } ],
      market_order_calls: market_order_calls
    )

    assert_difference "ShortRebalance.count", 1 do
      HyperliquidService.stub(:new, mock_service) do
        HedgeSyncJob.perform_now(hedge.id)
      end
    end

    assert_equal 1, market_order_calls.size
    assert_equal true, market_order_calls.first[:is_buy]
    assert_equal BigDecimal("0.25"), market_order_calls.first[:size]
  end

  test "closes over-hedged short and notifies when pool amount is zero" do
    hedge = hedges(:eth_hedge)
    # Both pool amounts zero: position is fully out of range on both sides.
    # WETH has an open short (over-hedged); USDC has none (nothing to close).
    # Only the WETH asset produces a rebalance record; hedge stays active so
    # the sibling short and future re-entries are handled normally.
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    close_fills = [
      { "coin" => "ETH", "closedPnl" => "-12.00", "px" => "1900", "sz" => "0.5", "side" => "B", "time" => Time.current.to_i * 1000 }
    ]

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      fills: close_fills
    )

    assert_emails 1 do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0"), rebalance.new_short_size
    assert_equal BigDecimal("-12.00"), rebalance.realized_pnl

    hedge.reload
    assert hedge.active?, "hedge should remain active to manage sibling asset and handle re-entry"
  end

  test "target zero close path passes current short size to close_short" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    market_order_calls = []
    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_order_calls: market_order_calls
    )

    HyperliquidService.stub(:new, mock_service) do
      HedgeSyncJob.perform_now(hedge.id)
    end

    close_order = market_order_calls.find { |args| args[:is_buy] == true }
    assert_not_nil close_order
    assert_equal "ETH", close_order[:coin]
    assert_equal BigDecimal("0.5"), close_order[:size]
    assert_equal [ close_order ], market_order_calls
  end

  test "close short returning nil records failed rebalance instead of success" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_close_result: nil
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0.5"), rebalance.new_short_size
    assert_match "returned nil", rebalance.message
  end

  test "close short raising records failed rebalance instead of success" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_close_error: HyperliquidService::OrderError.new("close rejected")
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0.5"), rebalance.new_short_size
    assert_match "close rejected", rebalance.message
  end

  test "close short network error reconciles success when position is gone afterwards" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_close_error: Hyperliquid::NetworkError.new("SSL_read: unexpected eof while reading"),
      positions_after_close_error: []
    )

    assert_emails 1 do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0"), rebalance.new_short_size
    assert_match "Reconciled after ambiguous order error", rebalance.message
  end

  test "close short network error records failure with actual size when position remains" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_close_error: Hyperliquid::NetworkError.new("SSL_read: unexpected eof while reading"),
      positions_after_close_error: [ { coin: "ETH", szi: "-0.4" } ]
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0.4"), rebalance.new_short_size
    assert_match "SSL_read", rebalance.message
  end

  test "open short network error reconciles success when position reaches target" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [],
      market_order_error: Hyperliquid::NetworkError.new("SSL_read: unexpected eof while reading"),
      positions_after_open_error: [ { coin: "ETH", szi: "-0.5" } ]
    )

    assert_emails 1 do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.status
    assert_equal BigDecimal("0"), rebalance.old_short_size
    assert_equal BigDecimal("0.5"), rebalance.new_short_size
    assert_match "Reconciled after ambiguous order error", rebalance.message
  end

  test "open short network error records failure with actual size when position remains zero" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))

    mock_service = build_mock_service(
      positions: [],
      market_order_error: Hyperliquid::NetworkError.new("SSL_read: unexpected eof while reading"),
      positions_after_open_error: []
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0"), rebalance.old_short_size
    assert_equal BigDecimal("0"), rebalance.new_short_size
    assert_match "SSL_read", rebalance.message
  end

  test "explicit API rejection remains failed without reconciled success" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("1.0"), asset1_amount: BigDecimal("0"))
    rejected_order = {
      "status" => "ok",
      "response" => {
        "data" => {
          "statuses" => [
            { "error" => "Order must have minimum value of $10" }
          ]
        }
      }
    }

    mock_service = build_mock_service(
      positions: [],
      market_order_result: rejected_order,
      positions_after_open_error: [ { coin: "ETH", szi: "-0.5" } ]
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0"), rebalance.new_short_size
    assert_match "minimum value", rebalance.message
  end

  test "close short rejected response records failed rebalance instead of success" do
    hedge = hedges(:eth_hedge)
    hedge.position.update!(asset0_amount: BigDecimal("0"), asset1_amount: BigDecimal("0"))

    rejected_close = {
      "status" => "ok",
      "response" => {
        "data" => {
          "statuses" => [
            { "error" => "No open position found for ETH" }
          ]
        }
      }
    }
    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_close_result: rejected_close
    )

    assert_no_emails do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalance = ShortRebalance.where(asset: "WETH").order(:id).last
    assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
    assert_equal BigDecimal("0.5"), rebalance.old_short_size
    assert_equal BigDecimal("0.5"), rebalance.new_short_size
    assert_match "No open position found", rebalance.message
  end

  test "allocates subaccount when main account is in use for same asset" do
    hedge = hedges(:eth_hedge)

    # Create a second position+hedge that also uses WETH, already on main account
    position2 = Position.create!(
      user: hedge.position.user,
      dex: hedge.position.dex,
      wallet: hedge.position.wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "2.0",
      asset1_amount: "4000.0",
      asset0_price_usd: "2000.0",
      asset1_price_usd: "1.0",
      external_id: "99999",
      pool_address: "0xpool9999",
      active: true
    )
    hedge2 = Hedge.create!(
      position: position2,
      target: "0.5",
      tolerance: "0.05",
      active: true
    )
    # hedge2 has no hl_account columns set → it's on main for both assets
    # When hedge (eth_hedge) syncs, it should detect main is taken for ETH and allocate a subaccount

    mock_service = build_mock_service(
      positions: [],
      subaccounts: [ { "subAccountUser" => "0xexistingsub" } ]
    )

    HyperliquidService.stub(:new, mock_service) do
      HedgeSyncJob.perform_now(hedge.id)
    end

    hedge.reload
    assert_equal "0xexistingsub", hedge.asset0_hl_account
    # hedge2 also claims main for USDC (asset1), so hedge gets subaccount for both
    assert_equal "0xexistingsub", hedge.asset1_hl_account
  ensure
    hedge2&.destroy
    position2&.destroy
  end

  test "creates new subaccount when all existing subaccounts are in use" do
    hedge = hedges(:eth_hedge)

    # Another hedge already on main for ETH
    position2 = Position.create!(
      user: hedge.position.user,
      dex: hedge.position.dex,
      wallet: hedge.position.wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "2.0",
      asset1_amount: "4000.0",
      asset0_price_usd: "2000.0",
      asset1_price_usd: "1.0",
      external_id: "88888",
      pool_address: "0xpool8888",
      active: true
    )
    hedge2 = Hedge.create!(position: position2, target: "0.5", tolerance: "0.05", active: true)

    # Third hedge on subaccount 0xsub1 for ETH
    position3 = Position.create!(
      user: hedge.position.user,
      dex: hedge.position.dex,
      wallet: hedge.position.wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.0",
      asset1_amount: "2000.0",
      asset0_price_usd: "2000.0",
      asset1_price_usd: "1.0",
      external_id: "77777",
      pool_address: "0xpool7777",
      active: true
    )
    hedge3 = Hedge.create!(position: position3, target: "0.5", tolerance: "0.05", active: true, asset0_hl_account: "0xsub1")

    mock_service = build_mock_service(
      positions: [],
      subaccounts: [ { "subAccountUser" => "0xsub1" } ]
    )

    HyperliquidService.stub(:new, mock_service) do
      HedgeSyncJob.perform_now(hedge.id)
    end

    hedge.reload
    # 0xsub1 is taken by hedge3, main is taken by hedge2 → should create new
    assert_equal "0xnewsub", hedge.asset0_hl_account
  ensure
    hedge3&.destroy
    position3&.destroy
    hedge2&.destroy
    position2&.destroy
  end

  test "skips Aerodrome monitor-only positions without calling HyperliquidService when flag is false" do
    position = Position.create!(
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
      asset0: "AERO",
      asset1: "WETH",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("0.5"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "5016",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "false") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "treats missing Aerodrome hedge flag as false" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => nil) do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "skips Aerodrome hedge when flag is true but amount or price data is missing" do
    position = aerodrome_position(asset0_amount: nil, asset1_price_usd: nil)
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "missing Aerodrome hedge paused flag blocks before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => nil, "HYPERLIQUID_TESTNET" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome hedge paused flag blocks before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "true", "HYPERLIQUID_TESTNET" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome hedge paused false allows next safety gates" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_SHORT_ETH" => "0.1") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome max short ETH exceeded blocks before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_SHORT_ETH" => "0.1") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome max short notional exceeded blocks before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_SHORT_NOTIONAL_USD" => "100") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome max leverage exceeded blocks before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    users(:one).setting.update!(hyperliquid_leverage: 2)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_LEVERAGE" => "1") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    users(:one).setting.update!(hyperliquid_leverage: 3)
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome tiny delta below minimum notional skips without order or rebalance" do
    position = aerodrome_position(asset0_amount: BigDecimal("1.008"))
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.0001", active: true)
    market_order_calls = []
    update_leverage_calls = []
    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_order_calls: market_order_calls,
      update_leverage_calls: update_leverage_calls
    )

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MIN_ORDER_NOTIONAL_USD" => nil) do
      assert_no_difference "ShortRebalance.count" do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_empty market_order_calls
    assert_empty update_leverage_calls
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome tiny delta below minimum notional does not increment failed streak" do
    position = aerodrome_position(asset0_amount: BigDecimal("1.008"))
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.0001", active: true)
    create_rebalance!(hedge, status: ShortRebalance::STATUS_FAILED)
    create_rebalance!(hedge, status: ShortRebalance::STATUS_FAILED)
    mock_service = build_mock_service(positions: [ { coin: "ETH", szi: "-0.5" } ])

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MIN_ORDER_NOTIONAL_USD" => "10") do
      assert_no_difference "hedge.short_rebalances.count" do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_equal 2, hedge.short_rebalances.where(status: ShortRebalance::STATUS_FAILED).count
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome invalid minimum notional skips safely without order or rebalance" do
    position = aerodrome_position(asset0_amount: BigDecimal("1.02"))
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.0001", active: true)
    market_order_calls = []
    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_order_calls: market_order_calls
    )

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MIN_ORDER_NOTIONAL_USD" => "not-a-number") do
      assert_no_difference "ShortRebalance.count" do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_empty market_order_calls
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome close to zero bypasses failed rebalance circuit breaker" do
    position = aerodrome_position(asset0_amount: BigDecimal("0"))
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    3.times { create_rebalance!(hedge, status: ShortRebalance::STATUS_FAILED) }
    market_order_calls = []
    mock_service = build_mock_service(
      positions: [ { coin: "ETH", szi: "-0.5" } ],
      market_order_calls: market_order_calls
    )

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true") do
      assert_difference "hedge.short_rebalances.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    close_order = market_order_calls.find { |args| args[:is_buy] == true }
    assert_not_nil close_order
    assert_equal BigDecimal("0.5"), close_order[:size]
    assert_equal ShortRebalance::STATUS_SUCCESS, hedge.short_rebalances.order(:id).last.status
    assert_equal BigDecimal("0"), hedge.short_rebalances.order(:id).last.new_short_size
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "skips Aerodrome hedge when flag is true but Hyperliquid testnet is false" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "false") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "missing Aerodrome live approval blocks mainnet before HyperliquidService" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => nil) do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome live approval true on mainnet allows later gates" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    mock_service = build_mock_service(positions: [])
    users(:one).setting.update!(hyperliquid_leverage: 1)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "true", "AERODROME_MAX_SHORT_ETH" => "1", "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2000", "AERODROME_MAX_LEVERAGE" => "1") do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_equal [ "WETH" ], hedge.short_rebalances.order(:id).pluck(:asset)
  ensure
    users(:one).setting.update!(hyperliquid_leverage: 3)
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome hedge paused blocks mainnet even when live approved" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "true", "HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "Aerodrome hedge disabled blocks mainnet even when live approved" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "false", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "skips Aerodrome hedge when flag is true but Hyperliquid testnet is missing" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => nil) do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "processes only Aerodrome WETH side through existing rebalance path when flag is true" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    mock_service = build_mock_service(positions: [])
    users(:one).setting.update!(hyperliquid_leverage: 1)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_SHORT_ETH" => "1", "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2000", "AERODROME_MAX_LEVERAGE" => "1") do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    rebalances = hedge.short_rebalances.order(:id)
    assert_equal [ "WETH" ], rebalances.pluck(:asset)
    assert_equal [ ShortRebalance::STATUS_SUCCESS ], rebalances.pluck(:status)
    assert_empty hedge.short_rebalances.where(asset: "USDC")
  ensure
    users(:one).setting.update!(hyperliquid_leverage: 3)
    hedge&.destroy
    position&.destroy
  end

  test "processes Aerodrome ETH symbol as ETH hedge side when flag is true" do
    position = aerodrome_position(asset0: "ETH")
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    mock_service = build_mock_service(positions: [])

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true", "AERODROME_MAX_SHORT_ETH" => nil, "AERODROME_MAX_SHORT_NOTIONAL_USD" => nil, "AERODROME_MAX_LEVERAGE" => nil) do
      assert_difference "ShortRebalance.count", 1 do
        HyperliquidService.stub(:new, mock_service) do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end

    assert_equal [ "ETH" ], hedge.short_rebalances.order(:id).pluck(:asset)
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "skips unsupported Aerodrome assets before HyperliquidService when flag is true" do
    position = aerodrome_position(asset0: "AERO", asset1: "USDC")
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    hedge&.destroy
    position&.destroy
  end

  test "blocks Aerodrome live sync when multiple active hedgeable positions exist" do
    position = aerodrome_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true)
    other_position = aerodrome_position(external_id: "315986")
    other_hedge = Hedge.create!(position: other_position, target: "1.0", tolerance: "0.03", active: true)

    with_env("AERODROME_HEDGE_ENABLED" => "true", "AERODROME_HEDGE_PAUSED" => "false", "HYPERLIQUID_TESTNET" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        assert_no_difference "ShortRebalance.count" do
          HedgeSyncJob.perform_now(hedge.id)
        end
      end
    end
  ensure
    other_hedge&.destroy
    other_position&.destroy
    hedge&.destroy
    position&.destroy
  end

  test "does not process Aerodrome hedge proposals" do
    position = Position.create!(
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
    proposal = position.aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: AerodromeHedgePreview::SOURCE,
      generated_at: Time.current
    )
    Hedge.update_all(active: false)

    HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
      assert_no_difference "ShortRebalance.count" do
        assert_no_difference "Hedge.count" do
          HedgeSyncJob.perform_now
        end
      end
    end

    assert_equal "draft", proposal.reload.status
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  ensure
    proposal&.destroy
    position&.destroy
  end

  private

  def aerodrome_position(overrides = {})
    Position.create!({
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    }.merge(overrides))
  end

  def create_rebalance!(hedge, attributes = {})
    hedge.short_rebalances.create!({
      asset: "WETH",
      old_short_size: BigDecimal("0.5"),
      new_short_size: BigDecimal("0.51"),
      realized_pnl: BigDecimal("0"),
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
    }.merge(attributes))
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
