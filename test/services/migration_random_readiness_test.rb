require "test_helper"

class MigrationRandomReadinessTest < ActiveSupport::TestCase
  test "recovery-finalized Ethereal to Nado suppresses pending continuation and recommends Nado to Ethereal" do
    canary_dir = Rails.root.join("tmp/test-readiness-canaries-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-readiness-recoveries-#{SecureRandom.hex(4)}")
    random_dir = Rails.root.join("tmp/test-readiness-random-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_ready_canary(canary_dir, position: position, from: "extended", to: "ethereal")
    write_ready_canary(canary_dir, position: position, from: "ethereal", to: "extended")
    write_ready_canary(canary_dir, position: position, from: "extended", to: "nado")
    write_ready_canary(canary_dir, position: position, from: "nado", to: "extended")
    write_pending_nado_canary(canary_dir, position: position, from: "ethereal", timestamp: 10.minutes.ago)
    write_recovery(recovery_dir, position: position, from: "ethereal", to: "nado", timestamp: 5.minutes.ago)
    write_dry_run(random_dir, position: position, from: "nado", to: "ethereal")
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: random_dir)

    report = MigrationRandomReadiness.new(position: position, proof_registry: registry, canary_dir: canary_dir).report

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", report.fetch(:route_proof_statuses).find { |route| route[:route] == "ethereal->nado" }.fetch(:status)
    assert_nil report.fetch(:pending_nado_target_continuation)
    assert_equal false, report.fetch(:pending_nado_target_continuation_blocking)
    assert_equal true, report.fetch(:stale_pending_continuation_ignored)
    assert_not_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
    assert_equal "nado->ethereal", report.fetch(:next_recommended_canary).fetch(:route)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
    FileUtils.rm_rf(random_dir) if random_dir
  end

  test "route-ready pending Nado continuation blocks when hedge is outside tolerance" do
    pending_dir = Rails.root.join("tmp/test-readiness-pending-#{SecureRandom.hex(4)}")
    proof_dir = Rails.root.join("tmp/test-readiness-ready-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-readiness-recoveries-#{SecureRandom.hex(4)}")
    position = migration_position("ethereal")
    write_pending_nado_canary(pending_dir, position: position, from: "extended", timestamp: 10.minutes.ago)
    write_ready_canary(proof_dir, position: position, from: "extended", to: "nado")
    position.position_dashboard_snapshot.update!(
      production_venue: "ethereal",
      selected_venue: "ethereal",
      extended_short_eth: "0",
      ethereal_short_eth: "2.469",
      nado_short_eth: "0",
      target_short_eth: "2.288623048860169",
      tolerance_abs_eth: "0.06865869146580507",
      combined_short_eth: "2.469",
      drift_eth: "-0.180376951139831",
      inside_tolerance: false,
      open_orders_count_extended: 0
    )
    registry = MigrationRouteProofRegistry.new(canary_dir: proof_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, proof_registry: registry, canary_dir: pending_dir).report

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", report.fetch(:route_proof_statuses).find { |route| route[:route] == "extended->nado" }.fetch(:status)
    assert_equal "extended->nado", report.fetch(:pending_nado_target_continuation).fetch(:route)
    assert_equal false, report.fetch(:stale_pending_continuation_ignored)
    assert_equal true, report.fetch(:pending_nado_target_continuation_blocking)
    assert_equal "real_unresolved_exchange_risk", report.fetch(:pending_continuation_classification)
    assert_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
  ensure
    FileUtils.rm_rf(pending_dir) if pending_dir
    FileUtils.rm_rf(proof_dir) if proof_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "current venue regains a live eligible route from fresh production cycle evidence" do
    canary_dir = Rails.root.join("tmp/test-readiness-canaries-#{SecureRandom.hex(4)}")
    production_dir = Rails.root.join("tmp/test-readiness-production-#{SecureRandom.hex(4)}")
    empty_dir = Rails.root.join("tmp/test-readiness-empty-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    # Extended holds the production hedge (source of the rotation route).
    position.position_dashboard_snapshot.update!(
      extended_short_eth: "1.18", extended_status: "active", nado_short_eth: "0", nado_status: "flat"
    )
    # Legacy canary receipts have gone stale; only production cycle evidence is fresh.
    write_stale_canary(canary_dir, position: position, from: "extended", to: "ethereal")
    write_production_cycle_event(production_dir, position: position, from: "extended", to: "ethereal", timestamp: 2.hours.ago)
    registry = MigrationRouteProofRegistry.new(
      canary_dir: canary_dir, recovery_dir: empty_dir, route_proof_dir: empty_dir,
      random_dir: empty_dir, continuation_dir: empty_dir, latency_proof_dir: empty_dir,
      production_dir: production_dir
    )
    stub_matrix = { routes: [ {
      from_venue: "extended", to_venue: "ethereal", preview_available: true,
      route_status: "READY_FOR_DRY_RUN", open_orders_status: "clear", blockers: []
    } ] }
    planner = MigrationRandomPlanner.new(proof_registry: registry, route_matrix: stub_matrix)

    report = MigrationRandomReadiness.new(position: position, proof_registry: registry, planner: planner, canary_dir: canary_dir).report

    ethereal_route = report.fetch(:route_proof_statuses).find { |route| route[:route] == "extended->ethereal" }
    assert_equal "READY_FOR_RANDOM", ethereal_route.fetch(:status)
    assert_equal "production_random_cycle", ethereal_route.fetch(:proof_source)
    assert_includes report.fetch(:completed_route_proofs).map { |route| route[:route] }, "extended->ethereal"
    assert_includes report.fetch(:current_live_eligible_routes).map { |route| route[:route] }, "extended->ethereal"
  ensure
    [ canary_dir, production_dir, empty_dir ].each { |dir| FileUtils.rm_rf(dir) if dir }
  end

  private

  def write_stale_canary(dir, position:, from:, to:)
    write_event(dir, {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: 45.days.ago.utc.iso8601
    })
  end

  def write_production_cycle_event(dir, position:, from:, to:, timestamp:)
    FileUtils.mkdir_p(dir)
    event = {
      event: "cycle",
      cycle: 12,
      started_at: timestamp.utc.iso8601,
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      status: "success",
      blockers: [],
      execution: {
        status: "MIGRATION_FINALIZED",
        source_flat_after: true,
        target_holds_expected_short: true,
        third_venue_flat: true,
        open_orders_clear_after: true,
        open_orders_after: 0,
        final_inside_tolerance: true,
        production_venue_finalized: true,
        manual_action_required: false,
        orders_submitted: 1,
        signatures_created: 1
      },
      post_cycle_hedge: { production_venue: to }
    }
    File.open(Pathname(dir).join("20260706_120000_position_#{position.id}.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
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
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1.18",
      extended_status: "flat",
      ethereal_status: "flat",
      nado_status: "active",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 0
    )
    position
  end

  def write_ready_canary(dir, position:, from:, to:)
    write_event(dir, {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: Time.current.iso8601
    })
  end

  def write_pending_nado_canary(dir, position:, from:, timestamp:)
    write_event(dir, {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: "nado",
      final_status: "TARGET_ACCEPTED_AWAITING_CONTINUATION",
      target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
      continuation_pending: true,
      nado_target_digest: "0xnado-target",
      exchange_order_ids: [ "0xnado-target" ],
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: timestamp.iso8601
    })
  end

  def write_recovery(dir, position:, from:, to:, timestamp:)
    write_event(dir, {
      action: "recover_target_first_source_close",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      lifecycle_state: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      readback_confirmed: true,
      target_confirmed: true,
      source_already_flat: true,
      other_venues_flat: true,
      third_venue_flat: true,
      open_orders_clear_after: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      manual_action_required: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      timestamp: timestamp.iso8601
    })
  end

  def write_dry_run(dir, position:, from:, to:)
    write_event(dir, {
      action: "random_migration_rehearsal",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: "dry_run",
      timestamp: Time.current.iso8601,
      orders_submitted: 0,
      signatures_created: 0
    })
  end

  def write_event(dir, event)
    FileUtils.mkdir_p(dir)
    File.open(Pathname(dir).join("20260601.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end
end
