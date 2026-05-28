require "test_helper"

class MigrationLiveAutopilotReadinessTest < ActiveSupport::TestCase
  test "readiness never submits or signs and reports blocked routes" do
    report = MigrationLiveAutopilotReadiness.new(position: position, route_matrix: { routes: [] }, capability_registry: capability_registry).report

    assert_equal "live_autopilot_readiness", report.fetch(:action)
    assert_equal false, report.fetch(:would_execute_live)
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
    assert_equal [], report.fetch(:live_autopilot_eligible_routes)
    assert report.fetch(:live_autopilot_blocked_routes).present?
  end

  private

  def capability_registry
    Class.new do
      def report
        {
          routes: [
            {
              from_venue: "extended",
              to_venue: "ethereal",
              live_autopilot_eligible: false,
              blockers: [ "LIVE_CANARY_CONFIRMED receipt is required." ]
            }
          ]
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
