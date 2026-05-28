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
