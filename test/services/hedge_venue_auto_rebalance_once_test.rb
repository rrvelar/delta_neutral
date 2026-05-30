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

  test "Nado one-shot cannot submit while capabilities are missing" do
    result = HedgeVenueAutoRebalanceAdapters::Nado.new(readiness: StaticReadiness.new("nado blocker")).run(
      position: position("nado"),
      dry_run: false,
      live: true,
      confirmation: "anything",
      max_slippage: "0.01"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "nado blocker"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
  end

  private

  def adapter(readiness: StaticReadiness.new, service: FakeExecutionService.new)
    HedgeVenueAutoRebalanceAdapters::Ethereal.new(readiness: readiness, service: service)
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
    def initialize(blocker = nil)
      @blocker = blocker
    end

    def readiness(position:)
      {
        position_id: position.id,
        venue: position.hedge.execution_venue,
        planned_auto_action: "increase_short",
        current_short_eth: "0.9",
        target_short_eth: "1.0",
        drift_eth: "0.1",
        tolerance_eth: "0.03",
        requested_size_eth: "0.1",
        side: "sell",
        reduce_only: false,
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
end
