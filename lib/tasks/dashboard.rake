namespace :dashboard do
  desc "Refresh the persisted read-only dashboard snapshot for one position"
  task refresh_position_snapshot: :environment do
    position_id = ENV["position_id"] || ENV["POSITION_ID"] || ARGV.find { |arg| arg.start_with?("position_id=") }&.split("=", 2)&.last
    abort("position_id is required") if position_id.blank?

    position = Position.includes(:dex, :hedge, wallet: :network).find(position_id)
    snapshot = DashboardSnapshotRefresh.new(position: position).refresh

    puts JSON.pretty_generate(
      position_id: position.id,
      snapshot_id: snapshot.id,
      refreshed_at: snapshot.refreshed_at&.iso8601,
      refresh_status: snapshot.refresh_status,
      production_venue: snapshot.production_venue,
      target_short_eth: snapshot.decimal_string(snapshot.target_short_eth),
      extended_short_eth: snapshot.decimal_string(snapshot.extended_short_eth),
      ethereal_short_eth: snapshot.decimal_string(snapshot.ethereal_short_eth),
      nado_short_eth: snapshot.decimal_string(snapshot.nado_short_eth),
      combined_short_eth: snapshot.decimal_string(snapshot.combined_short_eth),
      drift_eth: snapshot.decimal_string(snapshot.drift_eth),
      inside_tolerance: snapshot.inside_tolerance,
      extended_status: snapshot.extended_status,
      ethereal_status: snapshot.ethereal_status,
      nado_status: snapshot.nado_status,
      signer_status: snapshot.signer_status,
      timeout_seconds_used: snapshot.timeout_seconds_used&.to_s("F"),
      extended_critical_read_duration_ms: snapshot.extended_critical_read_duration_ms,
      extended_critical_read_status: snapshot.extended_critical_read_status,
      extended_optional_read_duration_ms: snapshot.extended_optional_read_duration_ms,
      extended_optional_read_status: snapshot.extended_optional_read_status,
      extended_value_stale_as_of: snapshot.extended_value_stale_as_of&.iso8601,
      orders_submitted: 0,
      signatures_created: 0,
      source_errors: snapshot.source_errors_hash
    )
  end
end
