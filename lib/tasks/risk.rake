namespace :risk do
  desc "List whitelisted runtime risk settings without live exchange actions"
  task list: :environment do
    rows = RiskSettings.list.map do |setting|
      {
        key: setting.key,
        value: setting.raw_value,
        parsed_value: setting.value&.to_s("F"),
        source: setting.source
      }
    end
    puts JSON.pretty_generate(action: "risk_list", settings: rows, restart_required: false, orders_submitted: 0, signatures_created: 0)
  end

  desc "Set a whitelisted risk setting: key=ETHEREAL_MAX_SHORT_ETH value=2 confirmation=..."
  task set: :environment do
    result = RiskSettings.set!(
      key: ENV["key"] || ENV["KEY"],
      value: ENV["value"] || ENV["VALUE"],
      reason: ENV["reason"] || ENV["REASON"],
      confirmation: ENV["confirmation"] || ENV["CONFIRMATION"]
    )
    puts JSON.pretty_generate(
      action: "risk_set",
      ok: result.ok,
      key: result.setting&.key || ENV["key"] || ENV["KEY"],
      value: result.setting&.value || ENV["value"] || ENV["VALUE"],
      errors: result.errors,
      restart_required: false,
      orders_submitted: 0,
      signatures_created: 0
    )
  end
end

namespace :hedge do
  desc "Print no-live cap diagnostics for a position and venue"
  task cap_diagnostics: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    abort("position_id is required") if position_id.blank?

    position = Position.includes(:hedge).find(position_id)
    venue = ENV["venue"].presence || ENV["VENUE"].presence || position.hedge&.execution_venue || HedgeVenues.default_supported
    report = AerodromeDashboardHedgeAction.new(position: position, action: "open", execute: false, venue: venue).report
    puts JSON.pretty_generate(
      action: "hedge_cap_diagnostics",
      position_id: position.id,
      venue: HedgeVenues.normalize(venue),
      cap_diagnostics: report.fetch(:cap_diagnostics),
      blockers: report.fetch(:blockers),
      orders_submitted: 0,
      signatures_created: 0
    )
  end
end
