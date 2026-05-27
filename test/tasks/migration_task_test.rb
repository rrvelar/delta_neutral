require "test_helper"
require "rake"

class MigrationTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("migration:prove_routes")
    Rake::Task["migration:prove_routes"].reenable
  end

  test "prove routes task writes JSONL proof receipts" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    receipt_path = Rails.root.join("storage/hedge_migration_route_proofs/#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0

    out, = capture_io { Rake::Task["migration:prove_routes"].invoke }

    summary = JSON.parse(out)
    assert_equal "migration_route_proof_summary", summary.fetch("action")
    assert_equal position.id, summary.fetch("position_id")
    assert_equal 24, summary.fetch("receipts_written")
    lines = File.readlines(receipt_path)
    assert_operator lines.size, :>, before_lines
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "migration_route_proof" }
    assert receipt
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
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
end
