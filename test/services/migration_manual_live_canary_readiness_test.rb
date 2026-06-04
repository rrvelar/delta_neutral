require "test_helper"

class MigrationManualLiveCanaryReadinessTest < ActiveSupport::TestCase
  test "readiness reports blockers and read only counters" do
    report = MigrationManualLiveCanaryReadiness.new(position: position, from: "extended", to: "ethereal", capability_registry: capability_registry, target_preflight: { blockers: [] }).report

    assert_equal "manual_live_canary_readiness", report.fetch(:action)
    assert_equal "extended->ethereal", report.fetch(:route)
    assert_equal false, report.fetch(:ready_for_supervised_canary)
    assert_equal false, report.fetch(:canary_already_confirmed)
    assert_equal "target_first", report.fetch(:recommended_sequence)
    assert_equal false, report.fetch(:source_first_supported)
    assert_equal false, report.fetch(:source_first_allowed)
    assert_includes report.fetch(:blockers), "MIGRATION_LIVE_ENABLED must be true for supervised live canary."
    assert_not_includes report.fetch(:blockers), "source_first locked by default; target_first is the only recommended live sequence."
    assert_not_includes report.fetch(:blockers), "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal."
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "source first requested explicitly remains blocked without source first gate" do
    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "ethereal",
      capability_registry: capability_registry,
      target_preflight: { blockers: [] },
      sequence: "source_first"
    ).report

    assert_equal "source_first", report.fetch(:requested_sequence)
    assert_includes report.fetch(:blockers), "source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true"
  end

  test "Extended to Ethereal readiness blocks when source Extended auto is enabled" do
    env = {
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "true",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"
    }

    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "ethereal",
      env: env,
      capability_registry: capability_registry,
      target_preflight: { blockers: [] }
    ).report

    assert_includes report.fetch(:blockers), "source venue auto must be disabled during migration canary: extended"
    assert_not_includes report.fetch(:blockers), "target venue auto must be disabled during migration canary: ethereal"
    assert_not_includes report.fetch(:blockers), "source_first locked by default; target_first is the only recommended live sequence."
  end

  test "Extended to Ethereal readiness has no auto blocker when both autos are disabled" do
    env = {
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"
    }

    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "ethereal",
      env: env,
      capability_registry: capability_registry,
      target_preflight: { blockers: [] }
    ).report

    assert_not_includes report.fetch(:blockers), "source venue auto must be disabled during migration canary: extended"
    assert_not_includes report.fetch(:blockers), "target venue auto must be disabled during migration canary: ethereal"
  end

  test "Ethereal to Extended readiness blocks when source Ethereal auto is enabled" do
    ethereal_position = position
    ethereal_position.hedge.update!(execution_venue: "ethereal")
    ethereal_position.position_dashboard_snapshot.update!(extended_short_eth: "0", ethereal_short_eth: "1.0", production_venue: "ethereal")
    registry = Class.new do
      def report
        { routes: [ { from_venue: "ethereal", to_venue: "extended", live_path_implemented: true, live_canary_confirmed: false, blockers: [] } ] }
      end
    end.new

    report = MigrationManualLiveCanaryReadiness.new(
      position: ethereal_position,
      from: "ethereal",
      to: "extended",
      env: {
        "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "true",
        "EXTENDED_AUTO_REBALANCE_ENABLED" => "false"
      },
      capability_registry: registry,
      target_preflight: { blockers: [] }
    ).report

    assert_includes report.fetch(:blockers), "source venue auto must be disabled during migration canary: ethereal"
    assert_not_includes report.fetch(:blockers), "target venue auto must be disabled during migration canary: extended"
  end

  test "Ethereal to Extended target leg preflight does not require production venue already extended" do
    ethereal_position = position
    ethereal_position.hedge.update!(execution_venue: "ethereal")
    ethereal_position.position_dashboard_snapshot.update!(extended_short_eth: "0", ethereal_short_eth: "1.0", production_venue: "ethereal")
    registry = Class.new do
      def report
        { routes: [ { from_venue: "ethereal", to_venue: "extended", live_path_implemented: true, live_canary_confirmed: false, blockers: [] } ] }
      end
    end.new

    report = MigrationManualLiveCanaryReadiness.new(position: ethereal_position, from: "ethereal", to: "extended", capability_registry: registry).report

    assert_equal "ethereal->extended", report.fetch(:route)
    assert_not report.fetch(:target_leg_blockers).any? { |blocker| blocker.to_s.include?("execution_venue") || blocker.to_s.include?("selected hedge execution venue") }
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

  test "readiness uses fresh HedgeFreshTarget and blocks when unavailable" do
    target = Struct.new(:payload) do
      def resolve(refresh_if_stale:)
        payload.merge(refresh_if_stale: refresh_if_stale)
      end
    end.new({
      status: "blocked",
      target_short_eth: nil,
      blockers: [ "fresh Mellow exposure required before hedge sizing" ],
      orders_submitted: 0,
      signatures_created: 0
    })

    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "ethereal",
      capability_registry: capability_registry,
      target_preflight: { blockers: [] },
      fresh_target: target
    ).report

    assert_equal "blocked", report.fetch(:fresh_target_status)
    assert_nil report.fetch(:target_short)
    assert_includes report.fetch(:blockers), "fresh Mellow exposure required before hedge sizing"
    assert_includes report.fetch(:blockers), "fresh Mellow target is required before supervised canary."
  end

  test "nado readiness uses canonical planner blockers instead of blanket not implemented" do
    report = MigrationManualLiveCanaryReadiness.new(position: position, from: "extended", to: "nado", capability_registry: capability_registry, target_preflight: { blockers: [] }).report

    assert_equal true, report.fetch(:live_path_implemented)
    assert_not_includes report.fetch(:blockers), "Nado live migration path not implemented."
    assert_includes report.fetch(:blockers), "MIGRATION_LIVE_ENABLED must be true for supervised live canary."
  end

  test "Aerodrome direct Extended to Nado readiness does not require Mellow Autopilot" do
    report = MigrationManualLiveCanaryReadiness.new(
      position: position,
      from: "extended",
      to: "nado",
      env: ready_nado_env,
      capability_registry: capability_registry,
      target_preflight: { blockers: [] }
    ).report

    assert_equal "extended->nado", report.fetch(:route)
    assert_equal true, report.fetch(:live_path_implemented)
    assert_not_includes report.fetch(:blockers), "active hedge-ready Mellow Autopilot position is required"
    assert_not_includes report.fetch(:blockers), "fresh Mellow target is required before supervised canary."
  end

  test "Mellow Autopilot positions can still require Mellow hedge readiness" do
    mellow = position
    mellow.update!(source: Position::SOURCE_MELLOW_AUTOPILOT, mellow_metadata: { hedge_ready: false }.to_json)

    report = MigrationManualLiveCanaryReadiness.new(
      position: mellow,
      from: "extended",
      to: "nado",
      env: ready_nado_env,
      capability_registry: capability_registry,
      fresh_target: Struct.new(:target) {
        def resolve(refresh_if_stale:)
          {
            status: "ok",
            target_short_eth: BigDecimal(target),
            target_source: "test",
            exposure_source: "test",
            exposure_refreshed_at: Time.current.iso8601,
            exposure_stale: false,
            blockers: [],
            orders_submitted: 0,
            signatures_created: 0
          }
        end
      }.new("1.0"),
      target_preflight: { blockers: [ "active hedge-ready Mellow Autopilot position is required" ] }
    ).report

    assert_includes report.fetch(:blockers), "active hedge-ready Mellow Autopilot position is required"
  end

  private

  def ready_nado_env
    {
      "MIGRATION_LIVE_ENABLED" => "true",
      "MIGRATION_MANUAL_LIVE_CANARY_ENABLED" => "true",
      "MIGRATION_FULL_ALLOWED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def capability_registry
    Class.new do
      def report
        {
          routes: [
            { from_venue: "extended", to_venue: "ethereal", live_path_implemented: true, live_canary_confirmed: false, blockers: [ "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal." ] },
            { from_venue: "extended", to_venue: "nado", live_path_implemented: true, live_canary_confirmed: false, blockers: [ "LIVE_CANARY_CONFIRMED receipt is required for extended->nado." ] }
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
