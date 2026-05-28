class MigrationManualLiveCanaryRunner
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_live_canaries")
  CONFIRMATION = MigrationManualLiveCanaryReadiness::CONFIRMATION

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, now: -> { Time.current }, receipt_dir: RECEIPT_DIR, executor: nil)
    @env = env
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @executor = executor
  end

  def run(position:, from:, to:, confirmation:, sequence: "source_first")
    readiness = MigrationManualLiveCanaryReadiness.new(position: position, from: from, to: to, env: env).report
    blockers = hard_blockers(readiness: readiness, confirmation: confirmation)
    receipt = base_receipt(position: position, readiness: readiness, confirmation: confirmation, sequence: sequence, blockers: blockers)
    if blockers.any?
      write_receipt(receipt)
      return Result.new("blocked_before_submit", blockers, readiness.fetch(:warnings), receipt)
    end

    result = executor.run(
      position: position,
      from_venue: readiness.fetch(:from_venue),
      to_venue: readiness.fetch(:to_venue),
      mode: "full",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      migration_sequence: sequence
    )
    canary_receipt = receipt.merge(from_executor_result(result))
    write_receipt(canary_receipt)
    Result.new(canary_receipt[:final_status], Array(canary_receipt[:blockers]), Array(canary_receipt[:warnings]), canary_receipt)
  end

  private

  attr_reader :env, :now, :receipt_dir

  def executor
    @executor ||= HedgeVenueMigrationExecutor.new(env: env, receipt_writer: HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir))
  end

  def hard_blockers(readiness:, confirmation:)
    blockers = []
    blockers.concat(readiness.fetch(:blockers))
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "MIGRATION_NADO_LIVE_MIGRATION_ENABLED must be true for Nado canary." if readiness.fetch(:route).include?("nado") && !bool_env("MIGRATION_NADO_LIVE_MIGRATION_ENABLED")
    blockers.uniq
  end

  def base_receipt(position:, readiness:, confirmation:, sequence:, blockers:)
    {
      action: "manual_live_canary",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      from_venue: readiness.fetch(:from_venue),
      to_venue: readiness.fetch(:to_venue),
      mode: "full",
      sequence: sequence,
      final_status: blockers.any? ? "blocked_before_submit" : "submitted_to_executor",
      confirmation_type: confirmation == CONFIRMATION ? "manual_live_canary_confirmation" : "missing_or_invalid_confirmation",
      blockers: blockers,
      warnings: readiness.fetch(:warnings),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      would_execute_live: false
    }
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
      blockers: result.blockers,
      warnings: result.warnings
    }
  end

  def write_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
