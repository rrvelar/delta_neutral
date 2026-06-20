require "test_helper"

class PositionDashboardSnapshotTest < ActiveSupport::TestCase
  test "migration completeness is false when target short is missing" do
    snapshot = position_dashboard_snapshot(target_short_eth: nil)

    assert_equal false, snapshot.migration_complete_for_proof?
    assert_equal false, snapshot.migration_critical_fields_present?
    assert_includes snapshot.missing_migration_fields, "target_short_eth"
  end

  test "migration completeness is true when critical fields are present" do
    snapshot = position_dashboard_snapshot

    assert_equal true, snapshot.migration_complete_for_proof?
    assert_empty snapshot.missing_migration_fields
  end

  test "carried-forward Extended exposure is diagnostic only and never confirmed live exposure" do
    snapshot = position_dashboard_snapshot(
      extended_short_eth: nil,
      extended_carried_forward_short_eth: "1.997",
      extended_status: "error",
      extended_source_status: "stale",
      extended_critical_read_status: "error_carried_forward"
    )

    assert_equal true, snapshot.extended_exposure_carried_forward?

    state = snapshot.venue_state("extended")
    assert_nil state[:short_size], "stale value must not surface as confirmed live exposure"
    assert_equal true, state[:carried_forward_exposure]
    assert_equal BigDecimal("1.997"), state[:carried_forward_short_eth]
    assert_equal "1.997", state[:carried_forward_short_eth_display]
    refute_equal "active", state[:status]

    # The unknown Extended readback fails closed for migration readiness.
    assert_equal false, snapshot.migration_complete_for_proof?
    assert_includes snapshot.missing_migration_fields, "extended_short_eth"
  end

  test "fresh confirmed Extended read does not expose carry-forward diagnostic" do
    snapshot = position_dashboard_snapshot

    assert_equal false, snapshot.extended_exposure_carried_forward?
    state = snapshot.venue_state("extended")
    assert_equal false, state[:carried_forward_exposure]
    assert_nil state[:carried_forward_short_eth]
  end

  private

  def position_dashboard_snapshot(overrides = {})
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
    position.create_position_dashboard_snapshot!({
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok"
    }.merge(overrides))
  end
end
