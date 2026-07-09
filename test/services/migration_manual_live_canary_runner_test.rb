require "test_helper"

class MigrationManualLiveCanaryRunnerTest < ActiveSupport::TestCase
  test "run manual live canary blocks without env and exact phrase" do
    result = MigrationManualLiveCanaryRunner.new(receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}")).run(
      position: position,
      from: "extended",
      to: "ethereal",
      confirmation: "wrong"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationManualLiveCanaryRunner::CONFIRMATION}"
    assert_not_includes result.blockers, "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal."
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  test "source first canary blocks before source close when target preflight can fail" do
    result = MigrationManualLiveCanaryRunner.new(receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}")).run(
      position: position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION,
      sequence: "source_first"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "source_first canary is blocked until target venue live-open preflight passes and MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true"
    assert_includes result.blockers, "fresh Mellow target is required before supervised canary."
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "runner does not call executor when canonical planner blockers are present" do
    executor = Class.new do
      def run_precomputed_plan(*)
        raise "executor should not run when canonical planner is blocked"
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "fresh Mellow target is required before supervised canary."
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "runner blocks before execution if source auto is enabled" do
    executor = Class.new do
      def run_precomputed_plan(*)
        raise "executor should not run while source auto is enabled"
      end
    end.new
    ready_position = position
    ready_position.update!(
      mellow_metadata: {
        "exposure_source" => "current_share_token_resolver",
        "last_current_exposure_at" => Time.current.iso8601,
        "user_weth_exposure" => "1",
        "user_usdc_exposure" => "1000",
        "user_total_value_usd" => "3000"
      }.to_json
    )

    result = MigrationManualLiveCanaryRunner.new(
      env: { "EXTENDED_AUTO_REBALANCE_ENABLED" => "true", "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false" },
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "source venue auto must be disabled during migration canary: extended"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "runner uses canonical ready plan and does not block on stale route proof veto" do
    executor = Class.new do
      attr_reader :received_plan

      def run_precomputed_plan(position:, plan:, confirmation:)
        @received_plan = plan
        HedgeVenueMigrationExecutor::Result.new(
          "blocked_before_submit",
          [ "mock stopped before live submit" ],
          plan.fetch(:warnings),
          plan.merge(final_status: "blocked_before_submit", blockers: [ "mock stopped before live submit" ], orders_placed: 0, signatures_created: 0)
        )
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "TARGET_LEG_FAILED_SOURCE_UNCHANGED", result.status
    assert_not_includes result.blockers, "Route proof is not READY_FOR_DRY_RUN."
    assert_equal true, executor.received_plan.fetch(:ready_for_supervised_canary)
    assert_empty executor.received_plan.fetch(:blockers)
    assert_equal "0.977", executor.received_plan.fetch(:current_source_short)
    assert_equal "0.9884587950517357", executor.received_plan.fetch(:target_short_eth)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "canary receipt surfaces authoritative-fill and per-leg latency diagnostics" do
    executor = Class.new do
      def run_precomputed_plan(position:, plan:, confirmation:)
        receipt = plan.merge(
          final_status: "success", source_flat_confirmed: true, target_holds_hedge_confirmed: true,
          final_inside_tolerance: true, orders_placed: 1, signatures_created: 1,
          double_exposure_start_source: "authoritative_fill", double_exposure_end_source: "authoritative_fill",
          target_open_confirmation_source: "ethereal_order_list_open_fill",
          source_close_confirmation_source: "extended_order_by_id_fill",
          target_open_fill_readback_agreement: true, source_close_fill_readback_agreement: true,
          target_total_latency_seconds: 9.63, source_close_total_latency_seconds: 37.64,
          total_migration_latency_seconds: 51.02,
          to_leg_execution: { confirmed: true, timing: { slow_step: "readback", total_action_latency_seconds: 9.63, submit_latency_seconds: 0.79, readback_latency_seconds: 4.82, build_started_at: "2026-07-08T19:20:18.000000Z", build_finished_at: "2026-07-08T19:20:22.000000Z" } },
          from_leg_execution: { confirmed: true, timing: { slow_step: "build", total_action_latency_seconds: 37.64, submit_latency_seconds: 1.0, readback_latency_seconds: 2.36, build_started_at: "2026-07-08T19:20:28.000000Z", build_finished_at: "2026-07-08T19:21:02.000000Z" } }
        )
        HedgeVenueMigrationExecutor::Result.new("success", [], [], receipt)
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_env, target_preflight: { blockers: [] }, fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"), executor: executor
    ).run(position: ready_position, from: "extended", to: "ethereal", confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION)
    r = result.receipt

    assert_equal "authoritative_fill", r.fetch(:double_exposure_start_source)
    assert_equal "authoritative_fill", r.fetch(:double_exposure_end_source)
    assert_equal "ethereal_order_list_open_fill", r.fetch(:target_open_confirmation_source)
    assert_equal "extended_order_by_id_fill", r.fetch(:source_close_confirmation_source)
    assert_equal true, r.fetch(:source_close_fill_readback_agreement)
    assert_equal 37.64, r.fetch(:source_close_total_latency_seconds)
    assert_equal "build", r.dig(:source_leg_timing, :slow_step)
    assert_in_delta 34.0, r.dig(:source_leg_timing, :build_latency_seconds), 0.01
    assert_equal "readback", r.dig(:target_leg_timing, :slow_step)
  end

  test "runner receipt reflects live target submit when executor stops after first leg" do
    executor = Class.new do
      def run_precomputed_plan(position:, plan:, confirmation:)
        receipt = plan.merge(
          final_status: "first_leg_not_confirmed",
          to_leg_execution: { confirmed: false },
          from_leg_execution: nil,
          final_inside_tolerance: false,
          exchange_order_ids: [ "0x3845e7" ],
          orders_placed: 1,
          signatures_created: 1,
          blockers: [ "First migration leg was not confirmed; second leg was not submitted." ],
          warnings: plan.fetch(:warnings)
        )
        HedgeVenueMigrationExecutor::Result.new("first_leg_not_confirmed", receipt.fetch(:blockers), receipt.fetch(:warnings), receipt)
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "TARGET_LEG_FAILED_SOURCE_UNCHANGED", result.status
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal true, result.receipt.fetch(:would_execute_live)
    assert_equal [ "0x3845e7" ], result.receipt.fetch(:exchange_order_ids)
  end

  test "runner preserves target submitted pending status instead of relabeling as failed" do
    executor = Class.new do
      def run_precomputed_plan(position:, plan:, confirmation:)
        receipt = plan.merge(
          final_status: "TARGET_SUBMITTED_BUT_NOT_CONFIRMED",
          target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
          to_leg_execution: { confirmed: false, orders_placed: 1, signatures_created: 1, exchange_order_id: "0xpending" },
          from_leg_execution: nil,
          final_inside_tolerance: false,
          exchange_order_ids: [ "0xpending" ],
          orders_placed: 1,
          orders_submitted: 1,
          signatures_created: 1,
          recovery_command: "bin/rails migration:recover_target_first_source_close position_id=3 from=extended to=nado dry_run=true",
          blockers: [ "First migration leg was not confirmed; second leg was not submitted." ],
          warnings: plan.fetch(:warnings)
        )
        HedgeVenueMigrationExecutor::Result.new("TARGET_SUBMITTED_BUT_NOT_CONFIRMED", receipt.fetch(:blockers), receipt.fetch(:warnings), receipt)
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "TARGET_SUBMITTED_BUT_NOT_CONFIRMED", result.status
    assert_equal false, result.receipt.fetch(:target_leg_readback_confirmed)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal [ "0xpending" ], result.receipt.fetch(:exchange_order_ids)
  end

  test "runner preserves source close execution metadata from executor" do
    executor = Class.new do
      def run_precomputed_plan(position:, plan:, confirmation:)
        receipt = plan.merge(
          final_status: "success",
          target_leg_status: "TARGET_CONFIRMED_LATE_BY_RECONCILIATION",
          source_leg_status: "SOURCE_CLOSE_CONFIRMED",
          source_leg_submitted: true,
          source_leg_exchange_order_id: "extended-close",
          to_leg_execution: { confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "0xnado-target" },
          from_leg_execution: { confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "extended-close", receipt: { mode: "close_only" } },
          source_flat_confirmed: true,
          target_holds_hedge_confirmed: true,
          final_inside_tolerance: true,
          open_orders_after: 0,
          exchange_order_ids: [ "0xnado-target", "extended-close" ],
          orders_placed: 2,
          orders_submitted: 2,
          signatures_created: 2,
          blockers: [],
          warnings: plan.fetch(:warnings)
        )
        HedgeVenueMigrationExecutor::Result.new("success", [], receipt.fetch(:warnings), receipt)
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "nado",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal MigrationLiveCanaryChecker::CONFIRMED_STATUS, result.status
    assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
    assert_equal "SOURCE_CLOSE_CONFIRMED", result.receipt.fetch(:source_leg_status)
    assert_equal true, result.receipt.fetch(:source_leg_submitted)
    assert_equal "extended-close", result.receipt.fetch(:source_leg_exchange_order_id)
    assert_equal true, result.receipt.fetch(:source_leg_readback_confirmed)
    assert_equal 2, result.receipt.fetch(:orders_submitted)
    assert_equal 2, result.receipt.fetch(:signatures_created)
  end

  test "Aerodrome direct Extended to Nado target failure keeps source unchanged" do
    source_close_called = false
    executor = Class.new do
      attr_reader :received_plan

      def initialize(source_close_called)
        @source_close_called = source_close_called
      end

      def run_precomputed_plan(position:, plan:, confirmation:)
        @received_plan = plan
        HedgeVenueMigrationExecutor::Result.new(
          "first_leg_not_confirmed",
          [ "Nado target open failed; source unchanged." ],
          plan.fetch(:warnings),
          plan.merge(
            final_status: "first_leg_not_confirmed",
            to_leg_execution: { confirmed: false, orders_placed: 0, signatures_created: 0 },
            from_leg_execution: nil,
            source_leg_submitted: @source_close_called,
            final_inside_tolerance: false,
            orders_placed: 0,
            orders_submitted: 0,
            signatures_created: 0,
            blockers: [ "Nado target open failed; source unchanged." ]
          )
        )
      end
    end.new(source_close_called)

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_nado_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "nado",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "TARGET_LEG_FAILED_SOURCE_UNCHANGED", result.status
    assert_equal false, result.receipt.fetch(:source_leg_submitted)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_not_includes result.blockers, "active hedge-ready Mellow Autopilot position is required"
  end

  test "Aerodrome direct Extended to Nado accepted target shows continuation instead of duplicate target open" do
    executor = Class.new do
      def run_precomputed_plan(position:, plan:, confirmation:)
        receipt = plan.merge(
          final_status: "TARGET_ACCEPTED_AWAITING_CONTINUATION",
          target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
          source_leg_status: nil,
          source_leg_submitted: false,
          to_leg_execution: { confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "0xnado-target" },
          from_leg_execution: nil,
          final_inside_tolerance: false,
          continuation_pending: true,
          nado_target_digest: "0xnado-target",
          exchange_order_ids: [ "0xnado-target" ],
          orders_placed: 1,
          orders_submitted: 1,
          signatures_created: 1,
          blockers: [],
          warnings: plan.fetch(:warnings)
        )
        HedgeVenueMigrationExecutor::Result.new("TARGET_ACCEPTED_AWAITING_CONTINUATION", [], receipt.fetch(:warnings), receipt)
      end
    end.new

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_nado_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: ready_position,
      from: "extended",
      to: "nado",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "TARGET_ACCEPTED_AWAITING_CONTINUATION", result.status
    assert_equal true, result.receipt.fetch(:continuation_pending)
    assert_equal false, result.receipt.fetch(:source_leg_submitted)
    assert_equal "0xnado-target", result.receipt.fetch(:nado_target_digest)
    assert_equal [ "0xnado-target" ], result.receipt.fetch(:exchange_order_ids)
  end

  test "stale duplicate canary after completed route does not call executor" do
    executed = false
    executor = Class.new do
      def initialize(flag)
        @flag = flag
      end

      def run_precomputed_plan(*)
        @flag = true
        raise "executor should not run for completed stale route"
      end
    end.new(executed)
    current = ready_position
    current.hedge.update!(execution_venue: "nado")
    set_completed_readback(current, from: "extended", to: "nado", production_venue: "nado")

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_nado_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: current,
      from: "extended",
      to: "nado",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE", result.status
    assert_empty result.blockers
    assert_equal false, executed
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal 0, result.receipt.fetch(:cancels_submitted)
  end

  test "stale duplicate canary with app venue not finalized returns finalize required without executor" do
    executor = Class.new do
      def run_precomputed_plan(*)
        raise "executor should not run for completed stale route"
      end
    end.new
    current = ready_position
    set_completed_readback(current, from: "extended", to: "nado", production_venue: "extended")

    result = MigrationManualLiveCanaryRunner.new(
      env: ready_nado_env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: executor
    ).run(
      position: current,
      from: "extended",
      to: "nado",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal "SOURCE_CLOSED_TARGET_CONFIRMED_NOT_FINALIZED", result.status
    assert_empty result.blockers
    assert_equal true, result.receipt.fetch(:finalize_safe)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal 0, result.receipt.fetch(:cancels_submitted)
  end

  test "runner blocked result uses the same canonical planner blockers" do
    env = ready_env.merge("EXTENDED_AUTO_REBALANCE_ENABLED" => "true")
    plan = MigrationManualCanaryPlanner.new(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      env: env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target
    ).report

    result = MigrationManualLiveCanaryRunner.new(
      env: env,
      target_preflight: { blockers: [] },
      fresh_target: fresh_target,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      executor: Class.new do
        def run_precomputed_plan(*)
          raise "executor should not run"
        end
      end.new
    ).run(
      position: ready_position,
      from: "extended",
      to: "ethereal",
      confirmation: MigrationManualLiveCanaryRunner::CONFIRMATION
    )

    assert_equal plan.fetch(:blockers), result.blockers
    assert_includes result.blockers, "source venue auto must be disabled during migration canary: extended"
  end

  # --- Part A: frozen source-position proof builder (guarded) ---

  def armed_env
    {
      "MIGRATION_LIVE_ENABLED" => "true", "MIGRATION_MANUAL_LIVE_CANARY_ENABLED" => "true",
      "MIGRATION_FULL_ALLOWED" => "true", "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def proof_plan(open_orders: "zero", stale: false, size: "1.8703")
    { open_orders_status: open_orders, exposure_stale: stale, planned_second_leg: { size_eth: size },
      source_snapshot_refreshed_at: "2026-07-09T00:00:00Z" }
  end

  def stopped_runner_status
    { status: "stopped", pid: nil, duplicate_runner_process: false }
  end

  def proof_runner(env, runner_status: stopped_runner_status)
    MigrationManualLiveCanaryRunner.new(
      env: env,
      receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}"),
      production_runner_status: ->(_position) { runner_status }
    )
  end

  def build_proof(env: armed_env, plan: proof_plan, from: "ethereal", sequence: "target_first", runner_status: stopped_runner_status)
    proof_runner(env, runner_status: runner_status).send(:frozen_source_position_proof, position: position, plan: plan, from: from, sequence: sequence)
  end

  test "frozen proof is built when all invariants hold" do
    proof = build_proof
    assert proof, "expected a frozen proof when all invariants hold"
    assert_equal "ethereal", proof[:source_venue]
    assert_equal "1.8703", proof[:short_size]
    assert_equal true, proof[:invariants_proven]
  end

  test "frozen proof is nil when migration DB gates are not armed" do
    assert_nil build_proof(env: armed_env.merge("MIGRATION_LIVE_ENABLED" => "false"))
  end

  test "frozen proof is nil when the Ethereal source auto is not paused" do
    assert_nil build_proof(env: armed_env.merge("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "true"))
  end

  test "frozen proof is nil when open orders are not zero" do
    assert_nil build_proof(plan: proof_plan(open_orders: "1"))
  end

  test "frozen proof is nil when the source snapshot is stale" do
    assert_nil build_proof(plan: proof_plan(stale: true))
  end

  test "frozen proof is nil when the production runner is active" do
    assert_nil build_proof(runner_status: { status: "running", pid: 4321, duplicate_runner_process: false })
  end

  test "frozen proof is nil when the planned source size is missing" do
    assert_nil build_proof(plan: { open_orders_status: "zero", exposure_stale: false, planned_second_leg: {} })
  end

  test "frozen proof is nil for a non-target_first sequence" do
    assert_nil build_proof(sequence: "source_first")
  end

  private

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
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
    }
  end

  def ready_nado_env
    ready_env.merge(
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
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

  def ready_position
    current = position
    current.update!(asset0_amount: "0.9884587950517357", source: Position::SOURCE_AERODROME_DIRECT)
    current.position_dashboard_snapshot.update!(
      target_short_eth: "0.9884587950517357",
      tolerance_abs_eth: "0.029653763851552071",
      combined_short_eth: "0.977",
      drift_eth: "0.0114587950517357",
      extended_short_eth: "0.977",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      open_orders_count_extended: 0
    )
    current
  end

  def set_completed_readback(position, from:, to:, production_venue:)
    target = position.position_dashboard_snapshot.target_short_eth
    attrs = {
      production_venue: production_venue,
      selected_venue: production_venue,
      combined_short_eth: target,
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      open_orders_count_extended: 0
    }
    attrs["#{from}_short_eth"] = "0"
    attrs["#{to}_short_eth"] = target
    position.position_dashboard_snapshot.update!(attrs)
  end

  def position
    @position ||= begin
      position = Position.create!(
        user: users(:one),
        wallet: wallets(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        source: Position::SOURCE_MELLOW_AUTOPILOT,
        mellow_metadata: JSON.generate({ "hedge_ready" => false }),
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
        stale: false,
        production_venue: "extended",
        target_short_eth: "1.0",
        combined_short_eth: "1.0",
        drift_eth: "0",
        inside_tolerance: true,
        extended_short_eth: "1.0",
        ethereal_short_eth: "0",
        nado_short_eth: "0"
      )
      position
    end
  end
end
