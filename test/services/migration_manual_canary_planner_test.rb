require "test_helper"

class MigrationManualCanaryPlannerTest < ActiveSupport::TestCase
  test "extended to ethereal target first is ready under clean canonical state" do
    report = planner.report

    assert_equal true, report.fetch(:ready_for_supervised_canary), report.fetch(:blockers).inspect
    assert_empty report.fetch(:blockers)
    assert_equal "extended->ethereal", report.fetch(:route)
    assert_equal "target_first", report.fetch(:requested_sequence)
    assert_equal "0.977", report.fetch(:current_source_short)
    assert_equal "0.9884587950517357", report.fetch(:target_short_eth)
    assert_equal "ethereal", report.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "extended", report.fetch(:planned_second_leg).fetch(:venue)
    assert_equal [], report.fetch(:target_leg_blockers)
    assert_equal [], report.fetch(:source_close_preflight_blockers)
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "source first is blocked by the canonical planner" do
    report = planner(sequence: "source_first").report

    assert_equal false, report.fetch(:ready_for_supervised_canary)
    assert_equal false, report.fetch(:source_first_supported)
    assert_equal false, report.fetch(:source_first_allowed)
    assert_includes report.fetch(:blockers), "source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true"
  end

  test "ethereal to extended blocks while Ethereal source is flat" do
    position.hedge.update!(execution_venue: "ethereal")
    position.position_dashboard_snapshot.update!(production_venue: "ethereal", extended_short_eth: "0", ethereal_short_eth: "0")

    report = planner(from: "ethereal", to: "extended").report

    assert_equal false, report.fetch(:ready_for_supervised_canary)
    assert_includes report.fetch(:blockers), "source venue must have a real short before canary."
  end

  test "all directed target first routes are represented by canonical planner" do
    routes = [
      [ "extended", "ethereal" ],
      [ "ethereal", "extended" ],
      [ "extended", "nado" ],
      [ "nado", "extended" ],
      [ "ethereal", "nado" ],
      [ "nado", "ethereal" ]
    ]

    routes.each do |from, to|
      position_for_route(from)
      report = planner(from: from, to: to).report

      assert_equal "#{from}->#{to}", report.fetch(:route)
      assert_equal true, report.fetch(:live_path_implemented)
      assert_equal "target_first", report.fetch(:recommended_sequence)
      assert_equal 0, report.fetch(:orders_submitted)
      assert_equal 0, report.fetch(:signatures_created)
    end
  end

  test "extended to nado can be ready when mocked Nado target preflight is clean" do
    report = planner(from: "extended", to: "nado").report

    assert_equal true, report.fetch(:ready_for_supervised_canary), report.fetch(:blockers).inspect
    assert_empty report.fetch(:blockers)
    assert_equal "nado", report.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "extended", report.fetch(:planned_second_leg).fetch(:venue)
  end

  test "nado to ethereal can be ready when Nado source short exists" do
    position_for_route("nado")
    report = planner(from: "nado", to: "ethereal").report

    assert_equal true, report.fetch(:ready_for_supervised_canary), report.fetch(:blockers).inspect
    assert_empty report.fetch(:blockers)
    assert_equal "ethereal", report.fetch(:planned_first_leg).fetch(:venue)
    assert_equal "nado", report.fetch(:planned_second_leg).fetch(:venue)
  end

  private

  def planner(from: "extended", to: "ethereal", sequence: "target_first")
    MigrationManualCanaryPlanner.new(
      position: position,
      from: from,
      to: to,
      env: ready_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      sequence: sequence
    )
  end

  def fresh_target
    Struct.new(:target) do
      def resolve(refresh_if_stale:)
        {
          status: "ok",
          target_short_eth: BigDecimal(target),
          target_source: "current_share_token_resolver",
          exposure_source: "current_share_token_resolver",
          exposure_refreshed_at: Time.current.iso8601,
          exposure_stale: false,
          blockers: [],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end.new("0.9884587950517357")
  end

  def ready_env
    {
      "MIGRATION_LIVE_ENABLED" => "true",
      "MIGRATION_MANUAL_LIVE_CANARY_ENABLED" => "true",
      "MIGRATION_FULL_ALLOWED" => "true",
      "MIGRATION_SOURCE_FIRST_CANARY_ALLOWED" => "false",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
    }
  end

  def position_for_route(source)
    position.hedge.update!(execution_venue: source)
    position.position_dashboard_snapshot.update!(
      production_venue: source,
      extended_short_eth: source == "extended" ? "0.977" : "0",
      ethereal_short_eth: source == "ethereal" ? "0.977" : "0",
      nado_short_eth: source == "nado" ? "0.977" : "0",
      combined_short_eth: "0.977",
      open_orders_count_extended: 0
    )
  end

  def position
    @position ||= begin
      current = Position.create!(
        user: users(:one),
        wallet: wallets(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: "0.9884587950517357",
        asset1_amount: "1000",
        asset0_price_usd: "2000",
        asset1_price_usd: "1",
        external_id: SecureRandom.hex(4),
        active: true
      )
      current.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
      current.create_position_dashboard_snapshot!(
        refreshed_at: Time.current,
        refresh_status: "ok",
        stale: false,
        production_venue: "extended",
        target_short_eth: "0.9884587950517357",
        tolerance_abs_eth: "0.029653763851552071",
        combined_short_eth: "0.977",
        drift_eth: "0.0114587950517357",
        inside_tolerance: true,
        extended_short_eth: "0.977",
        ethereal_short_eth: "0",
        nado_short_eth: "0",
        open_orders_count_extended: 0
      )
      current
    end
  end
end
