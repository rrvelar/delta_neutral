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

  test "planner accepts direct execution preflight when dashboard snapshot is partial" do
    position = migration_position(execution_venue: "ethereal")
    snapshot_for(position, extended_short: "0", ethereal_short: "0.8", nado_short: "0", target: "0.8")
    position.position_dashboard_snapshot.update!(refresh_status: "partial")

    result = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: "ethereal",
      to_venue: "nado",
      mode: "full",
      full_migration_allowed: true,
      execution_preflight: execution_preflight(position, current: "ethereal", target: "0.8")
    )

    assert_equal "preview", result.status, result.blockers.inspect
    assert_equal "direct_execution_preflight", result.receipt.fetch(:planning_source)
    assert_equal "0.8", result.receipt.fetch(:from_short_before)
    assert_equal "0.0", result.receipt.fetch(:to_short_before)
    assert_equal "0.8", result.receipt.fetch(:planned_target_leg).fetch(:size_eth)
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
    assert_equal "target_first", result.receipt.fetch(:migration_sequence)
    assert_equal "ethereal", result.receipt.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "extended", result.receipt.fetch(:planned_second_leg).fetch(:venue)
    assert_equal "overhedge", result.receipt.fetch(:temporary_risk_type)
    assert_includes result.warnings, "Target-venue-first sequence temporarily overhedges until source venue reduction confirms."
  end

  test "Extended to Ethereal full source first plans source close then target open" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.824", ethereal_short: "0", nado_short: "0", target: "0.8086")

    result = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      mode: "full",
      full_migration_allowed: true,
      migration_sequence: "source_first"
    )

    assert_equal "source_first", result.receipt.fetch(:migration_sequence)
    assert_equal "extended", result.receipt.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "buy", result.receipt.fetch(:planned_first_leg).fetch(:side)
    assert_equal true, result.receipt.fetch(:planned_first_leg).fetch(:reduce_only)
    assert_equal "0.824", result.receipt.fetch(:planned_first_leg).fetch(:size_eth)
    assert_equal "ethereal", result.receipt.fetch(:planned_second_leg).fetch(:venue)
    assert_equal "sell", result.receipt.fetch(:planned_second_leg).fetch(:side)
    assert_equal false, result.receipt.fetch(:planned_second_leg).fetch(:reduce_only)
    assert_equal "0.8086", result.receipt.fetch(:planned_second_leg).fetch(:size_eth)
    assert_equal "0.8086", result.receipt.fetch(:expected_final_combined)
    assert_equal "0.0", result.receipt.fetch(:expected_final_drift)
    assert_equal "0.0", result.receipt.fetch(:temporary_combined_after_first_leg)
    assert_equal "0.8086", result.receipt.fetch(:temporary_drift_after_first_leg)
    assert_equal "underhedge/unhedged", result.receipt.fetch(:temporary_risk_type)
    assert_equal true, result.receipt.fetch(:source_first_unhedged_warning)
  end

  test "Ethereal to Extended full source first works symmetrically" do
    position = migration_position(execution_venue: "ethereal")
    snapshot_for(position, extended_short: "0", ethereal_short: "0.824", nado_short: "0", target: "0.8086")

    result = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: "ethereal",
      to_venue: "extended",
      mode: "full",
      full_migration_allowed: true,
      migration_sequence: "source_first"
    )

    assert_equal "ethereal", result.receipt.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "buy", result.receipt.fetch(:planned_first_leg).fetch(:side)
    assert_equal "extended", result.receipt.fetch(:planned_second_leg).fetch(:venue)
    assert_equal "sell", result.receipt.fetch(:planned_second_leg).fetch(:side)
    assert_equal "0.8086", result.receipt.fetch(:expected_final_combined)
    assert_equal "underhedge/unhedged", result.receipt.fetch(:temporary_risk_type)
  end

  test "Extended to Ethereal full preview lands final combined at target when current combined is outside tolerance" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.974", ethereal_short: "0", nado_short: "0", target: "0.944872")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal", mode: "full", full_migration_allowed: true)

    assert_equal "preview", result.status, result.blockers.inspect
    assert_equal "0.944872", result.receipt.fetch(:planned_target_leg).fetch(:size_eth)
    assert_equal "0.974", result.receipt.fetch(:planned_source_leg).fetch(:size_eth)
    assert_equal "0.944872", result.receipt.fetch(:expected_final_combined)
    assert_equal "0.0", result.receipt.fetch(:expected_final_drift)
  end

  test "Extended to Ethereal stepwise preview transfers max step and warns final combined may remain unchanged" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "ethereal", mode: "stepwise", step_size_eth: "0.05")

    assert_equal "0.05", result.receipt.fetch(:planned_target_leg).fetch(:size_eth)
    assert_equal "0.05", result.receipt.fetch(:planned_source_leg).fetch(:size_eth)
    assert_equal "0.8", result.receipt.fetch(:expected_final_combined)
    assert result.warnings.any? { |warning| warning.include?("Stepwise migration transfers only the step size") }
  end

  test "stepwise source first plans source reduce then target increase" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      mode: "stepwise",
      step_size_eth: "0.05",
      migration_sequence: "source_first"
    )

    assert_equal "extended", result.receipt.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "0.05", result.receipt.fetch(:planned_first_leg).fetch(:size_eth)
    assert_equal "ethereal", result.receipt.fetch(:planned_second_leg).fetch(:venue)
    assert_equal "0.05", result.receipt.fetch(:planned_second_leg).fetch(:size_eth)
    assert_equal "0.75", result.receipt.fetch(:temporary_combined_after_first_leg)
    assert_equal "underhedge/unhedged", result.receipt.fetch(:temporary_risk_type)
  end

  test "Nado migration preview is supported by generic planner" do
    position = migration_position(execution_venue: "extended")
    snapshot_for(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", target: "0.8")

    result = HedgeVenueMigrationPlanner.new.plan(position: position, from_venue: "extended", to_venue: "nado", mode: "full", full_migration_allowed: true)

    assert_equal "preview", result.status
    assert_empty result.blockers
    assert_equal "nado", result.receipt.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "extended", result.receipt.fetch(:planned_second_leg).fetch(:venue)
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

  def execution_preflight(position, current:, target:)
    {
      preflight_source: "dedicated_burn_in_preflight",
      accepted: true,
      blockers: [],
      warnings: [],
      production_venue: current,
      target: { target_short_eth: BigDecimal(target), target_source: "test", target_fresh: true },
      venues: {
        "extended" => { short_eth: current == "extended" ? BigDecimal(target) : BigDecimal("0"), position_status: "ok", open_orders_status: "zero" },
        "ethereal" => { short_eth: current == "ethereal" ? BigDecimal(target) : BigDecimal("0"), position_status: "ok", open_orders_status: "zero" },
        "nado" => { short_eth: current == "nado" ? BigDecimal(target) : BigDecimal("0"), position_status: "ok", open_orders_status: "zero" }
      },
      combined_short_eth: BigDecimal(target),
      drift_eth: BigDecimal("0"),
      tolerance_abs_eth: BigDecimal(target) * BigDecimal(position.hedge.tolerance.to_s),
      inside_tolerance: true
    }
  end
end
