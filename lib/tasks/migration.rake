namespace :migration do
  desc "Write read-only hedge venue migration route proof receipts for a position"
  task prove_routes: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "migration_route_proof_summary",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    task_started_at = Time.current
    refresh_result = refresh_snapshot_for_route_proof(position)
    position.reload
    snapshot = position.position_dashboard_snapshot
    fallback_result = ensure_snapshot_migration_fields(position, snapshot)
    snapshot = position.position_dashboard_snapshot.reload if fallback_result[:updated]
    proof_started_at = Time.current
    snapshot_age_at_start = snapshot_age_seconds(snapshot, at: proof_started_at)
    snapshot_status_at_start = snapshot_status(snapshot, at: proof_started_at)
    if refresh_result[:error].present?
      puts JSON.pretty_generate(
        status: "blocked",
        action: "migration_route_proof_summary",
        position_id: position.id,
        blockers: [ "Snapshot refresh before route proof failed: #{refresh_result[:error]}" ],
        snapshot_refreshed_before_proof: refresh_result.fetch(:refreshed),
        proof_started_at: proof_started_at.utc.iso8601,
        snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
        snapshot_age_seconds_at_start: snapshot_age_at_start,
        snapshot_status_at_start: snapshot_status_at_start,
        route_plans_used_fresh_snapshot: false,
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    summary = HedgeVenueMigrationRouteMatrix.new(position: position, snapshot: snapshot, now: -> { proof_started_at }).prove_routes!
    proof_finished_at = Time.current
    summary.merge!(
      snapshot_refreshed_before_proof: refresh_result.fetch(:refreshed),
      proof_started_at: proof_started_at.utc.iso8601,
      proof_finished_at: proof_finished_at.utc.iso8601,
      proof_duration_seconds: (proof_finished_at - task_started_at).round(3),
      snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      snapshot_missing_fields: snapshot&.missing_migration_fields,
      snapshot_age_seconds_at_start: snapshot_age_at_start,
      snapshot_status_at_start: snapshot_status_at_start,
      snapshot_age_seconds_at_end: snapshot_age_seconds(snapshot, at: proof_finished_at),
      snapshot_status_at_end: snapshot_status(snapshot, at: proof_finished_at),
      route_plans_used_fresh_snapshot: snapshot_status_at_start == "fresh",
      route_plans_used_complete_snapshot: snapshot&.migration_complete_for_proof?,
      snapshot_refresh_reason: refresh_result[:reason],
      snapshot_fallback_warning: fallback_result[:warning]
    ).compact!
    puts JSON.pretty_generate(summary)
  end

  desc "Write a read-only random venue rotation decision receipt for a position"
  task random_rotation_decision: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "random_rotation_decision",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    matrix = HedgeVenueMigrationRouteMatrix.new(position: position).report
    use_virtual_state = ActiveModel::Type::Boolean.new.cast(ENV["use_virtual_state"].presence || ENV["USE_VIRTUAL_STATE"])
    state = use_virtual_state ? MigrationRandomRotationVirtualState.new(position: position).current : nil
    planner = HedgeVenueAutoMigrationPlanner.new(
      route_matrix: matrix,
      current_venue_override: state&.fetch(:virtual_current_venue, nil),
      virtual_mode: use_virtual_state
    )
    result = planner.plan(position: position)
    path = planner.write_receipt(result.receipt)
    puts JSON.pretty_generate(result.receipt.merge(receipt_path: path&.to_s, virtual_state: state).compact)
  end

  desc "Run the read-only daily random rotation dry-run workflow"
  task daily_random_rotation_dry_run: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    force = ActiveModel::Type::Boolean.new.cast(ENV["force"].presence || ENV["FORCE"])
    enabled_override = ActiveModel::Type::Boolean.new.cast(ENV["enabled_override"].presence || ENV["ENABLED_OVERRIDE"])
    seed = ENV["seed"].presence || ENV["MIGRATION_RANDOM_SEED"].presence
    result = MigrationRandomRotationDailyRunner.new.call(
      position_id: position_id,
      force: force,
      seed: seed,
      enabled_override: enabled_override
    )

    puts JSON.pretty_generate(
      action: "daily_random_rotation_dry_run_summary",
      status: result.status,
      position_id: position_id,
      positions: result.positions,
      blockers: result.blockers,
      warnings: result.warnings,
      orders_submitted: result.orders_submitted,
      signatures_created: result.signatures_created
    )
  end

  desc "Show read-only random rotation virtual state for a position"
  task random_rotation_state: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "random_rotation_state",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    state = MigrationRandomRotationVirtualState.new(position: position).current
    puts JSON.pretty_generate(state.merge(action: "random_rotation_state", status: "ok"))
  end

  desc "Reset read-only random rotation virtual state to the production venue"
  task reset_random_rotation_state: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "reset_random_rotation_state",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    state = MigrationRandomRotationVirtualState.new(position: position).reset!
    puts JSON.pretty_generate(state.merge(action: "reset_random_rotation_state", status: "ok"))
  end

  desc "Show read-only live autopilot readiness for a position"
  task live_autopilot_readiness: :environment do
    position = migration_position_from_env(action: "live_autopilot_readiness")
    next unless position

    puts JSON.pretty_generate(MigrationLiveAutopilotReadiness.new(position: position).report)
  end

  desc "Show read-only supervised manual live canary readiness for one route"
  task manual_live_canary_readiness: :environment do
    position = migration_position_from_env(action: "manual_live_canary_readiness")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    puts JSON.pretty_generate(MigrationManualLiveCanaryReadiness.new(position: position, from: from, to: to).report)
  end

  desc "Run gated supervised manual live canary if all live gates are open"
  task run_manual_live_canary: :environment do
    position = migration_position_from_env(action: "run_manual_live_canary")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationManualLiveCanaryRunner.new.run(position: position, from: from, to: to, confirmation: confirmation)
    puts JSON.pretty_generate(result.receipt)
  end

  def refresh_snapshot_for_route_proof(position)
    return { refreshed: false, reason: "disabled" } unless refresh_snapshot_for_route_proof?

    snapshot = position.position_dashboard_snapshot
    return { refreshed: false, reason: "fresh_complete" } if snapshot && !snapshot.stale_now? && snapshot.migration_complete_for_proof?

    reason = snapshot_refresh_reason(snapshot)
    DashboardSnapshotRefresh.new(position: position, force: true).refresh
    { refreshed: true, reason: reason }
  rescue => e
    { refreshed: false, reason: "refresh_error", error: "#{e.class}: #{e.message}" }
  end

  def migration_position_from_env(action:)
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)
    return position if position

    puts JSON.pretty_generate(
      status: "blocked",
      action: action,
      position_id: position_id,
      blockers: [ "Position #{position_id || '(missing)'} not found." ],
      orders_submitted: 0,
      signatures_created: 0
    )
    nil
  end

  def snapshot_refresh_reason(snapshot)
    return "missing" unless snapshot
    return "stale" if snapshot.stale_now?
    return "incomplete: #{snapshot.missing_migration_fields.join(', ')}" unless snapshot.migration_complete_for_proof?

    "fresh_complete"
  end

  def ensure_snapshot_migration_fields(position, snapshot)
    return { updated: false } unless snapshot
    return { updated: false } if snapshot.migration_complete_for_proof?

    target = computed_target_short(position)
    combined = computed_combined_short(snapshot)
    tolerance = target && position.hedge ? target * position.hedge.tolerance : nil
    drift = target && combined ? target - combined : nil
    attrs = {
      target_short_eth: snapshot.target_short_eth || target,
      tolerance_abs_eth: snapshot.tolerance_abs_eth || tolerance,
      combined_short_eth: snapshot.combined_short_eth || combined,
      drift_eth: snapshot.drift_eth || drift,
      inside_tolerance: snapshot.inside_tolerance.nil? && drift && tolerance ? drift.abs <= tolerance : snapshot.inside_tolerance
    }.compact
    return { updated: false } if attrs.empty?

    snapshot.update!(attrs)
    if snapshot.migration_complete_for_proof?
      { updated: true, warning: "target_short_eth computed from Position/Hedge because snapshot field was missing" }
    else
      { updated: true, warning: "snapshot migration fields remain incomplete: #{snapshot.missing_migration_fields.join(', ')}" }
    end
  end

  def computed_target_short(position)
    return nil unless position.asset0_amount && position.hedge

    position.asset0_amount * position.hedge.target
  end

  def computed_combined_short(snapshot)
    values = [ snapshot.extended_short_eth, snapshot.ethereal_short_eth, snapshot.nado_short_eth ]
    return nil unless values.all?

    values.sum(BigDecimal("0"))
  end

  def refresh_snapshot_for_route_proof?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("refresh_snapshot", "true"))
  end

  def snapshot_age_seconds(snapshot, at: Time.current)
    return nil unless snapshot&.refreshed_at

    (at - snapshot.refreshed_at).round
  end

  def snapshot_status(snapshot, at: Time.current)
    return "missing" unless snapshot
    return "stale" if snapshot.stale_at?(at)
    return "incomplete" unless snapshot.migration_complete_for_proof?

    snapshot.refresh_status == "ok" ? "fresh" : snapshot.refresh_status
  end
end
