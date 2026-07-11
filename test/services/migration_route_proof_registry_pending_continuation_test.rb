require "test_helper"

# Resolution of stale pending target=Nado continuation artifacts: an old
# TARGET_ACCEPTED_AWAITING_CONTINUATION receipt must be auto-resolved when the
# route's latest fresh proof carries the finalization flags
# (production_venue_finalized / open orders clear / other venues flat), and must
# stay unresolved when those flags are absent — the regression that resurfaced
# the June-5 artifact after the 2026-07-11 ethereal->nado certification.
class MigrationRouteProofRegistryPendingContinuationTest < ActiveSupport::TestCase
  test "stale pending nado artifact resolves when fresh proof carries finalization flags" do
    position = nado_position
    dir = Rails.root.join("tmp/route-proof-pending-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    pending = write_pending_artifact(dir: dir, position: position, timestamp: 30.days.ago.utc.iso8601)
    write_fresh_canary_proof(dir: dir, position: position, finalization_flags: true)

    assert_equal "READY_FOR_RANDOM", registry.route_status(position: position, from: "ethereal", to: "nado").fetch(:status)
    assert_equal true, registry.resolved_nado_target_continuation?(position: position, pending_event: pending)
  end

  test "stale pending nado artifact stays unresolved when fresh proof lacks finalization flags" do
    position = nado_position
    dir = Rails.root.join("tmp/route-proof-pending-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    pending = write_pending_artifact(dir: dir, position: position, timestamp: 30.days.ago.utc.iso8601)
    write_fresh_canary_proof(dir: dir, position: position, finalization_flags: false)

    route = registry.route_status(position: position, from: "ethereal", to: "nado")
    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_nil route.fetch(:final_readback_summary)[:production_venue_finalized]
    assert_equal false, registry.resolved_nado_target_continuation?(position: position, pending_event: pending)
  end

  test "fresh proof summary exposes the finalization flags the resolver needs" do
    position = nado_position
    dir = Rails.root.join("tmp/route-proof-pending-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_fresh_canary_proof(dir: dir, position: position, finalization_flags: true)

    summary = registry.route_status(position: position, from: "ethereal", to: "nado").fetch(:final_readback_summary)
    assert_equal true, summary[:production_venue_finalized]
    assert_equal true, summary[:open_orders_clear_after]
    assert_equal true, summary[:third_venue_flat]
  end

  private

  def registry_for(dir)
    MigrationRouteProofRegistry.new(
      route_proof_dir: dir.join("route_proofs"),
      canary_dir: dir.join("canaries"),
      recovery_dir: dir.join("recoveries"),
      continuation_dir: dir.join("continuations"),
      random_dir: dir.join("random"),
      latency_proof_dir: dir.join("latency_proofs"),
      production_dir: dir.join("production")
    )
  end

  # The June-5-shaped stale artifact: an accepted Nado target awaiting continuation.
  def write_pending_artifact(dir:, position:, timestamp:)
    event = {
      action: "manual_live_canary",
      timestamp: timestamp,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "TARGET_ACCEPTED_AWAITING_CONTINUATION",
      target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
      continuation_pending: true,
      manual_action_required: true,
      pending_migration_id: "abc123def4567890",
      nado_target_digest: "0x#{SecureRandom.hex(32)}",
      exchange_order_ids: [ "0x#{SecureRandom.hex(32)}" ],
      orders_submitted: 1, orders_placed: 1, signatures_created: 1
    }
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(event)
    event.transform_keys(&:to_s)
  end

  # A fresh certified source_first canary receipt, with or without the
  # executor finalization flags that from_executor_result must propagate.
  def write_fresh_canary_proof(dir:, position:, finalization_flags:)
    event = {
      action: "manual_live_canary",
      timestamp: 1.hour.ago.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      migration_sequence: "source_first",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      underhedge_seconds: 4.5,
      double_exposure_seconds: "0",
      route_production_safe: true,
      route_latency_proof: true,
      orders_submitted: 2, orders_placed: 2, signatures_created: 2
    }
    if finalization_flags
      event.merge!(production_venue_finalized: true, open_orders_clear_after: true, third_venue_flat: true)
    end
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(event)
  end

  def nado_position
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
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "nado")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "nado",
      selected_venue: "nado",
      target_short_eth: "1",
      tolerance_abs_eth: "0.05",
      combined_short_eth: "1",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1",
      signer_status: "ok"
    )
    position
  end
end
