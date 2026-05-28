class MigrationRandomRotationDailyRunner
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_random_rotation_daily")
  DEFAULT_DEBOUNCE_SECONDS = 1.hour

  Result = Data.define(:status, :positions, :blockers, :warnings, :orders_submitted, :signatures_created)

  def initialize(
    env: ENV,
    now: -> { Time.current },
    receipt_dir: RECEIPT_DIR,
    route_receipt_dir: HedgeVenueMigrationRouteMatrix::PROOF_RECEIPT_DIR,
    random_receipt_dir: HedgeVenueAutoMigrationPlanner::RECEIPT_DIR,
    state_dir: MigrationRandomRotationVirtualState::STATE_DIR,
    route_matrix_class: HedgeVenueMigrationRouteMatrix,
    planner_class: HedgeVenueAutoMigrationPlanner,
    snapshot_refresh_class: DashboardSnapshotRefresh,
    virtual_state_class: MigrationRandomRotationVirtualState
  )
    @env = env
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @route_receipt_dir = Pathname(route_receipt_dir)
    @random_receipt_dir = Pathname(random_receipt_dir)
    @state_dir = Pathname(state_dir)
    @route_matrix_class = route_matrix_class
    @planner_class = planner_class
    @snapshot_refresh_class = snapshot_refresh_class
    @virtual_state_class = virtual_state_class
  end

  def call(position_id: nil, force: false, seed: nil, enabled_override: false)
    daily_enabled = enabled_override || bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED")
    return disabled_result(position_id: position_id) unless daily_enabled

    positions = target_positions(position_id)
    return missing_position_result(position_id) if position_id.present? && positions.empty?

    results = positions.map { |position| run_position(position, force: force, seed: seed, enabled_override: enabled_override) }
    Result.new(
      status: results.any? { |row| row[:status] == "error" } ? "partial" : "ok",
      positions: results,
      blockers: results.flat_map { |row| Array(row[:blockers]) }.uniq,
      warnings: results.flat_map { |row| Array(row[:warnings]) }.uniq,
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  private

  attr_reader :env,
    :now,
    :receipt_dir,
    :route_receipt_dir,
    :random_receipt_dir,
    :state_dir,
    :route_matrix_class,
    :planner_class,
    :snapshot_refresh_class,
    :virtual_state_class

  def run_position(position, force:, seed:, enabled_override:)
    lock_key = "migration_random_rotation_daily:position:#{position.id}"
    ran = false
    result = nil
    JobConcurrencyGuard.with_lock(lock_key) do
      ran = true
      if !force && recent_receipt?(position.id)
        result = skipped_receipt(position, reason: "debounce", enabled_override: enabled_override)
        write_daily_receipt(result)
        next
      end

      result = execute_read_only_workflow(position, seed: seed, enabled_override: enabled_override)
    end

    return skipped_receipt(position, reason: "lock", enabled_override: enabled_override) unless ran

    result
  rescue => e
    error = error_receipt(position, error: "#{e.class}: #{e.message}", enabled_override: enabled_override)
    write_daily_receipt(error)
    error
  end

  def execute_read_only_workflow(position, seed:, enabled_override:)
    snapshot = snapshot_refresh_class.new(position: position, force: true).refresh
    position.reload
    route_matrix = route_matrix_class.new(position: position, snapshot: snapshot, receipt_dir: route_receipt_dir)
    proof_summary = route_matrix.prove_routes!
    virtual_state = virtual_state_class.new(position: position, state_dir: state_dir, now: now)
    state_before = virtual_state.current
    virtual_current = state_before.fetch(:virtual_current_venue)
    planner = planner_class.new(
      route_matrix: proof_summary,
      random_seed: seed,
      receipt_dir: random_receipt_dir,
      current_venue_override: virtual_current,
      virtual_mode: true
    )
    decision = planner.plan(position: position)
    random_receipt_path = planner.write_receipt(decision.receipt)
    selected_route = decision.receipt[:selected_route]
    selected_target = decision.receipt[:selected_target_venue]
    should_advance = virtual_decision_selected?(decision.receipt)
    virtual_after = should_advance && selected_target.present? ? selected_target : virtual_current

    receipt = {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      production_venue: position.hedge&.execution_venue,
      virtual_current_venue_before: virtual_current,
      current_venue: decision.receipt[:current_venue],
      route_proof_status: proof_summary[:status] || "recorded",
      route_proof_receipt_path: Array(proof_summary[:receipt_paths]).first,
      random_rotation_receipt_path: random_receipt_path&.to_s,
      selected_route: selected_route,
      selected_target_venue: selected_target,
      virtual_current_venue_after: virtual_after,
      dry_run_eligible_routes: decision.receipt[:dry_run_eligible_routes],
      live_blocked_routes: decision.receipt[:live_blocked_routes],
      status: decision.receipt[:status],
      blockers: decision.receipt[:blockers],
      warnings: decision.receipt[:warnings],
      auto_enabled: ActiveModel::Type::Boolean.new.cast(env["MIGRATION_AUTO_ENABLED"]),
      daily_enabled: true,
      enabled_override: enabled_override,
      dry_run_only: true,
      virtual_mode: true,
      production_venue_mutated: false,
      hedge_execution_venue_after: position.hedge&.reload&.execution_venue,
      would_migrate: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
    daily_receipt_path = write_daily_receipt(receipt)
    state_after = should_advance ? virtual_state.update_from_decision!(decision_receipt: decision.receipt, daily_receipt_path: daily_receipt_path&.to_s) : state_before
    receipt.merge(
      virtual_current_venue_after: state_after.fetch(:virtual_current_venue),
      virtual_state_path: state_dir.join("position_#{position.id}.json").to_s,
      receipt_path: daily_receipt_path&.to_s
    )
  end

  def disabled_result(position_id:)
    Result.new(
      status: "disabled",
      positions: [],
      blockers: [],
      warnings: [ "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED is false; daily random rotation dry-run skipped." ],
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def virtual_decision_selected?(decision_receipt)
    selected = decision_receipt[:selected_route] || decision_receipt["selected_route"]
    decision_receipt[:status] == "RANDOM_ROUTE_SELECTED" &&
      selected.present? &&
      selected.fetch(:virtual_decision_eligible, selected["virtual_decision_eligible"]) == true
  end

  def missing_position_result(position_id)
    Result.new(
      status: "blocked",
      positions: [],
      blockers: [ "Position #{position_id} not found." ],
      warnings: [],
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def skipped_receipt(position, reason:, enabled_override:)
    {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      current_venue: position.hedge&.execution_venue,
      status: "skipped",
      blockers: [],
      warnings: [ "Daily random rotation dry-run skipped: #{reason}." ],
      daily_enabled: true,
      enabled_override: enabled_override,
      dry_run_only: true,
      would_migrate: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def error_receipt(position, error:, enabled_override:)
    {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      current_venue: position.hedge&.execution_venue,
      status: "error",
      blockers: [ error ],
      warnings: [],
      daily_enabled: true,
      enabled_override: enabled_override,
      dry_run_only: true,
      would_migrate: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def write_daily_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end

  def recent_receipt?(position_id)
    latest = latest_daily_receipt(position_id)
    return false unless latest

    timestamp = Time.zone.parse(latest.fetch("timestamp"))
    timestamp > now.call - debounce_seconds.seconds
  rescue ArgumentError, KeyError
    false
  end

  def latest_daily_receipt(position_id)
    Dir.glob(receipt_dir.join("*.jsonl")).sort.reverse_each do |path|
      File.readlines(path).reverse_each do |line|
        receipt = JSON.parse(line)
        return receipt if receipt["position_id"].to_s == position_id.to_s && receipt["action"] == "daily_random_rotation_dry_run"
      rescue JSON::ParserError
        next
      end
    end
    nil
  rescue SystemCallError
    nil
  end

  def target_positions(position_id)
    scope = Position.includes(:dex, :hedge, :position_dashboard_snapshot)
      .joins(:dex, :hedge)
      .where(active: true, dexes: { name: "aerodrome_slipstream" }, hedges: { active: true })
    position_id.present? ? scope.where(id: position_id).to_a : scope.to_a
  end

  def debounce_seconds
    Integer(env.fetch("MIGRATION_RANDOM_ROTATION_DAILY_DEBOUNCE_SECONDS", DEFAULT_DEBOUNCE_SECONDS.to_i.to_s))
  rescue ArgumentError
    DEFAULT_DEBOUNCE_SECONDS.to_i
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
