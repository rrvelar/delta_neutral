class MigrationManualLiveCanaryRunner
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_live_canaries")
  CONFIRMATION = MigrationManualLiveCanaryReadiness::CONFIRMATION

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, now: -> { Time.current }, receipt_dir: RECEIPT_DIR, executor: nil, target_preflight: nil, fresh_target: nil)
    @env = env
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @executor = executor
    @target_preflight = target_preflight
    @fresh_target = fresh_target
  end

  def run(position:, from:, to:, confirmation:, sequence: "target_first")
    plan = canonical_plan(position: position, from: from, to: to, sequence: sequence)
    blockers = hard_blockers(plan: plan, confirmation: confirmation)
    receipt = base_receipt(position: position, plan: plan, confirmation: confirmation, blockers: blockers)
    if blockers.any?
      write_receipt(receipt)
      return Result.new("blocked_before_submit", blockers, plan.fetch(:warnings), receipt)
    end

    result = executor.run_precomputed_plan(
      position: position,
      plan: receipt,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
    )
    canary_receipt = receipt.merge(from_executor_result(result))
    canary_receipt[:final_status] = normalized_final_status(canary_receipt, result)
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

  def from_executor_result(result)
    receipt = result.receipt
    confirmed = result.status == "success" && receipt[:source_flat_confirmed] && receipt[:target_holds_hedge_confirmed] && receipt[:final_inside_tolerance]
    {
      final_status: confirmed ? MigrationLiveCanaryChecker::CONFIRMED_STATUS : result.status,
      target_leg_readback_confirmed: receipt[:to_leg_execution]&.fetch(:confirmed, false),
      source_leg_readback_confirmed: receipt[:from_leg_execution]&.fetch(:confirmed, false),
      final_inside_tolerance: receipt[:final_inside_tolerance],
      source_flat_after: receipt[:source_flat_confirmed],
      target_holds_expected_short: receipt[:target_holds_hedge_confirmed],
      open_orders_after: 0,
      exchange_order_ids: receipt[:exchange_order_ids],
      orders_submitted: receipt[:orders_placed].to_i,
      orders_placed: receipt[:orders_placed].to_i,
      signatures_created: receipt[:signatures_created].to_i,
      would_execute_live: receipt[:orders_placed].to_i.positive?,
      blockers: result.blockers,
      warnings: result.warnings
    }
  end

  def normalized_final_status(receipt, result)
    return MigrationLiveCanaryChecker::CONFIRMED_STATUS if receipt[:final_status] == MigrationLiveCanaryChecker::CONFIRMED_STATUS
    return "PARTIAL_OVERHEDGE_MANUAL_ACTION_REQUIRED" if receipt[:target_leg_readback_confirmed] && !receipt[:source_leg_readback_confirmed]
    return "TARGET_LEG_FAILED_SOURCE_UNCHANGED" unless receipt[:target_leg_readback_confirmed]

    result.status.to_s.upcase
  end

  def write_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end
end
