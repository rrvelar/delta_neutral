require "test_helper"

class HedgeVenueMigrationPlannerTest < ActiveSupport::TestCase
  test "planner uses PositionDashboardSnapshot instead of ShortRebalance for current exposure" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")
    position.hedge.short_rebalances.create!(
      venue: "ethereal",
      asset: "WETH",
      old_short_size: "1.1",
      new_short_size: "1.2",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: 1.minute.ago
    )

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal", mode: "full", full_migration_allowed: true)

    assert_equal "preview", result.status, result.blockers.inspect
    assert_equal "0.8", result.receipt.fetch(:from_short_before)
    assert_equal "0.0", result.receipt.fetch(:to_short_before)
    assert_equal "0.8", result.receipt.fetch(:planned_to_leg).fetch(:size_eth)
  end

  test "planner blocks when snapshot is missing" do
    position = migration_position(execution_venue: "extended")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal")

    assert_equal "blocked", result.status
    assert_includes result.blockers, "Position dashboard snapshot is missing; refresh read-only data before planning migration."
  end

  test "planner blocks when snapshot is stale" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8", refreshed_at: 10.minutes.ago)

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal")

    assert_equal "blocked", result.status
    assert_includes result.blockers, "Position dashboard snapshot is stale; refresh read-only data before planning migration."
  end

  test "planner builds Ethereal to Extended plan" do
    position = migration_position(execution_venue: "ethereal")
    snapshot_for(position, extended_short: "0", ethereal_short: "0.8", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "ethereal", to_venue: "extended", mode: "full", full_migration_allowed: true)

    assert_equal "sell", result.receipt.fetch(:planned_to_leg).fetch(:side)
    assert_equal false, result.receipt.fetch(:planned_to_leg).fetch(:reduce_only)
    assert_equal "buy", result.receipt.fetch(:planned_from_leg).fetch(:side)
    assert_equal true, result.receipt.fetch(:planned_from_leg).fetch(:reduce_only)
  end

  test "planner builds Extended to Ethereal dry run plan with temporary overhedge warning" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal", mode: "full", full_migration_allowed: true)

    assert_equal "ethereal", result.receipt.fetch(:planned_to_leg).fetch(:venue)
    assert_equal "sell", result.receipt.fetch(:planned_to_leg).fetch(:side)
    assert_equal "extended", result.receipt.fetch(:planned_from_leg).fetch(:venue)
    assert_equal "buy", result.receipt.fetch(:planned_from_leg).fetch(:side)
    assert_includes result.warnings, "Target-venue-first sequence temporarily overhedges until source venue reduction confirms."
  end

  test "Nado migration is unavailable" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "nado")

    assert_equal "blocked", result.status
    assert_includes result.blockers, "Nado migration readiness is not implemented."
  end

  private

  def migration_position(execution_venue:)
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
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: execution_venue)
    position
  end

  def snapshot_for(position, extended_short:, ethereal_short:, nado_short:, target:, refreshed_at: Time.current)
    combined = BigDecimal(extended_short) + BigDecimal(ethereal_short) + BigDecimal(nado_short)
    target_decimal = BigDecimal(target)
    position.create_position_dashboard_snapshot!(
      refreshed_at: refreshed_at,
      refresh_status: "ok",
      stale: false,
      production_venue: position.hedge.execution_venue,
      selected_venue: position.hedge.execution_venue,
      target_short_eth: target_decimal,
      tolerance_ratio: position.hedge.tolerance,
      tolerance_abs_eth: target_decimal * position.hedge.tolerance,
      combined_short_eth: combined,
      drift_eth: target_decimal - combined,
      inside_tolerance: (target_decimal - combined).abs <= target_decimal * position.hedge.tolerance,
      extended_short_eth: extended_short,
      ethereal_short_eth: ethereal_short,
      nado_short_eth: nado_short,
      extended_status: BigDecimal(extended_short).positive? ? "active" : "flat",
      ethereal_status: BigDecimal(ethereal_short).positive? ? "active" : "flat",
      nado_status: BigDecimal(nado_short).positive? ? "active" : "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 0,
      leverage_margin_gate_status: "pass"
    )
  end
end
