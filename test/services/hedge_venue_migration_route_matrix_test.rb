require "test_helper"

class HedgeVenueMigrationRouteMatrixTest < ActiveSupport::TestCase
  test "route matrix includes all directed routes" do
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position).report
    routes = matrix.fetch(:routes).map { |route| [ route.fetch(:from_venue), route.fetch(:to_venue) ] }

    assert_equal [
      [ "extended", "ethereal" ],
      [ "ethereal", "extended" ],
      [ "extended", "nado" ],
      [ "nado", "extended" ],
      [ "ethereal", "nado" ],
      [ "nado", "ethereal" ]
    ], routes
  end

  test "Extended to Ethereal and Ethereal to Extended are preview capable" do
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position).report

    assert_equal true, route(matrix, "extended", "ethereal").fetch(:preview_available)
    assert_equal true, route(matrix, "ethereal", "extended").fetch(:preview_available)
  end

  test "Nado routes are visible but blocked" do
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position).report

    [
      [ "extended", "nado" ],
      [ "nado", "extended" ],
      [ "ethereal", "nado" ],
      [ "nado", "ethereal" ]
    ].each do |from, to|
      item = route(matrix, from, to)
      assert_equal false, item.fetch(:supported)
      assert_equal false, item.fetch(:preview_available)
      assert_equal "NOT_IMPLEMENTED", item.fetch(:route_status)
      assert_includes item.fetch(:blockers), "Nado migration readiness is not proven."
    end
  end

  test "proof receipts are written with zero orders and signatures" do
    Dir.mktmpdir do |dir|
      summary = HedgeVenueMigrationRouteMatrix.new(position: migration_position, receipt_dir: dir).prove_routes!
      path = summary.fetch(:receipt_paths).first
      rows = File.readlines(path).map { |line| JSON.parse(line) }

      assert_equal 24, summary.fetch(:receipts_written)
      assert rows.any? { |row| row["from_venue"] == "extended" && row["to_venue"] == "ethereal" && row["planned_first_leg"].present? }
      rows.each do |row|
        assert_equal "migration_route_proof", row.fetch("action")
        assert_equal 0, row.fetch("orders_submitted")
        assert_equal 0, row.fetch("orders_placed")
        assert_equal 0, row.fetch("signatures_created")
        assert_no_match HedgeVenueMigrationExecutor::CONFIRMATION, row.to_json
      end
    end
  end

  private

  def route(matrix, from, to)
    matrix.fetch(:routes).find { |item| item.fetch(:from_venue) == from && item.fetch(:to_venue) == to }
  end

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
    snapshot_for(position)
    position
  end

  def snapshot_for(position)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: position.hedge.execution_venue,
      selected_venue: position.hedge.execution_venue,
      target_short_eth: "0.8",
      tolerance_ratio: position.hedge.tolerance,
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0.8",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "active",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 0,
      leverage_margin_gate_status: "pass"
    )
  end
end
