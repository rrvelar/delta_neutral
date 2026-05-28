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
    planner = HedgeVenueAutoMigrationPlanner.new(route_matrix: matrix)
    result = planner.plan(position: position)
    path = planner.write_receipt(result.receipt)
    puts JSON.pretty_generate(result.receipt.merge(receipt_path: path&.to_s))
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
