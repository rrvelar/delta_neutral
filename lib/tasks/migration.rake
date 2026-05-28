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

    refresh_result = refresh_snapshot_for_route_proof(position)
    position.reload
    snapshot = position.position_dashboard_snapshot
    summary = HedgeVenueMigrationRouteMatrix.new(position: position, snapshot: snapshot).prove_routes!
    summary.merge!(
      snapshot_refreshed_before_proof: refresh_result.fetch(:refreshed),
      snapshot_age_seconds: snapshot_age_seconds(snapshot),
      snapshot_status: snapshot_status(snapshot),
      snapshot_refresh_error: refresh_result[:error]
    ).compact!
    puts JSON.pretty_generate(summary)
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

  def snapshot_age_seconds(snapshot)
    return nil unless snapshot&.refreshed_at

    (Time.current - snapshot.refreshed_at).round
  end

  def snapshot_status(snapshot)
    return "missing" unless snapshot
    return "stale" if snapshot.stale_now?

    snapshot.refresh_status
  end
end
