require "test_helper"

class MigrationRouteProofRegistryTest < ActiveSupport::TestCase
  test "readback reconciliation receipt marks route ready with zero safety counters" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "extended",
      to_venue: "ethereal",
      final_status: "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "extended", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal "ethereal", route.fetch(:final_venue)
    assert_equal 0, route.fetch(:orders_submitted)
    assert_equal 0, route.fetch(:orders_placed)
    assert_equal 0, route.fetch(:signatures_created)
    assert_empty route.fetch(:blockers)
  end

  test "readback reconciliation receipt without source flat proof is not ready" do
    position = position_with_snapshot("nado")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "extended",
      to_venue: "nado",
      final_status: "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: false,
      final_inside_tolerance: true,
      source_flat_after: false,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "extended", to: "nado")

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_includes route.fetch(:blockers), "extended->nado temporarily disabled pending latency fix/proof."
  end

  test "safe finalized Nado target recovery still requires latency proof for random" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("recoveries")).write(
      action: "recover_target_first_source_close",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      production_venue: "nado",
      source_already_flat: true,
      target_confirmed: true,
      other_venues_flat: true,
      third_venue_flat: true,
      open_orders_clear_after: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    report = registry.report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "ethereal->nado" }

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_includes route.fetch(:blockers), "ethereal->nado temporarily disabled pending latency fix/proof."
    assert_not_includes report.fetch(:completed_route_proofs).map { |entry| entry[:route] }, "ethereal->nado"
    assert report.fetch(:missing_route_proofs).any? { |entry| entry[:route] == "ethereal->nado" }
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "source first Nado late readback finalization can mark route ready when latency proof is safe" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      manual_action_required: false,
      route_production_safe: true,
      source_flat_to_nado_submit_started_seconds: "0.02",
      source_flat_to_nado_submit_finished_seconds: "0.15",
      nado_accept_to_confirmed_seconds: "8",
      underhedge_seconds: "8",
      double_exposure_seconds: "0",
      total_migration_latency_seconds: "12",
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  private

  def registry_for(dir)
    MigrationRouteProofRegistry.new(
      route_proof_dir: dir.join("route_proofs"),
      canary_dir: dir.join("canaries"),
      recovery_dir: dir.join("recoveries"),
      continuation_dir: dir.join("continuations"),
      random_dir: dir.join("random")
    )
  end

  def position_with_snapshot(venue)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "500",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(6),
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: venue)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: venue,
      selected_venue: venue,
      target_short_eth: "1",
      tolerance_abs_eth: "0.05",
      combined_short_eth: "1",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: venue == "nado" ? "1" : "0",
      signer_status: "ok"
    )
    position
  end
end
