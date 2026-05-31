require "test_helper"

class HedgeVenueAutoRebalanceOnceTest < ActiveSupport::TestCase
  test "Ethereal dry-run creates zero orders and signatures" do
    result = adapter.run(position: position, dry_run: true, live: false, confirmation: nil, max_slippage: "0.01")

    assert_equal "dry_run", result.status
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "Ethereal live one-shot requires exact confirmation" do
    result = adapter.run(position: position, dry_run: false, live: true, confirmation: "wrong", max_slippage: "0.01")

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{HedgeVenueAutoAdapters::Ethereal::CONFIRMATION}"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
  end

  test "Ethereal live one-shot submits one mocked order and confirms readback" do
    service = FakeExecutionService.new
    result = adapter(service: service).run(
      position: position,
      dry_run: false,
      live: true,
      confirmation: HedgeVenueAutoAdapters::Ethereal::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal 1, service.calls
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  test "Ethereal live one-shot blocks before submit when open orders readback is unavailable" do
    service = FakeExecutionService.new
    result = adapter(readiness: StaticReadiness.new("Ethereal open orders readback unavailable; live auto fails closed"), service: service).run(
      position: position,
      dry_run: false,
      live: true,
      confirmation: HedgeVenueAutoAdapters::Ethereal::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Ethereal open orders readback unavailable; live auto fails closed"
    assert_equal 0, service.calls
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "Nado auto dry-run builds isolated open increase preview with zero orders and signatures" do
    service = FakeNadoExecutionService.new
    result = nado_adapter(service: service).run(
      position: position("nado"),
      dry_run: true,
      live: false,
      confirmation: nil,
      max_slippage: "0.01"
    )

    assert_equal "dry_run", result.status
    assert_equal "rebalance", service.preview_call.fetch(:action)
    assert_equal BigDecimal("0.1"), service.preview_call.fetch(:size_eth)
    assert_equal "sell", result.receipt.fetch(:side)
    assert_equal false, result.receipt.fetch(:reduce_only)
    assert_equal "isolated_1x_increase", result.receipt.dig(:order_preview, :summary, :margin_mode)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "Nado auto dry-run builds reduce-only decrease preview with zero orders and signatures" do
    service = FakeNadoExecutionService.new
    result = nado_adapter(
      readiness: StaticReadiness.new(nil, planned_auto_action: "decrease_short", drift_eth: "-0.1", side: "buy", reduce_only: true),
      service: service
    ).run(
      position: position("nado"),
      dry_run: true,
      live: false,
      confirmation: nil,
      max_slippage: "0.01"
    )

    assert_equal "dry_run", result.status
    assert_equal BigDecimal("-0.1"), service.preview_call.fetch(:size_eth)
    assert_equal "buy", result.receipt.fetch(:side)
    assert_equal true, result.receipt.fetch(:reduce_only)
    assert_equal "isolated_delta_reduce_only", result.receipt.dig(:order_preview, :summary, :margin_mode)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "Nado auto live one-shot requires exact confirmation" do
    service = FakeNadoExecutionService.new
    result = nado_adapter(service: service).run(
      position: position("nado"),
      dry_run: false,
      live: true,
      confirmation: "wrong",
      max_slippage: "0.01"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_REBALANCE_ORDER"
    assert_equal 0, service.submit_calls
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "Nado auto live one-shot uses delayed reconciliation after accepted digest" do
    service = FakeNadoExecutionService.new(status: "submitted_but_readback_pending")
    result = nado_adapter(service: service).run(
      position: position("nado"),
      dry_run: false,
      live: true,
      confirmation: "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_REBALANCE_ORDER",
      max_slippage: "0.01"
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal 1, service.submit_calls
    assert_equal true, service.reconciled
    assert_equal "nado-digest-1", result.receipt.fetch(:exchange_order_id)
    assert_equal true, result.receipt.fetch(:readback_confirmed)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  private

  def adapter(readiness: StaticReadiness.new, service: FakeExecutionService.new)
    HedgeVenueAutoRebalanceAdapters::Ethereal.new(readiness: readiness, service: service)
  end

  def nado_adapter(readiness: StaticReadiness.new(nil, venue: "nado"), service: FakeNadoExecutionService.new)
    HedgeVenueAutoRebalanceAdapters::Nado.new(env: nado_env, readiness: readiness, service: service)
  end

  def nado_env
    {
      "AERODROME_NADO_HEDGE_CONFIRMATION" => "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_REBALANCE_ORDER"
    }
  end

  def position(venue = "ethereal")
    current = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    current.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: venue)
    current
  end

  class StaticReadiness
    def initialize(blocker = nil, venue: "ethereal", planned_auto_action: "increase_short", drift_eth: "0.1", side: "sell", reduce_only: false)
      @blocker = blocker
      @venue = venue
      @planned_auto_action = planned_auto_action
      @drift_eth = drift_eth
      @side = side
      @reduce_only = reduce_only
    end

    def readiness(position:)
      {
        position_id: position.id,
        venue: @venue || position.hedge.execution_venue,
        planned_auto_action: @planned_auto_action,
        current_short_eth: "0.9",
        target_short_eth: "1.0",
        drift_eth: @drift_eth,
        tolerance_eth: "0.03",
        requested_size_eth: BigDecimal(@drift_eth).abs.to_s("F"),
        side: @side,
        reduce_only: @reduce_only,
        expected_after_short_eth: "1.0",
        blockers: [ @blocker ].compact,
        warnings: []
      }
    end
  end

  class FakeExecutionService
    attr_reader :calls

    def initialize
      @calls = 0
    end

    def read_position
      { side: "short", short_size: "0.9", margin_mode: "cross" }
    end

    def rebalance_short(**)
      @calls += 1
      EtherealHedgeExecutionService::Result.new(
        "submitted_and_confirmed",
        [],
        [],
        {
          submitted: true,
          orders_placed: 1,
          signatures_created: 1,
          exchange_order_id: "eth-1",
          post_submit_readback: { short_size: "1.0", side: "short" }
        }
      )
    end
  end

  class FakeNadoExecutionService
    attr_reader :preview_call, :submit_calls
    attr_accessor :reconciled

    def initialize(status: "submitted_and_confirmed")
      @status = status
      @submit_calls = 0
      @reconciled = false
    end

    def read_position
      { side: "short", short_size: "0.9", margin_mode: "isolated", isolated_margin_usd: "900" }
    end

    def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position:)
      @preview_call = { position: position, action: action, size_eth: BigDecimal(size_eth.to_s), max_slippage: max_slippage, current_position: current_position }
      {
        ok: true,
        summary: {
          action: action,
          side: BigDecimal(size_eth.to_s).negative? ? "buy" : "sell",
          reduce_only: BigDecimal(size_eth.to_s).negative?,
          rounded_size_eth: BigDecimal(size_eth.to_s).abs.to_s("F"),
          margin_mode: BigDecimal(size_eth.to_s).negative? ? "isolated_delta_reduce_only" : "isolated_1x_increase",
          expected_after_short_eth: "1.0"
        },
        blockers: [],
        warnings: []
      }
    end

    def rebalance_short(position:, delta_eth:, current_position:, confirmation:, max_slippage:, require_confirmation:)
      @submit_calls += 1
      NadoHedgeExecutionService::Result.new(
        @status,
        [],
        [],
        {
          exchange_order_id: "nado-digest-1",
          orders_placed: 1,
          signatures_created: 1,
          post_submit_readback: @status == "submitted_and_confirmed" ? { short_size: "1.0", side: "short" } : nil,
          confirmation: confirmation,
          require_confirmation: require_confirmation
        }
      )
    end

    def reconcile_pending_result(result)
      return result unless result.status.to_s.start_with?("submitted_but")

      @reconciled = true
      NadoHedgeExecutionService::Result.new(
        "submitted_and_confirmed",
        [],
        result.warnings,
        result.receipt.merge(
          post_submit_readback: { short_size: "1.0", side: "short" },
          final_status: "submitted_and_confirmed",
          reconciled_after_pending: true
        )
      )
    end
  end
end
