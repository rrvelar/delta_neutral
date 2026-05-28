require "test_helper"

class NadoMigrationReadinessTest < ActiveSupport::TestCase
  test "readiness is read only and blocked until implemented" do
    report = NadoMigrationReadiness.new.report

    assert_equal "not_implemented", report.fetch(:status)
    assert_equal false, report.fetch(:nado_position_read_available)
    assert_equal false, report.fetch(:nado_open_short_supported)
    assert_includes report.fetch(:blockers), "Nado migration readiness is not proven."
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "readiness returns current short and flat status when readback succeeds" do
    service = FakeNadoService.new(current_position: { short_size: BigDecimal("0.4"), size: BigDecimal("-0.4") })
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "source", nado_service: service).report

    assert_equal true, report.fetch(:nado_position_read_available)
    assert_equal "0.4", report.fetch(:nado_current_short_eth)
    assert_equal false, report.fetch(:nado_flat)
    assert_equal 0, report.fetch(:nado_open_orders_count)
    assert_equal true, report.fetch(:nado_reduce_only_close_preview_available)
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
    assert_equal 1, service.preview_calls.size
  end

  test "open orders readback unavailable is explicit and non fatal" do
    service = FakeNadoService.new(current_position: nil, open_orders_count: nil, open_orders_reason: "Nado open orders endpoint unavailable in fixture.")
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "target", nado_service: service).report

    assert_equal false, report.fetch(:nado_open_orders_read_available)
    assert_nil report.fetch(:nado_open_orders_count)
    assert_equal "Nado open orders endpoint unavailable in fixture.", report.fetch(:nado_open_orders_unavailable_reason)
    assert_includes report.fetch(:blockers), "Nado open orders readback is unavailable."
    assert_includes report.fetch(:blockers), "Nado open orders endpoint unavailable in fixture."
  end

  test "open orders count greater than zero blocks readiness" do
    service = FakeNadoService.new(current_position: nil, open_orders_count: 2)
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "target", nado_service: service).report

    assert_equal true, report.fetch(:nado_open_orders_read_available)
    assert_equal 2, report.fetch(:nado_open_orders_count)
    assert_includes report.fetch(:blockers), "Nado open orders must be zero for migration proof."
  end

  test "target leg dry run preview can be built from snapshot target" do
    service = FakeNadoService.new(current_position: nil)
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "target", nado_service: service).report
    preview = report.fetch(:target_leg_preview)

    assert_equal true, report.fetch(:nado_open_short_preview_available)
    assert_equal "sell", preview.fetch(:side)
    assert_equal false, preview.fetch(:reduce_only)
    assert_equal "0.8", preview.fetch(:size_eth)
    assert_equal "0.8", preview.fetch(:expected_after_short_eth)
    assert_equal "open", service.preview_calls.first.fetch(:action)
  end

  test "source leg dry run preview can be built from Nado current short" do
    service = FakeNadoService.new(current_position: { short_size: BigDecimal("0.4"), size: BigDecimal("-0.4") })
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "source", nado_service: service).report
    preview = report.fetch(:source_leg_preview)

    assert_equal true, report.fetch(:nado_reduce_only_close_preview_available)
    assert_equal "buy", preview.fetch(:side)
    assert_equal true, preview.fetch(:reduce_only)
    assert_equal "0.4", preview.fetch(:size_eth)
    assert_equal "0.0", preview.fetch(:expected_after_short_eth)
    assert_equal "close", service.preview_calls.first.fetch(:action)
    assert_equal 0, preview.fetch(:orders_submitted)
    assert_equal 0, preview.fetch(:signatures_created)
  end

  test "stepwise source preview uses step size for Nado decrease" do
    service = FakeNadoService.new(current_position: { short_size: BigDecimal("0.4"), size: BigDecimal("-0.4") })
    with_env("MIGRATION_MAX_STEP_SIZE_ETH" => "0.05") do
      report = NadoMigrationReadiness.new(position: migration_position, intended_role: "source", mode: "stepwise", nado_service: service).report
      preview = report.fetch(:source_leg_preview)

      assert_equal "decrease_short", preview.fetch(:action)
      assert_equal "buy", preview.fetch(:side)
      assert_equal true, preview.fetch(:reduce_only)
      assert_equal "0.05", preview.fetch(:size_eth)
      assert_equal "0.35", preview.fetch(:expected_after_short_eth)
      assert_equal "rebalance", service.preview_calls.first.fetch(:action)
      assert_equal "-0.05", service.preview_calls.first.fetch(:size_eth)
    end
  end

  test "source preview can use synthetic proof short without live Nado short" do
    service = FakeNadoService.new(current_position: nil)
    report = NadoMigrationReadiness.new(position: migration_position, intended_role: "source", nado_service: service, synthetic_proof_short_eth: "0.25").report
    preview = report.fetch(:nado_source_leg_preview_proof)

    assert_equal true, report.fetch(:nado_flat)
    assert_nil report.fetch(:source_leg_preview)
    assert_equal true, report.fetch(:nado_reduce_only_close_preview_available)
    assert_equal "synthetic", report.fetch(:nado_reduce_only_close_preview_proof_mode)
    assert_equal false, report.fetch(:production_source_route_available)
    assert_equal true, report.fetch(:route_still_blocked_because_source_flat)
    assert_includes report.fetch(:blockers), "source venue Nado has no current short to migrate."
    assert_equal true, preview.fetch(:synthetic_proof)
    assert_equal true, preview.fetch(:not_current_position)
    assert_equal "0.0", preview.fetch(:production_current_short_eth)
    assert_equal true, preview.fetch(:route_still_blocked_because_source_flat)
    assert_equal "buy", preview.fetch(:side)
    assert_equal true, preview.fetch(:reduce_only)
    assert_equal "0.25", preview.fetch(:size_eth)
    assert_equal "0.0", preview.fetch(:expected_after_short_eth)
    assert_equal 0, preview.fetch(:orders_submitted)
    assert_equal 0, preview.fetch(:signatures_created)
  end

  private

  class FakeNadoService
    attr_reader :preview_calls

    def initialize(current_position:, open_orders_count: 0, open_orders_reason: nil)
      @current_position = current_position
      @open_orders_count = open_orders_count
      @open_orders_reason = open_orders_reason
      @preview_calls = []
    end

    def read_position
      @current_position
    end

    def account_state
      {
        open_orders_count: @open_orders_count,
        open_orders_unavailable_reason: @open_orders_reason,
        open_orders_read_diagnostics: { endpoint_path: "/query", query_type: "subaccount_orders", query_keys: %w[type sender product_id] },
        blockers: [],
        warnings: []
      }
    end

    def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position:)
      @preview_calls << { position_id: position.id, action: action, size_eth: size_eth.to_s, current_position: current_position, max_slippage: max_slippage.to_s }
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
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 0,
      leverage_margin_gate_status: "pass"
    )
    position
  end

  def with_env(values)
    old = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
