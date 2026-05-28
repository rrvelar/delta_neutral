require "test_helper"
require "rake"

class MigrationTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("migration:prove_routes")
    Rake::Task["migration:prove_routes"].reenable
    Rake::Task["migration:random_rotation_decision"].reenable if Rake::Task.task_defined?("migration:random_rotation_decision")
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
    assert_equal false, summary.fetch("snapshot_refreshed_before_proof")
    assert_equal "fresh", summary.fetch("snapshot_status_at_start")
    assert_equal true, summary.fetch("route_plans_used_fresh_snapshot")
    assert_operator summary.fetch("proof_duration_seconds"), :>=, 0
    lines = File.readlines(receipt_path)
    assert_operator lines.size, :>, before_lines
    receipt = lines.reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "migration_route_proof" }
    assert receipt
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
  end

  test "prove routes task refreshes stale snapshot before proof" do
    position = migration_position(refreshed_at: 10.minutes.ago)
    ENV["position_id"] = position.id.to_s
    refresh_calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:, force: false) { route_proof_refresher(position, force, refresh_calls) }) do
      out, = capture_io { Rake::Task["migration:prove_routes"].invoke }
      summary = JSON.parse(out)
      route = summary.fetch("routes").find { |row| row["from_venue"] == "extended" && row["to_venue"] == "ethereal" }

      assert_equal [ true ], refresh_calls
      assert_equal true, summary.fetch("snapshot_refreshed_before_proof")
      assert_operator summary.fetch("snapshot_age_seconds_at_start"), :<, 5
      assert_equal "fresh", summary.fetch("snapshot_status_at_start")
      assert_equal true, summary.fetch("route_plans_used_fresh_snapshot")
      assert_not_includes route.fetch("blockers"), "Position dashboard snapshot is stale; refresh read-only data before planning migration."
      assert_equal 0, summary.fetch("orders_submitted")
      assert_equal 0, summary.fetch("signatures_created")
    end
  ensure
    ENV.delete("position_id")
  end

  test "prove routes task refreshes incomplete snapshot before proof" do
    position = migration_position
    position.position_dashboard_snapshot.update!(target_short_eth: nil, drift_eth: nil, inside_tolerance: nil)
    ENV["position_id"] = position.id.to_s
    refresh_calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:, force: false) { route_proof_refresher(position, force, refresh_calls) }) do
      out, = capture_io { Rake::Task["migration:prove_routes"].invoke }
      summary = JSON.parse(out)
      route = summary.fetch("routes").find { |row| row["from_venue"] == "extended" && row["to_venue"] == "ethereal" }

      assert_equal [ true ], refresh_calls
      assert_equal true, summary.fetch("snapshot_refreshed_before_proof")
      assert_match "incomplete", summary.fetch("snapshot_refresh_reason")
      assert_equal true, summary.fetch("route_plans_used_complete_snapshot")
      assert_empty summary.fetch("snapshot_missing_fields")
      assert_not_includes route.fetch("blockers"), "target short is unavailable in dashboard snapshot"
      assert_not_includes route.fetch("blockers"), "planned migration size is zero"
    end
  ensure
    ENV.delete("position_id")
  end

  test "prove routes reports fresh start separately from stale end" do
    now = Time.zone.local(2026, 5, 28, 12, 0, 0)
    position = migration_position(refreshed_at: now - 119.seconds)
    ENV["position_id"] = position.id.to_s
    calls = 0

    Time.stub(:current, -> {
      calls += 1
      calls <= 3 ? now : now + 5.seconds
    }) do
      out, = capture_io { Rake::Task["migration:prove_routes"].invoke }
      summary = JSON.parse(out)
      route = summary.fetch("routes").find { |row| row["from_venue"] == "extended" && row["to_venue"] == "ethereal" }

      assert_equal "fresh", summary.fetch("snapshot_status_at_start")
      assert_equal "stale", summary.fetch("snapshot_status_at_end")
      assert_equal true, summary.fetch("route_plans_used_fresh_snapshot")
      assert_not_includes route.fetch("blockers"), "Position dashboard snapshot is stale; refresh read-only data before planning migration."
    end
  ensure
    ENV.delete("position_id")
  end

  test "random rotation decision task writes decision receipt" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    receipt_path = Rails.root.join("storage/hedge_migration_random_rotation/#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    before_lines = File.exist?(receipt_path) ? File.readlines(receipt_path).size : 0

    out, = capture_io { Rake::Task["migration:random_rotation_decision"].invoke }
    summary = JSON.parse(out)

    assert_equal "random_rotation_decision", summary.fetch("action")
    assert_equal position.id, summary.fetch("position_id")
    assert_equal "random_rotation", summary.fetch("strategy")
    assert_equal false, summary.fetch("would_migrate")
    assert summary.key?("dry_run_eligible_routes")
    assert summary.key?("live_eligible_routes")
    assert summary.key?("live_blocked_routes")
    assert_equal false, summary.fetch("selected_route_live_available") if summary.fetch("selected_route")
    assert_equal 0, summary.fetch("orders_submitted")
    assert_equal 0, summary.fetch("signatures_created")
    assert_match "storage/hedge_migration_random_rotation", summary.fetch("receipt_path")
    lines = File.readlines(receipt_path).drop(before_lines)
    receipt = lines.filter_map { |line| JSON.parse(line) rescue nil }.find { |row| row["position_id"] == position.id && row["action"] == "random_rotation_decision" }
    assert receipt
    assert receipt.key?("dry_run_eligible_routes")
    assert receipt.key?("live_blocked_routes")
    assert_equal 0, receipt.fetch("orders_placed")
    assert_equal 0, receipt.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
  end

  private

  def migration_position(refreshed_at: Time.current)
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
      refreshed_at: refreshed_at,
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

  def route_proof_refresher(position, force, calls)
    Object.new.tap do |object|
      object.define_singleton_method(:refresh) do
        calls << force
        position.position_dashboard_snapshot.update!(
          refreshed_at: Time.current,
          refresh_status: "ok",
          stale: false,
          target_short_eth: position.asset0_amount * position.hedge.target,
          tolerance_abs_eth: position.asset0_amount * position.hedge.target * position.hedge.tolerance,
          combined_short_eth: position.position_dashboard_snapshot.extended_short_eth.to_d + position.position_dashboard_snapshot.ethereal_short_eth.to_d + position.position_dashboard_snapshot.nado_short_eth.to_d,
          drift_eth: (position.asset0_amount * position.hedge.target) - (position.position_dashboard_snapshot.extended_short_eth.to_d + position.position_dashboard_snapshot.ethereal_short_eth.to_d + position.position_dashboard_snapshot.nado_short_eth.to_d),
          inside_tolerance: true
        )
        position.position_dashboard_snapshot.reload
      end
    end
  end
end
