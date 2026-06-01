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

  desc "Read-only production dashboard smoke diagnostics for one position"
  task production_smoke: :environment do
    position_id = ENV["position_id"] || ENV["POSITION_ID"] || ARGV.find { |arg| arg.start_with?("position_id=") }&.split("=", 2)&.last
    route_exists = Rails.application.routes.routes.any? { |route| route.name == "mellow_autopilot_probe" }
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        action: "dashboard_production_smoke",
        status: "blocked",
        blocker: "position #{position_id || '(missing)'} not found in local DB",
        current_mellow_exposure_source: nil,
        current_target_short_eth: nil,
        extended_current_short_eth: nil,
        extended_auto_within_tolerance: nil,
        extended_auto_planned_action: nil,
        extended_auto_suppressed_reason: nil,
        current_resolver_status: "blocked",
        current_resolver_successful_method: nil,
        legacy_rewards_status: "blocked",
        legacy_rewards_error: "position not found in local DB",
        hedge_control_uses_readiness_preview: false,
        stale_preview_warning_present: false,
        dashboard_header_status: "blocked",
        production_health_status: "blocked",
        production_health_reason: "position not found in local DB",
        hedge_control_action_label: "blocked",
        mismatch_warnings: [ "position not found in local DB" ],
        tx_hash_onboarding_route_exists: route_exists,
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    mellow = safe_smoke_section { MellowCurrentExposureResolver.new(position: position).resolve }
    readiness = canonical_auto_readiness_for_smoke(position)
    random_migration = safe_smoke_section { MigrationRandomReadiness.new(position: position).report }
    active_auto_readiness = {
      continuous_auto_ready: readiness[:continuous_auto_ready],
      planned_auto_action: readiness[:planned_auto_action],
      action_suppressed_reason: readiness[:action_suppressed_reason],
      min_rebalance_size_eth: readiness[:min_rebalance_size_eth],
      cooldown_remaining_seconds: readiness[:cooldown_remaining_seconds],
      consecutive_outside_tolerance_count: readiness[:consecutive_outside_tolerance_count],
      strong_drift_bypass_used: readiness[:strong_drift_bypass_used],
      blockers: readiness[:blockers]
    }
    rewards_snapshot = position.position_rewards_fees_snapshot
    snapshot = position.position_dashboard_snapshot
    last_success = position.hedge&.short_rebalances&.where(venue: "extended", asset: [ nil, "ETH", "WETH" ], status: ShortRebalance::STATUS_SUCCESS)&.order(rebalanced_at: :desc, created_at: :desc)&.first

    puts JSON.pretty_generate(
      action: "dashboard_production_smoke",
      status: "ok",
      position_id: position.id,
      mellow_current_exposure_status: mellow[:status],
      current_resolver_status: mellow[:status],
      current_mellow_exposure_source: mellow[:exposure_source] || position.mellow_metadata_hash["exposure_source"],
      current_resolver_successful_method: mellow[:successful_method] || position.mellow_metadata_hash["successful_method"],
      successful_method: mellow[:successful_method] || position.mellow_metadata_hash["successful_method"],
      legacy_rewards_status: rewards_snapshot&.refresh_status || "not_loaded",
      legacy_rewards_error: legacy_rewards_error(position, rewards_snapshot),
      db_asset0_amount: position.asset0_amount&.to_s("F"),
      db_asset1_amount: position.asset1_amount&.to_s("F"),
      production_venue: active_readiness_value(readiness, :execution_venue) || position.hedge&.execution_venue,
      active_auto_venue: active_readiness_value(readiness, :active_auto_venue),
      active_current_short_eth: active_readiness_value(readiness, :active_current_short_eth),
      active_target_short_eth: active_readiness_value(readiness, :active_target_short_eth),
      active_drift_eth: active_readiness_value(readiness, :active_drift_eth),
      active_tolerance_eth: active_readiness_value(readiness, :active_tolerance_eth),
      active_within_tolerance: active_readiness_value(readiness, :active_within_tolerance),
      active_planned_auto_action: active_readiness_value(readiness, :active_planned_auto_action),
      active_auto_enabled: active_readiness_value(readiness, :active_auto_enabled),
      active_live_enabled: active_readiness_value(readiness, :active_live_enabled),
      active_auto_ready: active_readiness_value(readiness, :active_auto_ready),
      continuous_auto_ready: readiness[:continuous_auto_ready],
      active_auto_blockers: active_readiness_value(readiness, :active_auto_blockers),
      active_auto_warnings: active_readiness_value(readiness, :active_auto_warnings),
      current_target_short_eth: readiness[:target_short_eth],
      extended_current_short_eth: readiness[:extended_current_short_eth],
      ethereal_current_short_eth: active_readiness_value(readiness, :ethereal_current_short_eth),
      extended_auto_within_tolerance: readiness[:within_tolerance],
      extended_auto_planned_action: readiness[:planned_auto_action],
      extended_auto_suppressed_reason: readiness[:action_suppressed_reason],
      dashboard_header_status: dashboard_header_status(readiness),
      production_health_status: dashboard_production_health_status(readiness),
      production_health_reason: dashboard_production_health_reason(readiness),
      hedge_control_action_label: dashboard_hedge_control_action_label(readiness),
      hedge_control_uses_readiness_preview: dashboard_readiness_preview_available?(readiness),
      stale_preview_warning_present: !dashboard_readiness_preview_available?(readiness),
      mismatch_warnings: dashboard_mismatch_warnings(snapshot, readiness),
      non_production_venue_diagnostics: {
        extended: { short_eth: snapshot&.extended_short_eth&.to_s("F") },
        ethereal: { short_eth: snapshot&.ethereal_short_eth&.to_s("F") },
        nado: { short_eth: snapshot&.nado_short_eth&.to_s("F") }
      },
      combined_hedge: {
        extended_short_eth: snapshot&.extended_short_eth&.to_s("F"),
        ethereal_short_eth: snapshot&.ethereal_short_eth&.to_s("F"),
        nado_short_eth: snapshot&.nado_short_eth&.to_s("F"),
        combined_short_eth: snapshot&.combined_short_eth&.to_s("F"),
        combined_inside_tolerance: snapshot&.inside_tolerance
      },
      active_auto_readiness: active_auto_readiness,
      extended_auto_readiness: active_auto_readiness,
      random_migration_status: random_migration[:current_safe_to_live_if_operator_gates_open] ? "ready" : "not_ready",
      random_migration_next_canary: random_migration[:next_recommended_canary],
      random_migration_route_proofs: random_migration[:route_proof_statuses],
      random_migration_missing_proofs: random_migration[:missing_route_proofs],
      random_migration_enabled: random_migration.dig(:random_live_gates, :migration_random_rotation_live_enabled),
      last_successful_extended_rebalance: last_success && {
        id: last_success.id,
        old_short_size: last_success.old_short_size&.to_s("F"),
        new_short_size: last_success.new_short_size&.to_s("F"),
        rebalanced_at: last_success.rebalanced_at&.iso8601,
        exchange_order_id: last_success.exchange_order_id
      },
      dashboard_emergency_section_visible: dashboard_emergency_visible?(snapshot),
      tx_hash_onboarding_route_exists: route_exists,
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def safe_smoke_section
    yield
  rescue => e
    { status: "blocked", blockers: [ "#{e.class}: #{e.message}" ], orders_submitted: 0, signatures_created: 0 }
  end

  def canonical_auto_readiness_for_smoke(position)
    safe_smoke_section { HedgeVenueAutoReadiness.new.report(position: position) }.to_h.deep_symbolize_keys
  end

  def active_readiness_value(readiness, key)
    active_venue = readiness[:active_auto_venue].presence || readiness[:venue].presence || readiness[:execution_venue].presence
    return readiness[:current_short_eth] if key == :active_current_short_eth && readiness[:active_current_short_eth].blank?
    return readiness[:target_short_eth] if key == :active_target_short_eth && readiness[:active_target_short_eth].blank?
    return readiness[:drift_eth] if key == :active_drift_eth && readiness[:active_drift_eth].blank?
    return readiness[:tolerance_eth] if key == :active_tolerance_eth && readiness[:active_tolerance_eth].blank?
    return readiness[:within_tolerance] if key == :active_within_tolerance && readiness[:active_within_tolerance].nil?
    return readiness[:planned_auto_action] if key == :active_planned_auto_action && readiness[:active_planned_auto_action].blank?
    return readiness[:blockers] if key == :active_auto_blockers && readiness[:active_auto_blockers].blank?
    return readiness[:warnings] if key == :active_auto_warnings && readiness[:active_auto_warnings].blank?
    return readiness[:current_short_eth] if key == :ethereal_current_short_eth && active_venue == "ethereal" && readiness[:ethereal_current_short_eth].blank?

    readiness[key]
  end

  def dashboard_emergency_visible?(snapshot)
    return false unless snapshot&.production_venue == "extended"
    return true if snapshot.inside_tolerance == false

    snapshot.stale_now? || snapshot.target_short_eth.nil? || snapshot.combined_short_eth.nil?
  end

  def dashboard_header_status(readiness)
    within = readiness[:active_within_tolerance].nil? ? readiness[:within_tolerance] : readiness[:active_within_tolerance]
    return "Unknown / diagnostics unavailable" if within.nil?

    within ? "In tolerance" : "Out of tolerance"
  end

  def dashboard_production_health_status(readiness)
    return "WATCH" if readiness[:action_suppressed_reason].present?
    return "HEALTHY" if readiness[:active_within_tolerance] == true || readiness[:within_tolerance] == true
    return "ACTION PENDING" if readiness[:auto_can_act] == true
    return "BLOCKED" if readiness[:target_short_eth].blank?
    return "BLOCKED" if Array(readiness[:blockers]).any? { |blocker| blocker.to_s.include?("AUTO_REBALANCE_ENABLED") || blocker.to_s.include?("LIVE_ENABLED") }
    return "ACTION REQUIRED" if Array(readiness[:blockers]).present?

    "WATCH"
  end

  def dashboard_hedge_control_action_label(readiness)
    return "Waiting / suppressed: #{readiness[:action_suppressed_reason]}" if readiness[:action_suppressed_reason].present?

    case readiness[:planned_auto_action].to_s
    when "no_op" then "No-op / inside tolerance"
    when "increase_short" then "SELL non-reduce-only / increase short"
    when "decrease_short" then "BUY reduce-only / reduce short"
    when "blocked" then "Blocked / fresh target required"
    else readiness[:planned_auto_action].presence || "Unknown"
    end
  end

  def dashboard_production_health_reason(readiness)
    return "inside tolerance" if readiness[:active_within_tolerance] == true || readiness[:within_tolerance] == true
    return readiness[:action_suppressed_reason] if readiness[:action_suppressed_reason].present?
    return "auto_can_act=true" if readiness[:auto_can_act] == true
    return "fresh exposure unavailable" if readiness[:target_short_eth].blank?

    Array(readiness[:blockers]).first
  end

  def dashboard_readiness_preview_available?(readiness)
    readiness[:target_short_eth].present? &&
      (readiness[:active_current_short_eth].present? || readiness[:extended_current_short_eth].present?) &&
      (readiness[:planned_auto_action].to_s.in?(%w[no_op decrease_short increase_short]) || readiness[:action_suppressed_reason].present?)
  end

  def legacy_rewards_error(position, snapshot)
    return nil unless position.mellow_autopilot?

    error = [ snapshot&.rewards_stop_reason, snapshot&.fee_stop_reason, *snapshot&.warnings_list ].compact.find { |message| message.to_s.match?(/erc721|owner|token|nonexistent|not found|missing/i) }
    return nil unless error

    token_id = position.mellow_metadata_hash["strategy_token_id"].presence || position.external_id.to_s.delete_prefix("mellow:")
    "Legacy rewards/fees read unavailable for historical token #{token_id}: #{error}"
  end

  def dashboard_mismatch_warnings(snapshot, readiness)
    warnings = []
    if snapshot && !readiness[:within_tolerance].nil? && snapshot.inside_tolerance != readiness[:within_tolerance]
      warnings << "snapshot inside_tolerance=#{snapshot.inside_tolerance} differs from current active readiness #{readiness[:active_within_tolerance] || readiness[:within_tolerance]}"
    end
    if snapshot&.target_short_eth && readiness[:target_short_eth].present? && snapshot.target_short_eth.to_d != readiness[:target_short_eth].to_d
      warnings << "snapshot target_short_eth=#{snapshot.target_short_eth.to_s('F')} differs from current target #{readiness[:target_short_eth]}"
    end
    warnings
  rescue ArgumentError
    warnings << "target comparison unavailable"
  end
end
