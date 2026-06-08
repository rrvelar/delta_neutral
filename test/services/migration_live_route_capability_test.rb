require "test_helper"

class MigrationLiveRouteCapabilityTest < ActiveSupport::TestCase
  test "extended ethereal route is ready for random but blocked for live without live gates" do
    report = registry.report
    route = report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "ethereal" }

    assert_equal true, route.fetch(:dry_run_ready)
    assert_equal true, route.fetch(:ready_for_random)
    assert_equal true, route.fetch(:live_path_implemented)
    assert_equal true, route.fetch(:live_canary_confirmed)
    assert_equal false, route.fetch(:live_autopilot_eligible)
    assert_empty route.fetch(:blockers)
    assert_equal 0, route.fetch(:orders_submitted)
    assert_equal 0, route.fetch(:signatures_created)
  end

  test "extended ethereal can become eligible with live gates" do
    report = registry(
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true"
      }
    ).report
    route = report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "ethereal" }

    assert_equal true, route.fetch(:live_canary_confirmed)
    assert_equal true, route.fetch(:live_autopilot_eligible)
  end

  test "nado routes are ready but require Nado live gates for live autopilot" do
    route = registry.report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "nado" }

    assert_equal true, route.fetch(:live_path_implemented)
    assert_equal true, route.fetch(:ready_for_random)
    assert_equal false, route.fetch(:live_autopilot_eligible)
    assert_empty route.fetch(:blockers)
    assert_includes route.fetch(:required_gates), "AERODROME_NADO_HEDGE_LIVE_ENABLED=true"
  end

  private

  def registry(env: {}, canary_checker: nil)
    MigrationLiveRouteCapability.new(
      position: position,
      route_matrix: route_matrix,
      canary_checker: canary_checker,
      env: env
    )
  end

  def route_matrix
    {
      routes: [
        route("extended", "ethereal", "READY_FOR_DRY_RUN"),
        route("ethereal", "extended", "READY_FOR_DRY_RUN"),
        route("extended", "nado", "READY_FOR_DRY_RUN")
      ]
    }
  end

  def route(from, to, status)
    { from_venue: from, to_venue: to, route_status: status, preview_available: true, blockers: [] }
  end

  def position
    @position ||= begin
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
      position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
      position
    end
  end
end
