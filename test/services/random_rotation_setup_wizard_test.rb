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

  private

  def position_with_snapshot(venue)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.25",
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
      target_short_eth: "1.25",
      tolerance_abs_eth: "0.0625",
      combined_short_eth: "1.25",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: venue == "extended" ? "1.25" : "0",
      ethereal_short_eth: venue == "ethereal" ? "1.25" : "0",
      nado_short_eth: venue == "nado" ? "1.25" : "0",
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
