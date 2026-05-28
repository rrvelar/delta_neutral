require "test_helper"

class MigrationLiveRouteCapabilityTest < ActiveSupport::TestCase
  test "extended ethereal routes are implemented but blocked without canary" do
    report = registry.report
    route = report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "ethereal" }

    assert_equal true, route.fetch(:dry_run_ready)
    assert_equal true, route.fetch(:live_path_implemented)
    assert_equal false, route.fetch(:live_canary_confirmed)
    assert_equal false, route.fetch(:live_autopilot_eligible)
    assert_includes route.fetch(:blockers), "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal."
    assert_equal 0, route.fetch(:orders_submitted)
    assert_equal 0, route.fetch(:signatures_created)
  end

  test "extended ethereal can become eligible with mocked canary and gates" do
    report = registry(
      env: {
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true"
      },
      canary_checker: confirmed_canary_checker
    ).report
    route = report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "ethereal" }

    assert_equal true, route.fetch(:live_canary_confirmed)
    assert_equal true, route.fetch(:live_autopilot_eligible)
  end

  test "nado routes are not live implemented by default" do
    route = registry.report.fetch(:routes).find { |row| row[:from_venue] == "extended" && row[:to_venue] == "nado" }

    assert_equal false, route.fetch(:live_path_implemented)
    assert_equal false, route.fetch(:live_autopilot_eligible)
    assert_includes route.fetch(:blockers), "Nado live migration path not implemented."
  end

  private

  def registry(env: {}, canary_checker: missing_canary_checker)
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

  def missing_canary_checker
    Class.new do
      def status_for(from:, to:)
        {
          live_canary_confirmed: false,
          latest_canary_status: nil,
          latest_canary_receipt_path: nil,
          blockers: [ "LIVE_CANARY_CONFIRMED receipt is required for #{from}->#{to}." ],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end.new
  end

  def confirmed_canary_checker
    Class.new do
      def status_for(from:, to:)
        {
          live_canary_confirmed: from == "extended" && to == "ethereal",
          latest_canary_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
          latest_canary_receipt_path: "test.jsonl",
          blockers: from == "extended" && to == "ethereal" ? [] : [ "missing" ],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end.new
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
