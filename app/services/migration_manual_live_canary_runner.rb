class MigrationManualLiveCanaryRunner
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_live_canaries")
  CONFIRMATION = MigrationManualLiveCanaryReadiness::CONFIRMATION

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, now: -> { Time.current }, receipt_dir: RECEIPT_DIR, executor: nil, target_preflight: nil, fresh_target: nil, production_runner_status: nil)
    @env = env
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @executor = executor
    @target_preflight = target_preflight
    @fresh_target = fresh_target
    @production_runner_status = production_runner_status
  end

  def run(position:, from:, to:, confirmation:, sequence: "target_first")
    plan = canonical_plan(position: position, from: from, to: to, sequence: sequence)
    blockers = hard_blockers(plan: plan, confirmation: confirmation)
    receipt = base_receipt(position: position, plan: plan, confirmation: confirmation, blockers: blockers)
    if blockers.any?
      reconciled = reconcile_stale_action(position: position, from: from, to: to, confirmation: confirmation, blockers: blockers)
      return reconciled if reconciled

      write_receipt(receipt)
      return Result.new("blocked_before_submit", blockers, plan.fetch(:warnings), receipt)
    end

    receipt[:frozen_source_position] = frozen_source_position_proof(position: position, plan: receipt, from: from, sequence: sequence)
    result = executor.run_precomputed_plan(
      position: position,
      plan: receipt,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
    )
    canary_receipt = receipt.merge(from_executor_result(result))
    canary_receipt[:final_status] = normalized_final_status(canary_receipt, result)
    reconciled = reconcile_stale_action(position: position, from: from, to: to, confirmation: confirmation, blockers: Array(canary_receipt[:blockers]))
    return reconciled if canary_receipt[:blockers].present? && reconciled

    write_receipt(canary_receipt)
    Result.new(canary_receipt[:final_status], Array(canary_receipt[:blockers]), Array(canary_receipt[:warnings]), canary_receipt)
  end

  private

  attr_reader :env, :now, :receipt_dir

  def executor
    @executor ||= HedgeVenueMigrationExecutor.new(env: env, receipt_writer: HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir))
  end

  def canonical_plan(position:, from:, to:, sequence:)
    MigrationManualCanaryPlanner.new(
      position: position,
      from: from,
      to: to,
      env: env,
      target_preflight: @target_preflight,
      fresh_target: @fresh_target,
      sequence: sequence,
      now: now
    ).report
  end

  def hard_blockers(plan:, confirmation:)
    blockers = []
    blockers.concat(plan.fetch(:blockers))
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers.uniq
  end

  def base_receipt(position:, plan:, confirmation:, blockers:)
    plan.merge(
      action: "manual_live_canary",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      final_status: blockers.any? ? "blocked_before_submit" : "submitted_to_executor",
      confirmation_type: confirmation == CONFIRMATION ? "manual_live_canary_confirmation" : "missing_or_invalid_confirmation",
      blockers: blockers,
      warnings: plan.fetch(:warnings),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      would_execute_live: false
    )
  end

  # Part A: build a FROZEN source-position proof for the Ethereal source close, ONLY when
  # every invariant is proven at execution time. Returns nil (⇒ leg runner reads fresh)
  # unless: target_first, source ethereal, open orders zero, source snapshot fresh, all
  # three migration DB gates armed, the Ethereal source auto is paused (disabled), the
  # production runner is inactive, and a positive planned source size exists. The leg
  # runner re-validates and only uses it to SIZE the close; the fill confirmation + final
  # flat readback still read fresh. Fail-closed on any error.
  def frozen_source_position_proof(position:, plan:, from:, sequence:)
    return nil unless sequence.to_s == "target_first"
    return nil unless from.to_s == "ethereal"
    return nil unless plan[:open_orders_status].to_s == "zero"
    return nil unless plan[:exposure_stale] == false
    return nil unless migration_db_gates_armed?
    return nil if OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", env: env)
    return nil unless production_runner_inactive?(position)

    size = frozen_decimal(plan.dig(:planned_second_leg, :size_eth)) || frozen_decimal(plan[:current_source_short])
    return nil unless size&.positive?

    {
      source_venue: from.to_s,
      short_size: size.to_s("F"),
      invariants_proven: true,
      confirmed_at: plan[:source_snapshot_refreshed_at],
      reason: "target_first ethereal canary invariants proven: gates armed, ethereal source auto paused, open orders zero, runner inactive, fresh source snapshot"
    }
  rescue StandardError
    nil
  end

  def migration_db_gates_armed?
    %w[MIGRATION_LIVE_ENABLED MIGRATION_MANUAL_LIVE_CANARY_ENABLED MIGRATION_FULL_ALLOWED].all? do |key|
      OperationalSettings.enabled?(key, env: env)
    end
  end

  # "unsafe_gates_left_enabled" is the NORMAL status during an armed manual canary:
  # the runner reports it whenever any migration gate is armed with no runner process,
  # which is exactly the state this proof requires (gates armed + runner inactive).
  # It only counts as inactive with the same no-process guarantees as stopped/failed:
  # nil pid and no duplicate runner process.
  def production_runner_inactive?(position)
    status = if @production_runner_status
      @production_runner_status.call(position)
    else
      MigrationRandomProductionRunner.new(position: position, trap_signals: false).status
    end
    status[:status].to_s.in?(%w[stopped failed unsafe_gates_left_enabled]) && status[:pid].nil? && status[:duplicate_runner_process] != true
  rescue StandardError
    false
  end

  def frozen_decimal(value)
    return nil if value.nil? || value.to_s.strip.empty?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def from_executor_result(result)
    receipt = result.receipt
    confirmed = result.status == "success" && receipt[:source_flat_confirmed] && receipt[:target_holds_hedge_confirmed] && receipt[:final_inside_tolerance]
    {
      final_status: confirmed ? MigrationLiveCanaryChecker::CONFIRMED_STATUS : result.status,
      target_leg_status: receipt[:target_leg_status],
      source_leg_status: receipt[:source_leg_status],
      source_leg_submitted: receipt[:source_leg_submitted],
      source_leg_exchange_order_id: receipt[:source_leg_exchange_order_id],
      nado_target_digest: receipt[:nado_target_digest],
      target_confirmation_attempts: receipt[:target_confirmation_attempts],
      continuation_command: receipt[:continuation_command],
      pending_migration_id: receipt[:pending_migration_id],
      source_close_plan: receipt[:source_close_plan],
      continuation_pending: receipt[:continuation_pending],
      target_leg_readback_confirmed: receipt[:to_leg_execution]&.fetch(:confirmed, false) || receipt[:target_holds_hedge_confirmed] == true,
      source_leg_readback_confirmed: receipt[:from_leg_execution]&.fetch(:confirmed, false) || receipt[:source_flat_confirmed] == true,
      final_inside_tolerance: receipt[:final_inside_tolerance],
      source_flat_after: receipt[:source_flat_confirmed],
      target_holds_expected_short: receipt[:target_holds_hedge_confirmed],
      open_orders_after: receipt.fetch(:open_orders_after, 0),
      route_latency_proof: receipt[:route_latency_proof],
      production_safe_route: receipt[:production_safe_route],
      route_production_safe: receipt[:route_production_safe],
      double_exposure_seconds: receipt[:double_exposure_seconds],
      underhedge_seconds: receipt[:underhedge_seconds],
      total_route_seconds: receipt[:total_route_seconds] || receipt[:total_migration_latency_seconds],
      double_exposure_started_at: receipt[:double_exposure_started_at],
      double_exposure_ended_at: receipt[:double_exposure_ended_at],
      underhedge_started_at: receipt[:underhedge_started_at],
      underhedge_ended_at: receipt[:underhedge_ended_at],
      # --- authoritative fill / latency diagnostics (non-sensitive; surfaced so a
      # canary receipt shows where the double-exposure window bounds came from and
      # which leg phase was slow) ---
      double_exposure_start_source: receipt[:double_exposure_start_source],
      double_exposure_end_source: receipt[:double_exposure_end_source],
      target_leg_submit_started_at: receipt[:target_leg_submit_started_at],
      target_leg_submit_finished_at: receipt[:target_leg_submit_finished_at],
      target_action_timing: receipt[:target_action_timing],
      source_close_submit_started_at: receipt[:source_close_submit_started_at],
      source_close_submit_finished_at: receipt[:source_close_submit_finished_at],
      source_close_action_timing: receipt[:source_close_action_timing],
      target_confirm_to_source_close_submit_latency_seconds: receipt[:target_confirm_to_source_close_submit_latency_seconds],
      target_open_confirmation_source: receipt[:target_open_confirmation_source],
      source_close_confirmation_source: receipt[:source_close_confirmation_source],
      target_open_fill_confirmed_at: receipt[:target_open_fill_confirmed_at],
      target_open_position_readback_confirmed_at: receipt[:target_open_position_readback_confirmed_at],
      source_close_fill_confirmed_at: receipt[:source_close_fill_confirmed_at],
      source_close_position_readback_confirmed_at: receipt[:source_close_position_readback_confirmed_at],
      target_open_fill_readback_agreement: receipt[:target_open_fill_readback_agreement],
      source_close_fill_readback_agreement: receipt[:source_close_fill_readback_agreement],
      target_total_latency_seconds: receipt[:target_total_latency_seconds],
      source_close_total_latency_seconds: receipt[:source_close_total_latency_seconds],
      total_migration_latency_seconds: receipt[:total_migration_latency_seconds],
      target_leg_timing: leg_timing_summary(receipt[:to_leg_execution]),
      source_leg_timing: leg_timing_summary(receipt[:from_leg_execution]),
      exchange_order_ids: receipt[:exchange_order_ids],
      orders_submitted: receipt[:orders_placed].to_i,
      orders_placed: receipt[:orders_placed].to_i,
      signatures_created: receipt[:signatures_created].to_i,
      would_execute_live: receipt[:orders_placed].to_i.positive?,
      blockers: result.blockers,
      warnings: result.warnings
    }
  end

  # Per-leg timing summary so a canary receipt shows the slow phase (e.g. build vs
  # readback) without exposing sensitive fields. Reads the leg's own timing hash.
  def leg_timing_summary(leg)
    return nil unless leg.is_a?(Hash)

    timing = leg[:timing] || {}
    {
      slow_step: timing[:slow_step],
      total_action_latency_seconds: timing[:total_action_latency_seconds],
      build_latency_seconds: seconds_between(timing[:build_started_at], timing[:build_finished_at]),
      submit_latency_seconds: timing[:submit_latency_seconds],
      readback_latency_seconds: timing[:readback_latency_seconds]
    }.compact.presence
  end

  def seconds_between(start_at, finish_at)
    return nil if start_at.blank? || finish_at.blank?

    (Time.zone.parse(finish_at.to_s) - Time.zone.parse(start_at.to_s)).round(6)
  rescue ArgumentError, TypeError
    nil
  end

  def normalized_final_status(receipt, result)
    return MigrationLiveCanaryChecker::CONFIRMED_STATUS if receipt[:final_status] == MigrationLiveCanaryChecker::CONFIRMED_STATUS
    return "TARGET_ACCEPTED_AWAITING_CONTINUATION" if result.status.to_s == "TARGET_ACCEPTED_AWAITING_CONTINUATION"
    return "TARGET_SUBMITTED_BUT_NOT_CONFIRMED" if result.status.to_s == "TARGET_SUBMITTED_BUT_NOT_CONFIRMED"
    return "TARGET_REJECTED_OR_NOT_CONFIRMED" if result.status.to_s == "TARGET_REJECTED_OR_NOT_CONFIRMED"
    return "PARTIAL_OVERHEDGE_MANUAL_ACTION_REQUIRED" if receipt[:target_leg_readback_confirmed] && !receipt[:source_leg_readback_confirmed]
    return "TARGET_LEG_FAILED_SOURCE_UNCHANGED" unless receipt[:target_leg_readback_confirmed]

    result.status.to_s.upcase
  end

  def write_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end

  def reconcile_stale_action(position:, from:, to:, confirmation:, blockers:)
    return unless confirmation == CONFIRMATION
    return unless stale_action_blockers?(blockers)

    reconciler = MigrationRouteCompletionReconciler.new(position: position, from: from, to: to, now: now, receipt_dir: receipt_dir)
    current = reconciler.report
    return unless current.route_complete_by_readback

    finalized = current.production_venue_finalized ? reconciler.write_ready_receipt!(status: "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE") : current
    Result.new(finalized.status, [], finalized.warnings, finalized.receipt.merge(stale_action_blockers: blockers))
  end

  def stale_action_blockers?(blockers)
    Array(blockers).any? do |blocker|
      text = blocker.to_s
      text.match?(/source venue .* has no current short|source venue must have a real short|source close preview unavailable|execution_venue must be|production venue.*target|source.*flat/i)
    end
  end
end
