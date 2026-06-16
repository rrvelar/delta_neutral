require "test_helper"

class ActiveVenueOneShotRebalanceTest < ActiveSupport::TestCase
  test "recovers submitted pending readback when direct market becomes safe" do
    service = service(
      preflights: [
        preflight(shorts: { "ethereal" => "1.65" }, inside: false, blockers: outside_tolerance_blocker),
        preflight(shorts: { "ethereal" => "1.76" }, inside: false),
        preflight(shorts: { "ethereal" => "1.71" }, inside: true)
      ],
      rebalancer: FakeRebalancer.new(status: "submitted_but_readback_pending", receipt: submit_receipt)
    )

    payload = service.run(reason: "hold_monitor")

    assert_empty payload.fetch(:blockers)
    assert_equal "recovered_after_rebalance_readback", payload.fetch(:reason)
    assert_equal true, payload.fetch(:active_rebalance_recovered)
    assert_equal 2, payload.fetch(:active_rebalance_recheck_attempts)
    assert_equal true, payload.fetch(:final_direct_inside_tolerance)
    assert_equal true, payload.fetch(:final_direct_open_orders_zero)
    assert_nil payload.fetch(:terminal_reason)
  end

  test "terminal outside tolerance after bounded submitted pending readback rechecks" do
    payload = service(
      preflights: [
        preflight(shorts: { "ethereal" => "1.65" }, inside: false, blockers: outside_tolerance_blocker),
        preflight(shorts: { "ethereal" => "1.76" }, inside: false),
        preflight(shorts: { "ethereal" => "1.77" }, inside: false)
      ],
      rebalancer: FakeRebalancer.new(status: "submitted_but_readback_pending", receipt: submit_receipt)
    ).run(reason: "hold_monitor")

    assert_includes payload.fetch(:blockers), "active venue one-shot rebalance final readback is outside tolerance"
    assert_equal false, payload.fetch(:active_rebalance_recovered)
    assert_equal 2, payload.fetch(:active_rebalance_recheck_attempts)
    assert_equal false, payload.fetch(:final_direct_inside_tolerance)
    assert_equal "final_direct_outside_tolerance", payload.fetch(:terminal_reason)
  end

  test "terminal open orders nonzero after submitted pending readback rechecks" do
    payload = service(
      preflights: [
        preflight(shorts: { "ethereal" => "1.65" }, inside: false, blockers: outside_tolerance_blocker),
        preflight(shorts: { "ethereal" => "1.71" }, inside: true, open_orders_status: "nonzero"),
        preflight(shorts: { "ethereal" => "1.71" }, inside: true, open_orders_status: "nonzero")
      ],
      rebalancer: FakeRebalancer.new(status: "submitted_but_readback_pending", receipt: submit_receipt)
    ).run(reason: "hold_monitor")

    assert_includes payload.fetch(:blockers), "active venue one-shot rebalance final open orders are not zero"
    assert_equal false, payload.fetch(:final_direct_open_orders_zero)
    assert_equal "open_orders_nonzero_or_unknown", payload.fetch(:terminal_reason)
  end

  test "terminal multiple active venues after submitted pending readback rechecks" do
    payload = service(
      preflights: [
        preflight(shorts: { "ethereal" => "1.65" }, inside: false, blockers: outside_tolerance_blocker),
        preflight(shorts: { "ethereal" => "1.0", "nado" => "0.71" }, inside: true),
        preflight(shorts: { "ethereal" => "1.0", "nado" => "0.71" }, inside: true)
      ],
      rebalancer: FakeRebalancer.new(status: "submitted_but_readback_pending", receipt: submit_receipt)
    ).run(reason: "hold_monitor")

    assert_equal false, payload.fetch(:active_rebalance_recovered)
    assert_match(/final exposure is not isolated/, payload.fetch(:blockers).join(" "))
    assert_equal "multiple_or_missing_active_venues", payload.fetch(:terminal_reason)
  end

  test "zero-submit pending status does not enter submitted readback recovery" do
    payload = service(
      preflights: [
        preflight(shorts: { "ethereal" => "1.65" }, inside: false, blockers: outside_tolerance_blocker),
        preflight(shorts: { "ethereal" => "1.71" }, inside: true)
      ],
      rebalancer: FakeRebalancer.new(
        status: "submitted_but_readback_pending",
        receipt: submit_receipt.merge(orders_submitted: 0, orders_placed: 0, signatures_created: 0, exchange_order_id: nil)
      )
    ).run(reason: "hold_monitor")

    assert_includes payload.fetch(:blockers), "active venue one-shot rebalance status is submitted_but_readback_pending"
    assert_equal false, payload.fetch(:active_rebalance_recovered)
    assert_equal 0, payload.fetch(:active_rebalance_recheck_attempts)
    assert_equal "active_rebalance_unconfirmed", payload.fetch(:terminal_reason)
  end

  private

  def service(preflights:, rebalancer:)
    reports = preflights.dup
    ActiveVenueOneShotRebalance.new(
      position: position,
      live: true,
      preflight_factory: ->(position:, stage:) { reports.shift || preflights.last },
      rebalancer: rebalancer,
      recheck_attempts: 2,
      recheck_interval_seconds: 0,
      sleeper: ->(_seconds) { }
    )
  end

  def position
    @position ||= Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.71",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    ).tap do |created|
      created.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
    end
  end

  def preflight(shorts:, inside:, blockers: [], open_orders_status: "zero")
    venues = ActiveVenueOneShotRebalance::VENUES.to_h do |venue|
      [ venue, { short_eth: BigDecimal(shorts.fetch(venue, "0")), open_orders_status: open_orders_status, open_orders_count: open_orders_status == "zero" ? 0 : 1 } ]
    end
    combined = venues.values.sum(BigDecimal("0")) { |payload| payload.fetch(:short_eth) }
    {
      production_venue: "ethereal",
      target: { target_short_eth: BigDecimal("1.71") },
      venues: venues,
      active_short_venues: venues.select { |_venue, payload| payload.fetch(:short_eth).positive? }.keys,
      combined_short_eth: combined,
      drift_eth: BigDecimal("1.71") - combined,
      tolerance_abs_eth: BigDecimal("0.0513"),
      inside_tolerance: inside,
      blockers: blockers,
      warnings: []
    }
  end

  def outside_tolerance_blocker
    [ "current hedge outside tolerance: target_short_eth=1.71 current_short_eth=1.65" ]
  end

  def submit_receipt
    {
      final_status: "REBALANCE_REQUIRES_RECHECK",
      planned_auto_action: "increase_short",
      requested_size_eth: "0.06",
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "ethereal-order-1"
    }
  end

  class FakeRebalancer
    def initialize(status:, receipt:)
      @status = status
      @receipt = receipt
    end

    def run(**)
      HedgeVenueAutoRebalanceOnce::Result.new(@status, [], [], @receipt)
    end
  end
end
