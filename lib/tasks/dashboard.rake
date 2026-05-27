namespace :dashboard do
  def dashboard_position_from_env
    position_id = ENV["position_id"] || ENV["POSITION_ID"] || ARGV.find { |arg| arg.start_with?("position_id=") }&.split("=", 2)&.last
    abort("position_id is required") if position_id.blank?

    Position.includes(:dex, :hedge, wallet: :network).find(position_id)
  end

  desc "Refresh the persisted read-only dashboard snapshot for one position"
  task refresh_position_snapshot: :environment do
    position = dashboard_position_from_env
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

  desc "Refresh the persisted read-only rewards/fees snapshot for one position"
  task refresh_rewards_fees_snapshot: :environment do
    position = dashboard_position_from_env
    snapshot = RewardsFeesSnapshotRefresh.new(position: position).refresh

    puts JSON.pretty_generate(
      position_id: position.id,
      snapshot_id: snapshot.id,
      refreshed_at: snapshot.refreshed_at&.iso8601,
      refresh_status: snapshot.refresh_status,
      aero_rewards_amount: snapshot.aero_rewards_amount&.to_s("F"),
      aero_rewards_usd: snapshot.aero_rewards_usd&.to_s("F"),
      lp_fee_total_usd: snapshot.lp_fee_total_usd&.to_s("F"),
      rewards_value_state: snapshot.rewards_value_state,
      fee_value_state: snapshot.fee_value_state,
      orders_submitted: snapshot.orders_submitted,
      signatures_created: snapshot.signatures_created,
      source_errors: snapshot.source_errors_hash
    )
  end

  desc "Refresh the persisted read-only hedge accounting snapshot for one position"
  task refresh_hedge_accounting_snapshot: :environment do
    position = dashboard_position_from_env
    snapshot = HedgeAccountingSnapshotRefresh.new(position: position).refresh

    puts JSON.pretty_generate(
      position_id: position.id,
      snapshot_id: snapshot.id,
      refreshed_at: snapshot.refreshed_at&.iso8601,
      refresh_status: snapshot.refresh_status,
      venue: snapshot.venue,
      current_short_eth: snapshot.current_short_eth&.to_s("F"),
      unrealized_pnl_usd: snapshot.unrealized_pnl_usd&.to_s("F"),
      realized_pnl_usd: snapshot.realized_pnl_usd&.to_s("F"),
      net_hedge_pnl_usd: snapshot.net_hedge_pnl_usd&.to_s("F"),
      unavailable_components: snapshot.unavailable_components_list,
      orders_submitted: snapshot.orders_submitted,
      signatures_created: snapshot.signatures_created,
      source_errors: snapshot.source_errors_hash
    )
  end

  desc "Refresh all persisted read-only dashboard snapshots for one position"
  task refresh_all_position_snapshots: :environment do
    position = dashboard_position_from_env
    exposure = DashboardSnapshotRefresh.new(position: position).refresh
    rewards = RewardsFeesSnapshotRefresh.new(position: position.reload).refresh
    accounting = HedgeAccountingSnapshotRefresh.new(position: position.reload).refresh

    puts JSON.pretty_generate(
      position_id: position.id,
      position_snapshot_id: exposure.id,
      rewards_fees_snapshot_id: rewards.id,
      hedge_accounting_snapshot_id: accounting.id,
      refresh_statuses: {
        position: exposure.refresh_status,
        rewards_fees: rewards.refresh_status,
        hedge_accounting: accounting.refresh_status
      },
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  desc "Print read-only production health for one position"
  task production_health: :environment do
    position = dashboard_position_from_env
    report = ExtendedAutoOperationalHealth.new(position: position).report

    puts JSON.pretty_generate(
      production_health: {
        status: report.fetch(:status),
        warnings: report.fetch(:warnings),
        action_required: report.fetch(:action_required)
      },
      current_snapshot_summary: {
        snapshot: report.fetch(:snapshot),
        exposure: report.fetch(:exposure),
        rewards_snapshot: report.fetch(:rewards_snapshot),
        accounting_snapshot: report.fetch(:accounting_snapshot)
      },
      auto_health_summary: {
        auto: report.fetch(:auto),
        signer: report.fetch(:signer),
        auto_should_act: report.fetch(:auto_should_act),
        auto_should_be_waiting: report.fetch(:auto_should_be_waiting),
        duplicate_risk_detected: report.fetch(:duplicate_risk_detected),
        frequent_rebalance_warning: report.fetch(:frequent_rebalance_warning)
      },
      last_rebalances: {
        latest: report.fetch(:latest_rebalance),
        last_successful: report.fetch(:last_successful_rebalance),
        pending_count_last_24h: report.fetch(:pending_count_last_24h),
        failed_count_last_24h: report.fetch(:failed_count_last_24h)
      },
      orders_submitted: report.fetch(:orders_submitted),
      signatures_created: report.fetch(:signatures_created)
    )
  end
end
