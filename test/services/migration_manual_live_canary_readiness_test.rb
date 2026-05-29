require "test_helper"

class MigrationManualLiveCanaryReadinessTest < ActiveSupport::TestCase
  test "readiness reports blockers and read only counters" do
    report = MigrationManualLiveCanaryReadiness.new(position: position, from: "extended", to: "ethereal", capability_registry: capability_registry, target_preflight: { blockers: [] }).report

    assert_equal "manual_live_canary_readiness", report.fetch(:action)
    assert_equal "extended->ethereal", report.fetch(:route)
    assert_equal false, report.fetch(:ready_for_supervised_canary)
    assert_equal false, report.fetch(:canary_already_confirmed)
    assert_equal "target_first", report.fetch(:recommended_sequence)
    assert_includes report.fetch(:blockers), "MIGRATION_LIVE_ENABLED must be true for supervised live canary."
    assert_not_includes report.fetch(:blockers), "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal."
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "manual canary readiness exposes target leg blocker before source close" do
    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "ethereal",
      capability_registry: capability_registry,
      target_preflight: { blockers: [ "active hedge-ready Mellow position is required" ] }
    ).report

    assert_includes report.fetch(:target_leg_blockers), "active hedge-ready Mellow position is required"
    assert_includes report.fetch(:blockers), "active hedge-ready Mellow position is required"
  end

  test "nado readiness reports live path blocker" do
    report = MigrationManualLiveCanaryReadiness.new(position: position, from: "extended", to: "nado", capability_registry: capability_registry).report

    assert_includes report.fetch(:blockers), "Nado live migration path not implemented."
  end

  private

  def capability_registry
    Class.new do
      def report
        {
          routes: [
            { from_venue: "extended", to_venue: "ethereal", live_path_implemented: true, live_canary_confirmed: false, blockers: [ "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal." ] },
            { from_venue: "extended", to_venue: "nado", live_path_implemented: false, live_canary_confirmed: false, blockers: [ "Nado live migration path not implemented." ] }
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
      position.create_position_dashboard_snapshot!(
        refreshed_at: Time.current,
        refresh_status: "ok",
        production_venue: "extended",
        target_short_eth: "1.0",
        extended_short_eth: "1.0",
        ethereal_short_eth: "0",
        nado_short_eth: "0"
      )
      position
    end
  end
end
