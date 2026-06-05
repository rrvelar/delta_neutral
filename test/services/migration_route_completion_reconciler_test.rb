require "test_helper"

class MigrationRouteCompletionReconcilerTest < ActiveSupport::TestCase
  setup do
    OperationalSetting.delete_all
    OperationalSettingAudit.delete_all
  end

  test "finalize switches production venue and active auto to target only" do
    position = position_with_completed_readback(from: "extended", to: "ethereal", production_venue: "extended")

    result = MigrationRouteCompletionReconciler.new(position: position, from: "extended", to: "ethereal").finalize!

    assert_equal MigrationRouteCompletionReconciler::FINALIZED_STATUS, result.status
    assert_equal "ethereal", position.hedge.reload.execution_venue
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal 0, result.receipt.fetch(:cancels_submitted)
  end

  test "report does not finalize when target is not confirmed" do
    position = position_with_completed_readback(from: "extended", to: "ethereal", production_venue: "extended")
    position.position_dashboard_snapshot.update!(ethereal_short_eth: "0", combined_short_eth: "0", inside_tolerance: false)

    result = MigrationRouteCompletionReconciler.new(position: position, from: "extended", to: "ethereal").finalize!

    assert_equal "NOT_COMPLETE_BY_READBACK", result.status
    assert_equal "extended", position.hedge.reload.execution_venue
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    assert_includes result.blockers, "Ethereal target venue does not hold expected short"
  end

  private

  def position_with_completed_readback(from:, to:, production_venue:)
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
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: production_venue)
    attrs = {
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: production_venue,
      selected_venue: production_venue,
      target_short_eth: "1.25",
      tolerance_abs_eth: "0.0625",
      combined_short_eth: "1.25",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      open_orders_count_extended: 0,
      signer_status: "ok"
    }
    attrs["#{from}_short_eth"] = "0"
    attrs["#{to}_short_eth"] = "1.25"
    position.create_position_dashboard_snapshot!(attrs)
    position
  end
end
