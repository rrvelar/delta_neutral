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

    summary = HedgeVenueMigrationRouteMatrix.new(position: position).prove_routes!
    puts JSON.pretty_generate(summary)
  end
end
