require "test_helper"

class RandomRotationSetupWizardTest < ActiveSupport::TestCase
  test "missing route proofs report not ready and recommend extended to ethereal" do
    position = position_with_snapshot("extended")
    registry = isolated_registry
    readiness = MigrationRandomReadiness.new(position: position, proof_registry: registry).report

    report = RandomRotationSetupWizard.new(position: position, readiness: readiness, proof_registry: registry).report

    assert_equal "not_ready", report.fetch(:status)
    assert_equal "Not ready", report.fetch(:status_label)
    assert_equal "prepare_next_route", report.fetch(:next_action)
    assert_equal "extended", report.fetch(:next_route).fetch(:from_venue)
    assert_equal "ethereal", report.fetch(:next_route).fetch(:to_venue)
    assert_equal false, report.fetch(:next_action_live)
    assert_equal 0, report.fetch(:counters).fetch(:orders_submitted)
    assert_equal 0, report.fetch(:counters).fetch(:signatures_created)
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

    assert_equal "ready_to_enable", report.fetch(:status)
    assert_equal "enable_random", report.fetch(:next_action)
    assert_equal RandomRotationSetupWizard::ENABLE_CONFIRMATION, report.fetch(:required_confirmation_phrase)
    assert_empty report.fetch(:enable_blockers)
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
    assert_equal 0, report.fetch(:counters).fetch(:signatures_created)
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
end
