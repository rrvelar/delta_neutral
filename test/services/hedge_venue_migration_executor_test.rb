require "test_helper"

class HedgeVenueMigrationExecutorTest < ActiveSupport::TestCase
  test "live execution blocks without env gate" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: {}).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "MIGRATION_LIVE_ENABLED must be true"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live execution blocks without confirmation" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: { "MIGRATION_LIVE_ENABLED" => "true" }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: "wrong",
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{HedgeVenueMigrationExecutor::CONFIRMATION}"
  end

  test "live execution blocks with open orders" do
    position = migration_position(open_orders_count: 1)
    result = HedgeVenueMigrationExecutor.new(env: { "MIGRATION_LIVE_ENABLED" => "true" }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "target/source open orders must be zero."
  end

  test "execution stops if first leg is not confirmed" do
    position = migration_position
    calls = []
    runner = ->(leg) do
      calls << leg
      { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 1 }
    end

    result = HedgeVenueMigrationExecutor.new(env: { "MIGRATION_LIVE_ENABLED" => "true" }, leg_runner: runner).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "first_leg_not_confirmed", result.status
    assert_equal 1, calls.size
  end

  test "second leg failure produces partial migration status" do
    position = migration_position
    calls = []
    runner = ->(leg) do
      calls << leg
      if calls.size == 1
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1 }
      else
        { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 0 }
      end
    end

    result = HedgeVenueMigrationExecutor.new(env: { "MIGRATION_LIVE_ENABLED" => "true" }, leg_runner: runner).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "partial_migration_manual_action_required", result.status
    assert_equal 2, calls.size
    assert_equal 2, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  private

  def migration_position(open_orders_count: 0)
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
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
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
      nado_source_status: "ok",
      open_orders_count_extended: open_orders_count,
      leverage_margin_gate_status: "pass"
    )
    position
  end
end
