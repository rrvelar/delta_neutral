require "test_helper"

class NadoPendingRebalanceReconcilerTest < ActiveSupport::TestCase
  class ReadOnlyNadoService
    attr_reader :read_calls

    def initialize(position)
      @position = position
      @read_calls = 0
    end

    def read_position
      @read_calls += 1
      @position
    end
  end

  test "pending Nado increase reconciles to success when readback matches expected short" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "-0.7")

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal 1, service.read_calls
    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal BigDecimal("0.7"), rebalance.new_short_size
    assert_equal "Confirmed by later Nado readback", rebalance.message
    assert_equal "0x#{"28" * 32}", rebalance.exchange_order_id
  end

  test "pending Nado decrease reconciles to success when readback matches expected short" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.936", expected_short: "0.804", side: "buy")
    service = ReadOnlyNadoService.new(size: "-0.804")

    NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal ShortRebalance::STATUS_SUCCESS, rebalance.reload.status
    assert_equal BigDecimal("0.804"), rebalance.new_short_size
    assert_equal true, rebalance.reduce_only
  end

  test "pending remains pending when readback is missing" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(:unavailable)

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_nil result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
    assert_match "readback did not confirm", rebalance.message
  end

  test "pending remains pending with manual action message when readback conflicts" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "0.2")

    result = NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)

    assert_equal rebalance, result
    assert_equal ShortRebalance::STATUS_PENDING, rebalance.reload.status
    assert_match "long ETH-PERP", rebalance.message
  end

  test "reconcile path submits no orders and creates no signatures" do
    hedge = nado_hedge
    rebalance = pending_rebalance(hedge, old_short: "0.5", expected_short: "0.7", side: "sell")
    service = ReadOnlyNadoService.new(size: "-0.7")

    assert_no_difference "ShortRebalance.count" do
      NadoPendingRebalanceReconciler.new(service: service).reconcile(rebalance)
    end

    assert_equal 1, service.read_calls
  end

  test "stale pending dry run reports candidate without changing row" do
    hedge = nado_hedge
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "1.0",
      new_short_size: "1.2",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      message: "newer success",
      rebalanced_at: 1.hour.ago,
      venue: "nado",
      created_at: 1.hour.ago
    )
    pending = pending_rebalance(hedge, old_short: "0.483", expected_short: "0.483", side: "sell")
    pending.update!(created_at: 8.days.ago, updated_at: 8.days.ago, rebalanced_at: 8.days.ago)
    hedge.position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      production_venue: "nado",
      target_short_eth: "1.2",
      tolerance_abs_eth: "0.04",
      combined_short_eth: "1.2",
      inside_tolerance: true
    )
    resolver = NadoStalePendingRebalanceResolver.new(nado_venue: NadoVenueStub.new(short: "1.2", open_orders_count: 0))

    result = resolver.report(position: hedge.position, dry_run: true)

    assert_equal "dry_run", result.status
    assert_equal ShortRebalance::STATUS_PENDING, pending.reload.status
    assert_equal 1, result.receipt.fetch(:stale_candidates_count)
    assert_equal pending.id, result.receipt.fetch(:would_update).first.fetch(:id)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "stale pending acknowledgement requires exact confirmation" do
    hedge = stale_pending_hedge
    resolver = NadoStalePendingRebalanceResolver.new(nado_venue: NadoVenueStub.new(short: "1.2", open_orders_count: 0))

    result = resolver.report(position: hedge.position, dry_run: false, confirmation: "wrong")

    assert_equal "blocked", result.status
    assert_includes result.blockers, "confirmation must equal #{NadoStalePendingRebalanceResolver::CONFIRMATION}"
    assert_equal 1, hedge.short_rebalances.where(status: ShortRebalance::STATUS_PENDING).count
  end

  test "confirmed stale pending acknowledgement marks rows stale superseded" do
    hedge = stale_pending_hedge
    pending = hedge.short_rebalances.where(status: ShortRebalance::STATUS_PENDING).first
    resolver = NadoStalePendingRebalanceResolver.new(nado_venue: NadoVenueStub.new(short: "1.2", open_orders_count: 0))

    result = resolver.report(position: hedge.position, dry_run: false, confirmation: NadoStalePendingRebalanceResolver::CONFIRMATION)

    assert_equal "applied", result.status
    assert_equal ShortRebalance::STATUS_STALE_SUPERSEDED, pending.reload.status
    assert_match "Nado stale pending acknowledged", pending.message
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "old pending without newer success is not a stale candidate" do
    hedge = nado_hedge
    pending = pending_rebalance(hedge, old_short: "0.483", expected_short: "0.483", side: "sell")
    pending.update!(created_at: 8.days.ago, updated_at: 8.days.ago, rebalanced_at: 8.days.ago)
    hedge.position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      production_venue: "nado",
      target_short_eth: "1.2",
      tolerance_abs_eth: "0.04",
      combined_short_eth: "1.2",
      inside_tolerance: true
    )
    resolver = NadoStalePendingRebalanceResolver.new(nado_venue: NadoVenueStub.new(short: "1.2", open_orders_count: 0))

    result = resolver.report(position: hedge.position, dry_run: true)

    assert_equal 0, result.receipt.fetch(:stale_candidates_count)
    assert_equal 1, result.receipt.fetch(:blocking_pending_count)
  end

  private

  class NadoVenueStub
    def initialize(short:, open_orders_count:)
      @short = BigDecimal(short.to_s)
      @open_orders_count = open_orders_count
    end

    def read_position(symbol:)
      { short_size: @short.to_s("F"), size: -@short }
    end

    def account_state
      { open_orders_count: @open_orders_count }
    end
  end

  def nado_hedge
    Position.update_all(active: false)
    position = Position.create!(
      user: users(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:#{SecureRandom.hex(4)}",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.0"),
      asset1_amount: BigDecimal("240"),
      asset0_price_usd: BigDecimal("2300"),
      asset1_price_usd: BigDecimal("1"),
      entry_value_usd: BigDecimal("2540"),
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true,
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: "1.0",
        user_usdc_exposure: "240",
        user_total_value_usd: "2540"
      }.to_json
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
  end

  def pending_rebalance(hedge, old_short:, expected_short:, side:)
    exchange_order_id = "0x#{"28" * 32}"
    path = Rails.root.join("tmp", "test-nado-pending-#{SecureRandom.hex(6)}.jsonl")
    receipt = {
      venue: "nado",
      hedge_id: hedge.id,
      exchange_order_id: exchange_order_id,
      action_plan: {
        expected_after_short_eth: expected_short,
        delta_eth: (BigDecimal(expected_short) - BigDecimal(old_short)).to_s("F")
      }
    }
    File.write(path, "#{JSON.generate(receipt)}\n")

    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short,
      new_short_size: old_short,
      realized_pnl: BigDecimal("0"),
      status: ShortRebalance::STATUS_PENDING,
      message: "Nado submit accepted but readback did not confirm ETH-PERP position.",
      rebalanced_at: 5.minutes.ago,
      venue: "nado",
      order_side: side,
      reduce_only: side == "buy",
      exchange_order_id: exchange_order_id,
      receipt_path: path.to_s
    )
  end

  def stale_pending_hedge
    hedge = nado_hedge
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "1.0",
      new_short_size: "1.2",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      message: "newer success",
      rebalanced_at: 1.hour.ago,
      venue: "nado",
      created_at: 1.hour.ago
    )
    pending = pending_rebalance(hedge, old_short: "0.483", expected_short: "0.483", side: "sell")
    pending.update!(created_at: 8.days.ago, updated_at: 8.days.ago, rebalanced_at: 8.days.ago)
    hedge.position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      production_venue: "nado",
      target_short_eth: "1.2",
      tolerance_abs_eth: "0.04",
      combined_short_eth: "1.2",
      inside_tolerance: true
    )
    hedge
  end

  def size(value)
    { size: BigDecimal(value), symbol: "ETH-PERP", side: BigDecimal(value).negative? ? "short" : "long" }
  end
end
