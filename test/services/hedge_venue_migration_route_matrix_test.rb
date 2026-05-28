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
      assert_includes %w[NOT_IMPLEMENTED PREVIEW_BLOCKED], item.fetch(:route_status)
      assert_includes item.fetch(:blockers), "Nado migration readiness is not proven."
    end
  end

  test "Extended to Nado route uses readiness and can expose dry run target leg preview" do
    service = FakeNadoService.new(current_position: nil)
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position, nado_service: service).report
    item = route(matrix, "extended", "nado")

    assert_equal true, item.fetch(:preview_available)
    assert_equal false, item.fetch(:live_available)
    assert_equal "READY_FOR_DRY_RUN", item.fetch(:route_status)
    assert_equal "blocked_for_live", item.fetch(:readiness_status)
    assert_equal "0.0", item.dig(:nado_readiness, :nado_current_short_eth)
    assert_not_includes item.fetch(:blockers), "Nado open orders readback is unavailable."
    assert_equal 0, item.dig(:nado_readiness, :nado_open_orders_count)
  end

  test "Nado target route blocks when open orders are present" do
    service = FakeNadoService.new(current_position: nil, open_orders_count: 1)
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position, nado_service: service).report
    item = route(matrix, "extended", "nado")

    assert_equal false, item.fetch(:preview_available)
    assert_equal false, item.fetch(:live_available)
    assert_equal "PREVIEW_BLOCKED", item.fetch(:route_status)
    assert_includes item.fetch(:blockers), "Nado open orders must be zero for migration proof."
    assert_equal 1, item.dig(:nado_readiness, :nado_open_orders_count)
  end

  test "Nado to Extended route uses readiness and can expose dry run source leg preview" do
    service = FakeNadoService.new(current_position: { short_size: BigDecimal("0.4"), size: BigDecimal("-0.4") })
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position, nado_service: service).report
    item = route(matrix, "nado", "extended")

    assert_equal true, item.fetch(:preview_available)
    assert_equal false, item.fetch(:live_available)
    assert_equal "READY_FOR_DRY_RUN", item.fetch(:route_status)
    assert_equal "0.4", item.dig(:nado_readiness, :nado_current_short_eth)
  end

  test "Nado source route with flat Nado blocks with source flat blocker" do
    service = FakeNadoService.new(current_position: nil)
    matrix = HedgeVenueMigrationRouteMatrix.new(position: migration_position, nado_service: service).report
    item = route(matrix, "nado", "extended")

    assert_equal false, item.fetch(:preview_available)
    assert_equal false, item.fetch(:live_available)
    assert_equal "PREVIEW_BLOCKED", item.fetch(:route_status)
    assert_includes item.fetch(:blockers), "source venue Nado has no current short to migrate."
  end

  test "proof receipts are written with zero orders and signatures" do
    Dir.mktmpdir do |dir|
      summary = HedgeVenueMigrationRouteMatrix.new(position: migration_position, receipt_dir: dir).prove_routes!
      path = summary.fetch(:receipt_paths).first
      rows = File.readlines(path).map { |line| JSON.parse(line) }

      assert_equal 24, summary.fetch(:receipts_written)
      assert rows.any? { |row| row["from_venue"] == "extended" && row["to_venue"] == "ethereal" && row["planned_first_leg"].present? }
      assert rows.any? { |row| row["to_venue"] == "nado" && row["nado_readiness"].present? }
      assert rows.any? { |row| row["from_venue"] == "nado" && row["nado_readiness"].key?("nado_reduce_only_close_preview_available") }
      rows.each do |row|
        assert_equal "migration_route_proof", row.fetch("action")
        assert_equal 0, row.fetch("orders_submitted")
        assert_equal 0, row.fetch("orders_placed")
        assert_equal 0, row.fetch("signatures_created")
        assert_no_match HedgeVenueMigrationExecutor::CONFIRMATION, row.to_json
      end
    end
  end

  test "proof receipts include Nado source leg preview when current Nado short exists" do
    Dir.mktmpdir do |dir|
      service = FakeNadoService.new(current_position: { short_size: BigDecimal("0.4"), size: BigDecimal("-0.4") })
      summary = HedgeVenueMigrationRouteMatrix.new(position: migration_position, receipt_dir: dir, nado_service: service).prove_routes!
      rows = File.readlines(summary.fetch(:receipt_paths).first).map { |line| JSON.parse(line) }
      receipt = rows.find { |row| row["from_venue"] == "nado" && row["to_venue"] == "extended" && row["mode"] == "full" }

      assert receipt
      assert_equal "close_short", receipt.fetch("planned_source_leg").fetch("action")
      assert_equal "buy", receipt.fetch("planned_source_leg").fetch("side")
      assert_equal true, receipt.fetch("planned_source_leg").fetch("reduce_only")
      assert_equal "0.4", receipt.fetch("planned_source_leg").fetch("size_eth")
      assert_equal 0, receipt.fetch("orders_submitted")
      assert_equal 0, receipt.fetch("signatures_created")
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

  class FakeNadoService
    def initialize(current_position:, open_orders_count: 0)
      @current_position = current_position
      @open_orders_count = open_orders_count
    end

    def read_position
      @current_position
    end

    def account_state
      {
        open_orders_count: @open_orders_count,
        open_orders_read_diagnostics: { endpoint_path: "/query", query_type: "subaccount_orders", query_keys: %w[type sender product_id] },
        blockers: [],
        warnings: []
      }
    end

    def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position:)
      reduce_only = action == "close" || BigDecimal(size_eth.to_s).negative?
      {
        ok: true,
        summary: {
          venue: "Nado",
          symbol: "ETH-PERP",
          action: action,
          side: reduce_only ? "buy" : "sell",
          reduce_only: reduce_only,
          rounded_size_eth: BigDecimal(size_eth.to_s).abs.to_s("F"),
          rounded_price: "2400",
          estimated_notional_usd: "960",
          product_id: 4,
          order_type: "ioc",
          margin_mode: "isolated"
        },
        blockers: [],
        warnings: []
      }
    end
  end
end
