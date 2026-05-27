require "test_helper"

class HedgeVenueAutoMigrationPlannerTest < ActiveSupport::TestCase
  test "auto migration planner is decision only and disabled by default" do
    position = migration_position

    result = HedgeVenueAutoMigrationPlanner.new(env: {}).plan(position: position, recommended_venue: "ethereal", reason: "venue review")

    assert_equal false, result.would_migrate
    assert_includes result.blockers, "MIGRATION_AUTO_ENABLED must be true"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "daily and cooldown limits are enforced in decision planner" do
    position = migration_position
    now = Time.zone.local(2026, 5, 27, 12, 0, 0)
    events = [ { timestamp: (now - 1.hour).iso8601 } ]
    env = {
      "MIGRATION_AUTO_ENABLED" => "true",
      "MIGRATION_ALLOWED_FROM_VENUES" => "extended",
      "MIGRATION_ALLOWED_TO_VENUES" => "ethereal",
      "MIGRATION_MAX_PER_DAY" => "1",
      "MIGRATION_MIN_COOLDOWN_HOURS" => "12"
    }

    result = HedgeVenueAutoMigrationPlanner.new(env: env, now: -> { now }, migration_events: events).plan(position: position, recommended_venue: "ethereal", reason: "operator policy")

    assert_equal false, result.would_migrate
    assert_includes result.blockers, "daily migration limit reached"
    assert result.blockers.any? { |blocker| blocker.start_with?("migration cooldown remaining") }
  end

  test "auto migration planner refuses Nado routes without route proof ready" do
    position = migration_position
    env = {
      "MIGRATION_AUTO_ENABLED" => "true",
      "MIGRATION_AUTO_DRY_RUN_ONLY" => "false",
      "MIGRATION_REASON_REQUIRED" => "false",
      "MIGRATION_ALLOWED_VENUES" => "extended,ethereal,nado",
      "MIGRATION_REQUIRE_ROUTE_PROOF" => "true",
      "MIGRATION_MAX_PER_DAY" => "2",
      "MIGRATION_MIN_COOLDOWN_HOURS" => "0"
    }

    result = HedgeVenueAutoMigrationPlanner.new(env: env, route_proof_events: []).plan(position: position, recommended_venue: "nado", reason: "daily rotation")

    assert_equal false, result.would_migrate
    assert_equal "extended->nado", result.receipt.fetch(:proposed_route)
    assert_equal "missing", result.receipt.fetch(:route_proof_status)
    assert_includes result.blockers, "Nado route proof is not ready; Nado cannot be selected for future live migration"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  private

  def migration_position
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
    position
  end
end
