namespace :auto do
  def auto_position
    id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    abort("position_id is required") if id.blank?

    Position.includes(:hedge, :position_dashboard_snapshot).find(id)
  end

  desc "List active production auto-rebalance setting state without live actions"
  task list: :environment do
    position = auto_position
    payload = AutoRebalanceControl.new(position: position, venue: ENV["venue"].presence || ENV["VENUE"].presence).status
    puts JSON.pretty_generate(payload.merge(action: "auto_list"))
  end

  desc "Enable or disable one active production venue auto loop without live actions"
  task set: :environment do
    position = auto_position
    venue = ENV["venue"].presence || ENV["VENUE"].presence
    enabled = ENV["enabled"].presence || ENV["ENABLED"].presence
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    control = AutoRebalanceControl.new(position: position, venue: venue)
    result = control.set!(enabled: enabled, confirmation: confirmation)
    puts JSON.pretty_generate(
      result.payload.merge(
        action: "auto_set",
        ok: result.ok,
        errors: result.errors
      )
    )
  end

  desc "Disable all venue, migration, and random auto loops without live actions"
  task disable_all: :environment do
    position = auto_position
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = AutoRebalanceControl.new(position: position).disable_all!(confirmation: confirmation)
    puts JSON.pretty_generate(
      result.payload.merge(
        action: "auto_disable_all",
        ok: result.ok,
        errors: result.errors
      )
    )
  end
end
