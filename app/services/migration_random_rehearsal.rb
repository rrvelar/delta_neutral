class MigrationRandomRehearsal
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_random_rehearsals")
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, planner: nil, migration_planner: HedgeVenueMigrationPlanner.new, receipt_writer: nil, now: -> { Time.current })
    @env = env
    @planner = planner
    @migration_planner = migration_planner
    @receipt_writer = receipt_writer || HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: RECEIPT_DIR)
    @now = now
  end

  def run(position:, dry_run: true)
    random = planner.plan(position: position, require_live_proofs: false)
    selected = random.receipt[:selected_route]
    unless selected
      receipt = base_receipt(position: position, random: random.receipt).merge(final_status: "NO_ELIGIBLE_ROUTE", blockers: random.blockers)
      write_receipt(receipt)
      return Result.new("no_eligible_route", random.blockers, random.warnings, receipt)
    end

    plan = migration_planner.plan(
      position: position,
      from_venue: selected.fetch(:from_venue),
      to_venue: selected.fetch(:to_venue),
      mode: "full",
      full_migration_allowed: true,
      migration_sequence: "target_first"
    )
    blockers = Array(plan.blockers)
    receipt = base_receipt(position: position, random: random.receipt).merge(
      from_venue: selected.fetch(:from_venue),
      to_venue: selected.fetch(:to_venue),
      route: selected.fetch(:route),
      selected_route: selected,
      selected_by: random.receipt[:selected_by],
      migration_sequence: "target_first",
      target_leg_preview: plan.receipt[:planned_target_leg],
      source_close_preview: plan.receipt[:planned_source_leg],
      planned_first_leg: plan.receipt[:planned_first_leg],
      planned_second_leg: plan.receipt[:planned_second_leg],
      expected_temporary_overhedge: plan.receipt[:temporary_combined_after_first_leg],
      expected_final_state: {
        expected_from_short_after: plan.receipt[:expected_from_short_after],
        expected_to_short_after: plan.receipt[:expected_to_short_after],
        expected_combined_short_after: plan.receipt[:expected_combined_short_after],
        expected_final_inside_tolerance: plan.receipt[:final_expected_inside_tolerance]
      },
      recovery_command: "bin/rails migration:recover_target_first_source_close position_id=#{position.id} from=#{selected.fetch(:from_venue)} to=#{selected.fetch(:to_venue)} dry_run=true",
      final_status: blockers.empty? ? "dry_run" : "blocked_before_submit",
      blockers: blockers,
      warnings: (Array(random.warnings) + Array(plan.warnings)).uniq,
      dry_run: dry_run,
      would_execute_live: false
    )
    write_receipt(receipt)
    Result.new(receipt[:final_status], blockers, receipt[:warnings], receipt)
  end

  private

  attr_reader :env, :migration_planner, :receipt_writer, :now

  def planner
    @planner ||= MigrationRandomPlanner.new(env: env, now: now)
  end

  def base_receipt(position:, random:)
    {
      action: "random_migration_rehearsal",
      timestamp: now.call.utc.iso8601,
      source_commit: current_commit,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      current_production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      random_plan: random,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
  end

  def write_receipt(receipt)
    path = receipt_writer.write(receipt)
    receipt[:receipt_path] = path.to_s if path
  end

  def current_commit
    `git -C #{Rails.root} rev-parse --short HEAD 2>/dev/null`.strip.presence
  end
end
