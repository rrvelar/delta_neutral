require "test_helper"

class MigrationRandomSystemTest < ActiveSupport::TestCase
  test "random planner from Nado selects only Nado source routes" do
    result = random_planner.plan(position: migration_position("nado"))

    assert_empty result.blockers
    assert_equal %w[nado->ethereal nado->extended], result.receipt.fetch(:eligible_routes).map { |route| route.fetch(:route) }.sort
    assert result.receipt.fetch(:selected_route).fetch(:route).in?(%w[nado->ethereal nado->extended])
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "random planner excludes current source routes when source is flat or preview missing" do
    matrix = {
      routes: [
        route("nado", "ethereal", route_status: "READY_FOR_DRY_RUN", preview_available: true),
        route("nado", "extended", route_status: "PREVIEW_BLOCKED", preview_available: false),
        route("ethereal", "nado", route_status: "READY_FOR_DRY_RUN", preview_available: true)
      ]
    }
    result = random_planner(route_matrix: matrix).plan(position: migration_position("nado"))

    assert_equal [ "nado->ethereal" ], result.receipt.fetch(:eligible_routes).map { |candidate| candidate.fetch(:route) }
    excluded = result.receipt.fetch(:excluded_routes)
    assert excluded.any? { |candidate| candidate.fetch(:route) == "nado->extended" && candidate.fetch(:reasons).include?("route preview unavailable") }
    assert_empty excluded.select { |candidate| candidate.fetch(:route) == "ethereal->nado" }
  end

  test "random rehearsal builds target-first plan and writes no-live receipt" do
    position = migration_position("nado")
    result = MigrationRandomRehearsal.new(planner: random_planner(selector: ->(_) { "nado->ethereal" })).run(position: position)

    assert_equal "dry_run", result.status, result.blockers.inspect
    assert_equal "nado->ethereal", result.receipt.fetch(:route)
    assert_equal "ethereal", result.receipt.fetch(:target_leg_preview).fetch(:venue)
    assert_equal "nado", result.receipt.fetch(:source_close_preview).fetch(:venue)
    assert_equal "target_first", result.receipt.fetch(:migration_sequence)
    assert_match %r{storage/hedge_migration_random_rehearsals}, result.receipt.fetch(:receipt_path)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "route proof registry tracks all six statuses" do
    route_dir = Rails.root.join("tmp/test-route-proofs-#{SecureRandom.hex(4)}")
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(route_dir, {
      action: "random_migration_rehearsal",
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "dry_run",
      timestamp: Time.current.iso8601,
      orders_submitted: 0,
      signatures_created: 0
    })
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended"))

    report = MigrationRouteProofRegistry.new(route_proof_dir: route_dir, canary_dir: canary_dir, recovery_dir: route_dir, random_dir: route_dir).report(position: position)

    assert_equal 6, report.fetch(:routes).size
    assert_equal "READY_FOR_RANDOM", report.fetch(:routes).find { |route| route[:route] == "nado->extended" }.fetch(:status)
    assert_equal "NOT_STARTED", report.fetch(:routes).find { |route| route[:route] == "extended->ethereal" }.fetch(:status)
  ensure
    FileUtils.rm_rf(route_dir) if route_dir
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "random readiness is actionable and blocks live while proofs are missing" do
    report = MigrationRandomReadiness.new(position: migration_position("nado"), planner: random_planner).report

    assert_equal true, report.fetch(:random_engine_implemented)
    assert_equal "nado", report.fetch(:current_production_venue)
    assert report.fetch(:next_recommended_canary)
    assert_match(/bin\/rails migration:rehearse_route/, report.fetch(:operator_commands).fetch(:next_canary_dry_run))
    assert_match(/bin\/rails migration:run_manual_live_canary/, report.fetch(:operator_commands).fetch(:next_canary_live))
    assert_equal false, report.fetch(:current_safe_to_live_if_operator_gates_open)
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "historical pre-fix Nado confirmation failures do not block readiness when current state is otherwise rehearsable" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "1.1",
      new_short_size: "1.1",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_FAILED,
      message: "submitted confirmation must equal I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_ORDERS",
      rebalanced_at: 1.day.ago
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_equal 1, report.dig(:nado_auto_summary, :historical_prefix_confirmation_failed_count)
    assert_equal true, report.fetch(:current_safe_to_rehearse)
    assert_not_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
  end

  test "pending Nado rebalance blocks random readiness" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "1.1",
      new_short_size: "1.1",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_PENDING,
      message: "pending digest",
      rebalanced_at: Time.current
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
  end

  private

  def random_planner(route_matrix: ready_matrix, selector: nil)
    MigrationRandomPlanner.new(
      route_matrix: route_matrix,
      proof_registry: EmptyProofRegistry.new,
      random_seed: "seed",
      selector: selector
    )
  end

  def migration_position(venue)
    position = Position.create!(
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
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: venue)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: venue,
      selected_venue: venue,
      target_short_eth: "1.18",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.0354",
      combined_short_eth: "1.18",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: venue == "extended" ? "1.18" : "0",
      ethereal_short_eth: venue == "ethereal" ? "1.18" : "0",
      nado_short_eth: venue == "nado" ? "1.18" : "0",
      extended_status: venue == "extended" ? "active" : "flat",
      ethereal_status: venue == "ethereal" ? "active" : "flat",
      nado_status: venue == "nado" ? "active" : "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok"
    )
    position
  end

  def ready_matrix
    {
      routes: [
        route("nado", "ethereal"),
        route("nado", "extended"),
        route("ethereal", "nado"),
        route("extended", "nado")
      ]
    }
  end

  def route(from, to, route_status: "READY_FOR_DRY_RUN", preview_available: true)
    {
      from_venue: from,
      to_venue: to,
      route_status: route_status,
      preview_available: preview_available,
      target_open_preview_available: preview_available,
      source_close_preview_available: preview_available,
      open_orders_status: "clear",
      blockers: []
    }
  end

  def write_event(dir, event)
    FileUtils.mkdir_p(dir)
    File.open(Pathname(dir).join("20260601.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end

  def live_canary_event(position:, from:, to:)
    {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      mode: "full",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      timestamp: Time.current.iso8601
    }
  end

  class EmptyProofRegistry
    def report(position:)
      {
        routes: MigrationLiveRouteCapability::ROUTES.map do |from, to|
          { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "NOT_STARTED", blockers: [ "missing" ] }
        end,
        completed_route_proofs: [],
        missing_route_proofs: MigrationLiveRouteCapability::ROUTES.map { |from, to| { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "NOT_STARTED" } },
        stale_route_proofs: []
      }
    end
  end
end
