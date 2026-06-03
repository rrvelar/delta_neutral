namespace :risk do
  desc "List whitelisted runtime risk settings without live exchange actions"
  task list: :environment do
    rows = RiskSettings.list.map do |setting|
      {
        key: setting.key,
        value: setting.raw_value,
        parsed_value: setting.value&.to_s("F"),
        source: setting.source,
        layer: RiskSettings.hard_key?(setting.key) ? "hard_ceiling" : "runtime",
        valid: RiskSettings.hard_ceiling_validation_errors(setting.key, setting.raw_value).empty?,
        validation_errors: RiskSettings.hard_ceiling_validation_errors(setting.key, setting.raw_value)
      }
    end
    puts JSON.pretty_generate(
      action: "risk_list",
      settings: rows,
      runtime_caps: rows.reject { |row| row.fetch(:layer) == "hard_ceiling" },
      hard_ceilings: rows.select { |row| row.fetch(:layer) == "hard_ceiling" },
      restart_required: false,
      orders_submitted: 0,
      signatures_created: 0
    )
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

  desc "Recommend no-live risk limits for a position and venue"
  task recommend: :environment do
    position = Position.includes(:hedge, :position_dashboard_snapshot).find(ENV["position_id"] || ENV["POSITION_ID"])
    venue = ENV["venue"] || ENV["VENUE"] || position.hedge&.execution_venue
    puts JSON.pretty_generate(
      RiskLimitRecommendation.new(position: position, venue: venue).report.merge(
        action: "risk_recommend",
        orders_submitted: 0,
        signatures_created: 0
      )
    )
  end

  desc "Apply no-live recommended risk limits for a position and venue"
  task apply_recommended: :environment do
    position = Position.includes(:hedge, :position_dashboard_snapshot).find(ENV["position_id"] || ENV["POSITION_ID"])
    venue = ENV["venue"] || ENV["VENUE"] || position.hedge&.execution_venue
    result = RiskLimitRecommendation.new(position: position, venue: venue).apply!(
      reason: ENV["reason"] || ENV["REASON"],
      confirmation: ENV["confirmation"] || ENV["CONFIRMATION"]
    )
    puts JSON.pretty_generate(
      action: "risk_apply_recommended",
      ok: result.ok,
      errors: result.errors,
      applied: result.applied,
      recommendation: result.recommendation,
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
