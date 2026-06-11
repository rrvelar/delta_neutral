require "test_helper"
require "rake"

class MigrationTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("migration:prove_routes")
    Rake::Task["migration:prove_routes"].reenable
    Rake::Task["migration:random_rotation_decision"].reenable if Rake::Task.task_defined?("migration:random_rotation_decision")
    Rake::Task["migration:daily_random_rotation_dry_run"].reenable if Rake::Task.task_defined?("migration:daily_random_rotation_dry_run")
    Rake::Task["migration:random_rotation_state"].reenable if Rake::Task.task_defined?("migration:random_rotation_state")
    Rake::Task["migration:reset_random_rotation_state"].reenable if Rake::Task.task_defined?("migration:reset_random_rotation_state")
    Rake::Task["migration:live_autopilot_readiness"].reenable if Rake::Task.task_defined?("migration:live_autopilot_readiness")
    Rake::Task["migration:manual_live_canary_readiness"].reenable if Rake::Task.task_defined?("migration:manual_live_canary_readiness")
    Rake::Task["migration:run_manual_live_canary"].reenable if Rake::Task.task_defined?("migration:run_manual_live_canary")
    Rake::Task["migration:route_matrix"].reenable if Rake::Task.task_defined?("migration:route_matrix")
    Rake::Task["migration:route_proofs"].reenable if Rake::Task.task_defined?("migration:route_proofs")
    Rake::Task["migration:random_readiness"].reenable if Rake::Task.task_defined?("migration:random_readiness")
    Rake::Task["migration:random_rehearse"].reenable if Rake::Task.task_defined?("migration:random_rehearse")
    Rake::Task["migration:random_production_runner"].reenable if Rake::Task.task_defined?("migration:random_production_runner")
    Rake::Task["migration:random_production_status"].reenable if Rake::Task.task_defined?("migration:random_production_status")
    Rake::Task["migration:random_production_tail"].reenable if Rake::Task.task_defined?("migration:random_production_tail")
    Rake::Task["migration:random_production_stop"].reenable if Rake::Task.task_defined?("migration:random_production_stop")
    Rake::Task["migration:canary_ladder"].reenable if Rake::Task.task_defined?("migration:canary_ladder")
    Rake::Task["migration:next_canary"].reenable if Rake::Task.task_defined?("migration:next_canary")
    Rake::Task["migration:rehearse_next_canary"].reenable if Rake::Task.task_defined?("migration:rehearse_next_canary")
    Rake::Task["migration:rehearse_route"].reenable if Rake::Task.task_defined?("migration:rehearse_route")
    Rake::Task["migration:prove_route_latency"].reenable if Rake::Task.task_defined?("migration:prove_route_latency")
    Rake::Task["migration:recover_target_first_source_close"].reenable if Rake::Task.task_defined?("migration:recover_target_first_source_close")
    Rake::Task["migration:continue_target_first_after_nado_confirmed"].reenable if Rake::Task.task_defined?("migration:continue_target_first_after_nado_confirmed")
    Rake::Task["migration:reconcile_nado_source_first"].reenable if Rake::Task.task_defined?("migration:reconcile_nado_source_first")
    Rake::Task["migration:route_policy_list"].reenable if Rake::Task.task_defined?("migration:route_policy_list")
    Rake::Task["migration:route_policy_restore_defaults"].reenable if Rake::Task.task_defined?("migration:route_policy_restore_defaults")
    Rake::Task["migration:route_policy_set"].reenable if Rake::Task.task_defined?("migration:route_policy_set")
  end

  test "random production runner task names are registered" do
    assert Rake::Task.task_defined?("migration:random_production_runner")
    assert Rake::Task.task_defined?("migration:random_production_status")
    assert Rake::Task.task_defined?("migration:random_production_tail")
    assert Rake::Task.task_defined?("migration:random_production_stop")
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

  test "daily random rotation dry run task passes enabled override and outputs read only counters" do
    calls = []
    fake_runner = Object.new
    fake_runner.define_singleton_method(:call) do |position_id:, force:, seed:, enabled_override:|
      calls << { position_id: position_id, force: force, seed: seed, enabled_override: enabled_override }
      MigrationRandomRotationDailyRunner::Result.new(
        "ok",
        [
          {
            action: "daily_random_rotation_dry_run",
            position_id: position_id.to_i,
            selected_target_venue: "nado",
            would_migrate: false,
            orders_submitted: 0,
            signatures_created: 0
          }
        ],
        [],
        [],
        0,
        0
      )
    end

    ENV["position_id"] = "3"
    ENV["enabled_override"] = "true"
    ENV["force"] = "true"
    ENV["seed"] = "test-seed"
    MigrationRandomRotationDailyRunner.stub(:new, -> { fake_runner }) do
      out, = capture_io { Rake::Task["migration:daily_random_rotation_dry_run"].invoke }
      summary = JSON.parse(out)

      assert_equal "daily_random_rotation_dry_run_summary", summary.fetch("action")
      assert_equal "ok", summary.fetch("status")
      assert_equal 0, summary.fetch("orders_submitted")
      assert_equal 0, summary.fetch("signatures_created")
      assert_equal [ { position_id: "3", force: true, seed: "test-seed", enabled_override: true } ], calls
    end
  ensure
    ENV.delete("position_id")
    ENV.delete("enabled_override")
    ENV.delete("force")
    ENV.delete("seed")
  end

  test "random rotation state task shows virtual venue and reset returns it to production" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    state = MigrationRandomRotationVirtualState.new(position: position)
    state.update_from_decision!(
      decision_receipt: {
        selected_target_venue: "nado",
        selected_route: { from_venue: "extended", to_venue: "nado" }
      }
    )

    out, = capture_io { Rake::Task["migration:random_rotation_state"].invoke }
    payload = JSON.parse(out)
    assert_equal "nado", payload.fetch("virtual_current_venue")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")

    Rake::Task["migration:reset_random_rotation_state"].reenable
    out, = capture_io { Rake::Task["migration:reset_random_rotation_state"].invoke }
    payload = JSON.parse(out)
    assert_equal "extended", payload.fetch("virtual_current_venue")
    assert_equal "nado", payload.fetch("previous_virtual_venue")
  ensure
    ENV.delete("position_id")
  end

  test "live autopilot readiness task outputs read only counters" do
    position = migration_position
    ENV["position_id"] = position.id.to_s

    out, = capture_io { Rake::Task["migration:live_autopilot_readiness"].invoke }
    payload = JSON.parse(out)

    assert_equal "live_autopilot_readiness", payload.fetch("action")
    assert_equal false, payload.fetch("would_execute_live")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
  end

  test "manual live canary readiness task outputs blockers and zero counters" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "extended"
    ENV["to"] = "ethereal"

    out, = capture_io { Rake::Task["migration:manual_live_canary_readiness"].invoke }
    payload = JSON.parse(out)

    assert_equal "manual_live_canary_readiness", payload.fetch("action")
    assert_equal "extended->ethereal", payload.fetch("route")
    assert_equal false, payload.fetch("ready_for_supervised_canary")
    assert_equal "target_first", payload.fetch("recommended_sequence")
    assert payload.key?("planned_first_leg")
    assert_not_includes payload.fetch("blockers"), "Route proof is not READY_FOR_DRY_RUN."
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
  end

  test "route matrix task outputs all six routes and zero counters" do
    position = migration_position
    ENV["position_id"] = position.id.to_s

    out, = capture_io { Rake::Task["migration:route_matrix"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_route_matrix", payload.fetch("action")
    assert_equal 6, payload.fetch("routes").size
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
  end

  test "route proofs task tracks all six route proof states" do
    position = migration_position
    ENV["position_id"] = position.id.to_s

    out, = capture_io { Rake::Task["migration:route_proofs"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_route_proofs", payload.fetch("action")
    assert_equal 6, payload.fetch("routes").size
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
  end

  test "random readiness and canary ladder expose next commands with zero counters" do
    position = migration_position
    ENV["position_id"] = position.id.to_s

    out, = capture_io { Rake::Task["migration:random_readiness"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_random_readiness", payload.fetch("action")
    assert_equal true, payload.fetch("random_engine_implemented")
    assert payload.fetch("operator_commands").fetch("random_rehearse").include?("migration:random_rehearse")
    assert payload.fetch("next_recommended_canary")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")

    Rake::Task["migration:canary_ladder"].reenable
    out, = capture_io { Rake::Task["migration:canary_ladder"].invoke }
    ladder = JSON.parse(out)
    assert_equal "migration_canary_ladder", ladder.fetch("action")
  ensure
    ENV.delete("position_id")
  end

  test "next canary task gives exact dry run and live commands" do
    position = migration_position
    ENV["position_id"] = position.id.to_s

    out, = capture_io { Rake::Task["migration:next_canary"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_next_canary", payload.fetch("action")
    assert_match(/migration:rehearse_route/, payload.fetch("operator_commands").fetch("next_canary_dry_run"))
    assert_match(/migration:run_manual_live_canary/, payload.fetch("operator_commands").fetch("next_canary_live"))
    assert_equal 0, payload.fetch("orders_submitted")
  ensure
    ENV.delete("position_id")
  end

  test "random rehearse task writes no-live receipt" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["dry_run"] = "true"
    ENV["MIGRATION_REQUIRE_ROUTE_PROOF"] = "false"
    ENV["MIGRATION_MIN_COOLDOWN_HOURS"] = "0"

    out, = capture_io { Rake::Task["migration:random_rehearse"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_random_rehearse", payload.fetch("action")
    assert_equal true, payload.fetch("dry_run")
    assert payload.key?("target_leg_preview")
    assert payload.key?("source_close_preview")
    assert_match "storage/hedge_migration_random_rehearsals", payload.fetch("receipt_path")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("dry_run")
    ENV.delete("MIGRATION_REQUIRE_ROUTE_PROOF")
    ENV.delete("MIGRATION_MIN_COOLDOWN_HOURS")
  end

  test "rehearse route writes no live receipt" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "extended"
    ENV["to"] = "ethereal"
    ENV["sequence"] = "target_first"

    out, = capture_io { Rake::Task["migration:rehearse_route"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_rehearse_route", payload.fetch("action")
    assert_equal true, payload.fetch("dry_run")
    assert_equal false, payload.fetch("live")
    assert payload.key?("readback_verification")
    assert payload.key?("recovery_plan")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
    assert_match "storage/hedge_migration_route_rehearsals", payload.fetch("receipt_path")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("sequence")
  end

  test "rehearse Nado target route blocks cleanly without internal exception" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "extended"
    ENV["to"] = "nado"
    ENV["sequence"] = "target_first"

    out, = capture_io { Rake::Task["migration:rehearse_route"].invoke }
    payload = JSON.parse(out)

    assert_equal "migration_rehearse_route", payload.fetch("action")
    assert_equal true, payload.fetch("dry_run")
    assert_no_match(/ArgumentError|BigDecimal|invalid value/, payload.to_json)
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("sequence")
    Rake::Task["migration:rehearse_route"].reenable if Rake::Task.task_defined?("migration:rehearse_route")
  end

  test "rehearse Nado source route blocks on flat source not internal exception" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "nado"
    ENV["to"] = "ethereal"
    ENV["sequence"] = "target_first"

    out, = capture_io { Rake::Task["migration:rehearse_route"].invoke }
    payload = JSON.parse(out)

    assert_includes payload.fetch("blockers"), "source venue must have a real short before canary."
    assert_no_match(/ArgumentError|BigDecimal|invalid value/, payload.to_json)
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("sequence")
    Rake::Task["migration:rehearse_route"].reenable if Rake::Task.task_defined?("migration:rehearse_route")
  end

  test "run manual live canary task blocks without gates" do
    position = migration_position
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "extended"
    ENV["to"] = "ethereal"
    ENV["confirmation"] = "wrong"

    out, = capture_io { Rake::Task["migration:run_manual_live_canary"].invoke }
    payload = JSON.parse(out)

    assert_equal "blocked_before_submit", payload.fetch("final_status")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
    assert_equal "extended", position.hedge.reload.execution_venue
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("confirmation")
  end

  test "prove route latency uses shared preflight and ignores optional dashboard partial" do
    position = migration_position
    position.hedge.update!(execution_venue: "ethereal")
    position.position_dashboard_snapshot.update!(
      refresh_status: "partial",
      production_venue: "ethereal",
      selected_venue: "ethereal",
      extended_short_eth: "0",
      ethereal_short_eth: "0.8",
      nado_short_eth: "0",
      source_errors: [ "extended optional account state timed_out=true timeout_seconds=8.0" ]
    )
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "ethereal"
    ENV["to"] = "nado"
    ENV["strategy"] = "source_first"
    ENV["live"] = "true"
    ENV["confirmation"] = "I_UNDERSTAND_THIS_RUNS_LIVE_ROUTE_LATENCY_PROOF"

    preflight = {
      status: "ready",
      accepted: true,
      can_submit: true,
      hard_blockers: [],
      blockers: [],
      warnings: [ "dashboard snapshot refresh_status=partial treated as diagnostic; direct migration preflight readbacks are authoritative" ],
      diagnostics: {},
      target: { target_short_eth: BigDecimal("0.8"), target_fresh: true, status: "ok" },
      venues: {
        "extended" => { short_eth: BigDecimal("0"), position_status: "ok", open_orders_status: "zero" },
        "ethereal" => { short_eth: BigDecimal("0.8"), position_status: "ok", open_orders_status: "zero" },
        "nado" => { short_eth: BigDecimal("0"), position_status: "ok", open_orders_status: "zero" }
      }
    }
    fake_preflight = Object.new.tap { |object| object.define_singleton_method(:report) { preflight } }
    fake_executor = Object.new.tap do |object|
      object.define_singleton_method(:run) do |execution_preflight:, **|
        raise "missing shared preflight" unless execution_preflight == preflight

        HedgeVenueMigrationExecutor::Result.new(
          "blocked_before_submit",
          [],
          preflight[:warnings],
          {
            final_status: "blocked_before_submit",
            preflight_status: execution_preflight.fetch(:status),
            preflight_hard_blockers: execution_preflight.fetch(:hard_blockers),
            preflight_warnings: execution_preflight.fetch(:warnings),
            blockers: [],
            orders_submitted: 0,
            orders_placed: 0,
            signatures_created: 0,
            cancels_submitted: 0
          }
        )
      end
    end

    MigrationExecutionPreflight.stub(:new, fake_preflight) do
      HedgeVenueMigrationExecutor.stub(:new, fake_executor) do
        out, = capture_io { Rake::Task["migration:prove_route_latency"].invoke }
        payload = JSON.parse(out)

        assert_equal "prove_route_latency", payload.fetch("action")
        assert_equal "ready", payload.fetch("preflight_status")
        assert_empty payload.fetch("preflight_hard_blockers")
        assert_includes payload.fetch("preflight_warnings"), "dashboard snapshot refresh_status=partial treated as diagnostic; direct migration preflight readbacks are authoritative"
      end
    end
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("strategy")
    ENV.delete("live")
    ENV.delete("confirmation")
  end

  test "route policy restore defaults repairs all disabled routes without runtime gates" do
    position = migration_position
    OperationalSettings::ROUTE_KEYS.each { |key| OperationalSettings.set!(key: key, enabled: false) }
    OperationalSettings::RUNTIME_GATE_KEYS.each { |key| OperationalSettings.set!(key: key, enabled: false) }
    ENV["position_id"] = position.id.to_s
    ENV["confirmation"] = MigrationRouteOperationalPolicy::RESTORE_CONFIRMATION

    out, = capture_io { Rake::Task["migration:route_policy_restore_defaults"].invoke }
    payload = JSON.parse(out)

    assert_equal true, payload.fetch("ok")
    assert_equal "ok", payload.fetch("route_policy_health")
    assert OperationalSettings::ROUTE_KEYS.all? { |key| OperationalSettings.enabled?(key) }
    assert_equal "source_first", OperationalSettings.get("MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY").raw_value
    assert_equal "target_first", OperationalSettings.get("MIGRATION_ROUTE_NADO_TO_ETHEREAL_STRATEGY").raw_value
    assert OperationalSettings::RUNTIME_GATE_KEYS.none? { |key| OperationalSettings.enabled?(key) }
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("confirmation")
  end

  test "route policy set changes only selected route policy" do
    position = migration_position
    MigrationRouteOperationalPolicy.new.restore_defaults!(confirmation: MigrationRouteOperationalPolicy::RESTORE_CONFIRMATION)
    before = OperationalSettings::ALLOWED_KEYS.to_h { |key| [ key, OperationalSettings.get(key).raw_value ] }
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "ethereal"
    ENV["to"] = "nado"
    ENV["enabled"] = "false"
    ENV["strategy"] = "manual_only"
    ENV["confirmation"] = MigrationRouteOperationalPolicy::CHANGE_CONFIRMATION

    out, = capture_io { Rake::Task["migration:route_policy_set"].invoke }
    payload = JSON.parse(out)

    assert_equal true, payload.fetch("ok")
    assert_equal "false", OperationalSettings.get("MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED").raw_value
    assert_equal "manual_only", OperationalSettings.get("MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY").raw_value
    changed = OperationalSettings::ALLOWED_KEYS.select { |key| before[key] != OperationalSettings.get(key).raw_value }
    assert_equal %w[MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY], changed
    assert_equal 0, payload.fetch("orders_placed")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("enabled")
    ENV.delete("strategy")
    ENV.delete("confirmation")
  end

  test "reconcile nado source first task uses canonical readback helper" do
    position = migration_position
    position.hedge.update!(execution_venue: "nado")
    position.position_dashboard_snapshot.update!(
      production_venue: "nado",
      selected_venue: "nado",
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0.8",
      combined_short_eth: "0.8",
      inside_tolerance: true
    )
    ENV["position_id"] = position.id.to_s
    ENV["from"] = "ethereal"
    ENV["to"] = "nado"
    ENV["digest"] = "0xnado-task"
    calls = []
    readback = {
      status: "confirmed",
      confirmed: true,
      target_confirmed: true,
      source_flat: true,
      third_venue_flat: true,
      combined_inside_tolerance: true,
      open_orders_clear: true,
      target_short_eth: "0.8",
      source_short_eth: "0",
      combined_short_eth: "0.8",
      expected_target_short_eth: "0.8",
      tolerance_eth: "0.024",
      latest_attempt: {},
      verification: { confirmed: true },
      blockers: []
    }

    NadoMigrationReadback.stub(:confirm_target_short, ->(**kwargs) { calls << kwargs; readback }) do
      out, = capture_io { Rake::Task["migration:reconcile_nado_source_first"].invoke }
      payload = JSON.parse(out)

      assert_equal 1, calls.size
      assert_equal "ethereal", calls.first.fetch(:from)
      assert_equal "nado", calls.first.fetch(:to)
      assert_equal "0xnado-task", payload.fetch("nado_target_digest")
      assert_equal true, payload.fetch("canonical_nado_readback").fetch("confirmed")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("digest")
  end

  test "recover target first source close task outputs safe blocked counters" do
    ENV["position_id"] = "999999"
    ENV["from"] = "extended"
    ENV["to"] = "ethereal"
    ENV["dry_run"] = "true"

    out, = capture_io { Rake::Task["migration:recover_target_first_source_close"].invoke }
    payload = JSON.parse(out)

    assert_equal "recover_target_first_source_close", payload.fetch("action")
    assert_equal [ "Position 999999 not found." ], payload.fetch("blockers")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("dry_run")
  end

  test "continue target first after Nado confirmed task outputs safe blocked counters" do
    ENV["position_id"] = "999999"
    ENV["from"] = "ethereal"
    ENV["to"] = "nado"
    ENV["dry_run"] = "true"

    out, = capture_io { Rake::Task["migration:continue_target_first_after_nado_confirmed"].invoke }
    payload = JSON.parse(out)

    assert_equal "continue_target_first_after_nado_confirmed", payload.fetch("action")
    assert_equal [ "Position 999999 not found." ], payload.fetch("blockers")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  ensure
    ENV.delete("position_id")
    ENV.delete("from")
    ENV.delete("to")
    ENV.delete("dry_run")
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
