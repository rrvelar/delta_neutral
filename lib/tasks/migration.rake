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
      snapshot_age_seconds_at_start: snapshot_age_at_start,
      snapshot_status_at_start: snapshot_status_at_start,
      snapshot_age_seconds_at_end: snapshot_age_seconds(snapshot, at: proof_finished_at),
      snapshot_status_at_end: snapshot_status(snapshot, at: proof_finished_at),
      route_plans_used_fresh_snapshot: snapshot_status_at_start == "fresh"
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
    return { refreshed: false } unless refresh_snapshot_for_route_proof?

    snapshot = position.position_dashboard_snapshot
    return { refreshed: false } if snapshot && !snapshot.stale_now?

    DashboardSnapshotRefresh.new(position: position, force: true).refresh
    { refreshed: true }
  rescue => e
    { refreshed: false, error: "#{e.class}: #{e.message}" }
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

    snapshot.refresh_status == "ok" ? "fresh" : snapshot.refresh_status
  end
end
