require "test_helper"

class RandomRotationSetupWizardTest < ActiveSupport::TestCase
  test "missing route proofs report not ready and recommend extended to ethereal" do
    position = position_with_snapshot("extended")
    registry = isolated_registry
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal RandomRotationSetupWizard::STATES[:no_dry_run], report.fetch(:status)
    assert_equal "No dry-run proof yet", report.fetch(:status_label)
    assert_equal "prepare_next_route", report.fetch(:next_action)
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "ethereal", report.fetch(:next_route).fetch(:to_venue)
    assert_equal false, report.fetch(:next_action_live)
    assert_equal 0, report.fetch(:counters).fetch(:orders_submitted)
    assert_equal 0, report.fetch(:counters).fetch(:orders_placed)
    assert_equal 0, report.fetch(:counters).fetch(:signatures_created)
    assert_equal 0, report.fetch(:counters).fetch(:cancels_submitted)
  end

  test "all ready route proofs show enable random action" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    writer = HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries"))
    MigrationRouteProofRegistry::ROUTES.each do |from, to|
      writer.write(
        action: "manual_live_canary",
        timestamp: Time.current.utc.iso8601,
        position_id: position.id,
        from_venue: from,
        to_venue: to,
        final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
        target_leg_readback_confirmed: true,
        source_leg_readback_confirmed: true,
        final_inside_tolerance: true,
        source_flat_after: true,
        target_holds_expected_short: true,
        open_orders_after: 0,
        orders_submitted: 1,
        orders_placed: 1,
        signatures_created: 1
      )
    end
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal RandomRotationSetupWizard::STATES[:ready_for_random], report.fetch(:status)
    assert_equal "enable_random", report.fetch(:next_action)
    assert_equal RandomRotationSetupWizard::ENABLE_CONFIRMATION, report.fetch(:required_confirmation_phrase)
    assert_empty report.fetch(:enable_blockers)
  end

  test "dry run proven route shows supervised live canary action" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "ethereal")
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal RandomRotationSetupWizard::STATES[:dry_run_proven], report.fetch(:status)
    assert_equal "Dry-run complete / supervised canary required", report.fetch(:status_label)
    assert_equal "run_live_canary", report.fetch(:next_action)
    assert_equal "Run Supervised Live Canary", report.fetch(:next_action_label)
    assert_equal MigrationManualLiveCanaryRunner::CONFIRMATION, report.fetch(:required_confirmation_phrase)
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "ethereal", report.fetch(:next_route).fetch(:to_venue)
    assert_equal "DRY_RUN_PROVEN", report.fetch(:setup_progress).fetch(:status)
    assert_equal 0, report.fetch(:random_enablement).fetch(:ready_routes)
    assert_equal 6, report.fetch(:random_enablement).fetch(:total_routes)
    assert_not_equal "prepare_next_route", report.fetch(:next_action)
  end

  test "dry run proven Nado route shows supervised Nado canary action" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_ready_route(dir: dir, position: position, from: "extended", to: "ethereal")
    write_ready_route(dir: dir, position: position, from: "ethereal", to: "extended")
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "nado")
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal RandomRotationSetupWizard::STATES[:dry_run_proven], report.fetch(:status)
    assert_equal "Dry-run complete / supervised Nado canary required", report.fetch(:status_label)
    assert_equal "run_live_canary", report.fetch(:next_action)
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "nado", report.fetch(:next_route).fetch(:to_venue)
    assert_equal MigrationManualLiveCanaryRunner::CONFIRMATION, report.fetch(:required_confirmation_phrase)
  end

  test "successful Extended to Nado canary advances random readiness count" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_ready_route(dir: dir, position: position, from: "extended", to: "ethereal")
    write_ready_route(dir: dir, position: position, from: "ethereal", to: "extended")

    before = registry.report(position: position)
    assert_equal 2, before.fetch(:completed_route_proofs).size

    write_ready_route(dir: dir, position: position, from: "extended", to: "nado")
    after = registry.report(position: position)
    route = after.fetch(:routes).find { |entry| entry[:route] == "extended->nado" }

    assert_equal 3, after.fetch(:completed_route_proofs).size
    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal "nado", route.fetch(:final_venue)
    assert_equal 2, route.fetch(:orders_submitted)
    assert_equal 2, route.fetch(:signatures_created)
  end

  test "completed Extended to Nado readback with stale app venue shows finalize instead of canary" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "nado")
    set_completed_readback(position, from: "extended", to: "nado", production_venue: "extended")
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal RandomRotationSetupWizard::STATES[:source_closed_not_finalized], report.fetch(:status)
    assert_equal "finalize_migration", report.fetch(:next_action)
    assert_equal "Finalize migration", report.fetch(:next_action_label)
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "nado", report.fetch(:next_route).fetch(:to_venue)
    assert_not_equal "run_live_canary", report.fetch(:next_action)
    assert_equal 0, report.fetch(:counters).fetch(:orders_submitted)
    assert_equal 0, report.fetch(:counters).fetch(:signatures_created)
  end

  test "completed Extended to Nado readback with app venue already target advances to Nado to Ethereal" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_ready_route(dir: dir, position: position, from: "extended", to: "ethereal")
    write_ready_route(dir: dir, position: position, from: "ethereal", to: "extended")
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "nado")
    position.hedge.update!(execution_venue: "nado")
    set_completed_readback(position, from: "extended", to: "nado", production_venue: "nado")
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report
    route = registry.report(position: position).fetch(:routes).find { |item| item[:route] == "extended->nado" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal 3, report.fetch(:random_enablement).fetch(:ready_routes)
    assert_equal "prepare_next_route", report.fetch(:next_action)
    assert_equal "nado", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "ethereal", report.fetch(:next_route).fetch(:to_venue)
    assert_no_match(/Run Supervised Live Canary/, report.fetch(:next_action_label))
  end

  test "all routes reconcile completed readback without showing duplicate canary" do
    MigrationRouteProofRegistry::ROUTES.each do |from, to|
      position = position_with_snapshot(from)
      dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
      registry = isolated_registry(base_dir: dir)
      write_dry_run_route(dir: dir, position: position, from: from, to: to)
      position.hedge.update!(execution_venue: to)
      set_completed_readback(position, from: from, to: to, production_venue: to)
      readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

      report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report
      route = registry.report(position: position).fetch(:routes).find { |item| item[:route] == "#{from}->#{to}" }

      assert_equal "READY_FOR_RANDOM", route.fetch(:status), "#{from}->#{to}"
      assert_not_equal "run_live_canary", report.fetch(:next_action), "#{from}->#{to}"
      assert_equal 0, report.fetch(:counters).fetch(:orders_submitted), "#{from}->#{to}"
      assert_equal 0, report.fetch(:counters).fetch(:orders_placed), "#{from}->#{to}"
      assert_equal 0, report.fetch(:counters).fetch(:signatures_created), "#{from}->#{to}"
      assert_equal 0, report.fetch(:counters).fetch(:cancels_submitted), "#{from}->#{to}"
    end
  end

  test "final random blockers do not hide dry run proven canary action" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "ethereal")
    proof_report = registry.report(position: position)
    dry_route = proof_report.fetch(:routes).find { |route| route[:route] == "extended->ethereal" }
    readiness = {
      action: "migration_random_readiness",
      position_id: position.id,
      current_production_venue: "extended",
      next_recommended_canary: dry_route,
      completed_route_proofs: [],
      missing_route_proofs: proof_report.fetch(:missing_route_proofs),
      stale_route_proofs: [],
      pending_nado_target_continuation: nil,
      blockers: [
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true",
        "MIGRATION_LIVE_ENABLED must be true",
        "all route proofs must be READY_FOR_RANDOM"
      ],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal "run_live_canary", report.fetch(:next_action)
    assert_includes report.fetch(:random_enablement).fetch(:blockers), "all route proofs must be READY_FOR_RANDOM"
    assert_not_equal "prepare_next_route", report.fetch(:next_action)
  end

  test "degraded fallback preserves dry run proven canary action" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}")
    registry = isolated_registry(base_dir: dir)
    write_dry_run_route(dir: dir, position: position, from: "extended", to: "ethereal")

    report = RandomRotationSetupWizard.degraded(
      position: position,
      message: "random readiness timed out",
      proof_registry: registry
    )

    assert_equal RandomRotationSetupWizard::STATES[:dry_run_proven], report.fetch(:status)
    assert_equal "run_live_canary", report.fetch(:next_action)
    assert_equal MigrationManualLiveCanaryRunner::CONFIRMATION, report.fetch(:required_confirmation_phrase)
  end

  test "degraded report keeps canonical routes when readiness is unavailable" do
    position = position_with_snapshot("extended")

    report = RandomRotationSetupWizard.degraded(
      position: position,
      message: "random readiness timed out",
      proof_registry: isolated_registry
    )

    assert_equal "degraded", report.fetch(:status)
    assert_equal "Setup loaded with limited diagnostics", report.fetch(:status_label)
    assert_equal 6, report.fetch(:route_proof_statuses).size
    assert_equal 6, report.fetch(:missing_route_proofs).size
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "ethereal", report.fetch(:next_route).fetch(:to_venue)
    assert_equal "Healthy", report.fetch(:hedge_health).fetch(:status)
    assert_equal BigDecimal("1.25"), report.fetch(:venue_shorts).fetch("extended")
    assert_equal 0, report.fetch(:counters).fetch(:orders_submitted)
    assert_equal 0, report.fetch(:counters).fetch(:orders_placed)
    assert_equal 0, report.fetch(:counters).fetch(:signatures_created)
    assert_equal 0, report.fetch(:counters).fetch(:cancels_submitted)
  end

  test "out of tolerance snapshot blocks setup without losing routes" do
    position = position_with_snapshot("extended", inside_tolerance: false, target: "2.248279624519602", current: "2.166", tolerance: "0.06744838873558806")
    registry = isolated_registry
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry, dashboard_health: "ACTION REQUIRED").report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal "blocked_hedge_health", report.fetch(:status)
    assert_equal "Setup blocked / current hedge out of tolerance", report.fetch(:status_label)
    assert_equal "Out of tolerance", report.fetch(:hedge_health).fetch(:status)
    assert_equal BigDecimal("2.248279624519602"), report.fetch(:hedge_health).fetch(:target_short_eth)
    assert_equal BigDecimal("0.082279624519602"), report.fetch(:hedge_health).fetch(:drift_eth)
    assert_equal 6, report.fetch(:route_proof_statuses).size
    assert_equal "rebalance_current_hedge", report.fetch(:next_action)
    assert_equal false, report.fetch(:next_action_live)
  end

  private

  def position_with_snapshot(venue, inside_tolerance: true, target: "1.25", current: "1.25", tolerance: "0.0625")
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: target,
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
      target_short_eth: target,
      tolerance_abs_eth: tolerance,
      combined_short_eth: current,
      drift_eth: (BigDecimal(target) - BigDecimal(current)).to_s("F"),
      inside_tolerance: inside_tolerance,
      extended_short_eth: venue == "extended" ? current : "0",
      ethereal_short_eth: venue == "ethereal" ? current : "0",
      nado_short_eth: venue == "nado" ? current : "0",
      signer_status: "ok"
    )
    position
  end

  def isolated_registry(base_dir: Rails.root.join("tmp/random-rotation-wizard-#{SecureRandom.hex(4)}"))
    MigrationRouteProofRegistry.new(
      route_proof_dir: base_dir.join("route_proofs"),
      canary_dir: base_dir.join("canaries"),
      recovery_dir: base_dir.join("recoveries"),
      continuation_dir: base_dir.join("continuations"),
      random_dir: base_dir.join("random")
    )
  end

  def write_dry_run_route(dir:, position:, from:, to:)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("random")).write(
      action: "random_migration_rehearsal",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: "dry_run",
      route_status: "READY_FOR_DRY_RUN",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )
  end

  def write_ready_route(dir:, position:, from:, to:)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )
  end

  def set_completed_readback(position, from:, to:, production_venue:)
    target = position.position_dashboard_snapshot.target_short_eth
    attrs = {
      production_venue: production_venue,
      selected_venue: production_venue,
      combined_short_eth: target,
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      open_orders_count_extended: 0
    }
    attrs["#{from}_short_eth"] = "0"
    attrs["#{to}_short_eth"] = target
    position.position_dashboard_snapshot.update!(attrs)
  end
end
