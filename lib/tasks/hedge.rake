namespace :hedge do
  desc "Strictly gated emergency restore of the production Extended hedge; dry-run by default"
  task emergency_restore: :environment do
    run_hedge_emergency_task(action: "restore")
  end

  desc "Refresh source exposure and adjust the production Extended hedge to fresh target; dry-run by default"
  task emergency_refresh_and_adjust: :environment do
    run_hedge_emergency_task(action: "adjust")
  end

  desc "Fallback operator-provided Extended target adjustment; dry-run by default"
  task emergency_adjust_extended_to_target: :environment do
    run_hedge_emergency_task(action: "explicit_adjust")
  end

  def run_hedge_emergency_task(action:)
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    dry_run = if ENV.key?("dry_run") || ENV.key?("DRY_RUN")
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    else
      !live
    end
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    position = Position.includes(:dex, :hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "hedge_emergency_#{action}",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      return
    end

    result = HedgeEmergencyRestore.new(
      position: position,
      dry_run: dry_run,
      live: live,
      confirmation: confirmation,
      explicit_position_id: position_id.present?,
      action: action,
      target_short_eth: ENV["target_short_eth"].presence || ENV["TARGET_SHORT_ETH"].presence
    ).run

    puts JSON.pretty_generate(result.receipt)
    abort("Emergency hedge #{action} blocked: #{result.blockers.join('; ')}") if live && result.status != "RESTORE_CONFIRMED"
  end
end
