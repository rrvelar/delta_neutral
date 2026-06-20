class ExtendedAutoOperationalHealth
  STATUS_HEALTHY = "HEALTHY".freeze
  STATUS_WATCH = "WATCH".freeze
  STATUS_ACTION_REQUIRED = "ACTION REQUIRED".freeze
  STATUS_UNKNOWN = "UNKNOWN".freeze

  DEFAULT_CRITICAL_STALE_AFTER_SECONDS = 300
  DEFAULT_PENDING_REBALANCE_STALE_AFTER_SECONDS = 600
  DEFAULT_FREQUENT_REBALANCE_WINDOW_HOURS = 2
  DEFAULT_FREQUENT_REBALANCE_COUNT = 6
  DEFAULT_DUPLICATE_GUARD_SECONDS = 60

  def initialize(position:, env: ENV, now: -> { Time.current })
    @position = position
    @env = env
    @now = now
  end

  def report
    warnings = []
    action_required = []
    snapshot = position.position_dashboard_snapshot
    rewards = position.position_rewards_fees_snapshot
    accounting = position.position_hedge_accounting_snapshot
    history = extended_history
    latest = history.first
    last_success = history.find { |row| row.status == ShortRebalance::STATUS_SUCCESS }

    if snapshot.nil?
      action_required << "Position dashboard snapshot is missing."
      return base_report(snapshot: nil, rewards: rewards, accounting: accounting, latest: latest, last_success: last_success, warnings: warnings, action_required: action_required, status: STATUS_UNKNOWN)
    end

    snapshot_age = age_seconds(snapshot.refreshed_at)
    warnings << "Position dashboard snapshot is stale." if snapshot.stale_now?
    action_required << "Position dashboard snapshot exceeds critical stale threshold." if snapshot_age && snapshot_age > critical_stale_after_seconds
    action_required << "Production venue is #{HedgeVenues.label(snapshot.production_venue)}, expected Extended." unless snapshot.production_venue == "extended"
    action_required << "Extended current exposure is unknown or errored." if extended_exposure_unknown?(snapshot)
    action_required << "Ethereal is not flat while production venue is Extended." if short_positive?(snapshot.ethereal_short_eth)
    action_required << "Nado is not flat while production venue is Extended." if short_positive?(snapshot.nado_short_eth)
    warnings << "Extended is outside tolerance; auto should act if gates are clear." if snapshot.inside_tolerance == false && snapshot.extended_auto_enabled
    action_required << "Extended open orders are present." if snapshot.open_orders_count_extended.to_i.positive?
    action_required << "Extended signer is down while auto is enabled." if snapshot.extended_auto_enabled && snapshot.signer_status.to_s == "down"

    pending_count = count_status(history, ShortRebalance::STATUS_PENDING, 24.hours.ago)
    failed_count = count_status(history, ShortRebalance::STATUS_FAILED, 24.hours.ago)
    action_required << "Pending Extended rebalance is older than #{pending_rebalance_stale_after_seconds}s." if old_pending_rebalance?(history)
    warnings << "Latest Extended rebalance failed." if latest&.status == ShortRebalance::STATUS_FAILED
    action_required << "Repeated Extended rebalance failures in last 24h." if failed_count >= 3
    action_required << "Duplicate-risk Extended rebalance pattern detected." if duplicate_risk?(history)
    warnings << "Frequent Extended rebalances in recent window." if frequent_rebalance?(history)
    warnings << "Rewards/fees snapshot is stale or missing." if rewards.nil? || rewards.stale_now?
    warnings << "Hedge accounting snapshot is stale or missing." if accounting.nil? || accounting.stale_now?
    warnings << "Optional Extended diagnostics are stale/unavailable." if snapshot.extended_optional_read_status.to_s.in?(%w[error error_carried_forward skipped_throttled])
    warnings << "Auto enabled but position is outside tolerance and no recent rebalance attempt is visible." if auto_enabled_outside_tolerance_without_attempt?(snapshot, latest)

    status = status_for(snapshot: snapshot, warnings: warnings, action_required: action_required)
    base_report(
      snapshot: snapshot,
      rewards: rewards,
      accounting: accounting,
      latest: latest,
      last_success: last_success,
      warnings: warnings.uniq,
      action_required: action_required.uniq,
      status: status,
      pending_count_last_24h: pending_count,
      failed_count_last_24h: failed_count
    )
  end

  private

  attr_reader :position, :env, :now

  def base_report(snapshot:, rewards:, accounting:, latest:, last_success:, warnings:, action_required:, status:, pending_count_last_24h: 0, failed_count_last_24h: 0)
    {
      status: status,
      production_venue: snapshot&.production_venue || position.hedge&.execution_venue,
      production_venue_name: HedgeVenues.label(snapshot&.production_venue || position.hedge&.execution_venue),
      snapshot: snapshot_summary(snapshot),
      rewards_snapshot: snapshot_freshness(rewards),
      accounting_snapshot: snapshot_freshness(accounting),
      exposure: exposure_summary(snapshot),
      auto: auto_summary(snapshot),
      signer: signer_summary(snapshot),
      last_successful_rebalance: rebalance_summary(last_success),
      last_rebalance_age_seconds: age_seconds(last_success&.rebalanced_at || last_success&.created_at),
      latest_rebalance: rebalance_summary(latest),
      pending_count_last_24h: pending_count_last_24h,
      failed_count_last_24h: failed_count_last_24h,
      duplicate_risk_detected: duplicate_risk?(extended_history),
      frequent_rebalance_warning: frequent_rebalance?(extended_history),
      auto_should_be_waiting: snapshot&.inside_tolerance == true,
      auto_should_act: snapshot&.inside_tolerance == false && snapshot&.extended_auto_enabled == true,
      warnings: warnings,
      action_required: action_required,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def snapshot_summary(snapshot)
    return { status: "missing", age_seconds: nil, fresh: false, critical_stale: true } unless snapshot

    age = age_seconds(snapshot.refreshed_at)
    {
      id: snapshot.id,
      refresh_status: snapshot.refresh_status,
      refreshed_at: snapshot.refreshed_at&.utc&.iso8601,
      age_seconds: age,
      fresh: !snapshot.stale_now?,
      critical_stale: age && age > critical_stale_after_seconds,
      recurring_refresh_active: age && age <= critical_stale_after_seconds,
      position_status: snapshot.refresh_status,
      extended_critical_read_status: snapshot.extended_critical_read_status,
      extended_optional_read_status: snapshot.extended_optional_read_status,
      extended_critical_read_duration_ms: snapshot.extended_critical_read_duration_ms,
      extended_optional_read_duration_ms: snapshot.extended_optional_read_duration_ms
    }
  end

  def snapshot_freshness(snapshot)
    return { status: "missing", refreshed_at: nil, age_seconds: nil, stale: true } unless snapshot

    {
      status: snapshot.refresh_status,
      refreshed_at: snapshot.refreshed_at&.utc&.iso8601,
      age_seconds: age_seconds(snapshot.refreshed_at),
      stale: snapshot.stale_now?
    }
  end

  def exposure_summary(snapshot)
    return {} unless snapshot

    {
      extended_short_eth: decimal_string(snapshot.extended_short_eth),
      extended_status: snapshot.extended_status,
      ethereal_short_eth: decimal_string(snapshot.ethereal_short_eth),
      ethereal_status: snapshot.ethereal_status,
      nado_short_eth: decimal_string(snapshot.nado_short_eth),
      nado_status: snapshot.nado_status,
      combined_short_eth: decimal_string(snapshot.combined_short_eth),
      target_short_eth: decimal_string(snapshot.target_short_eth),
      drift_eth: decimal_string(snapshot.drift_eth),
      tolerance_abs_eth: decimal_string(snapshot.tolerance_abs_eth),
      inside_tolerance: snapshot.inside_tolerance,
      open_orders_count_extended: snapshot.open_orders_count_extended
    }
  end

  def auto_summary(snapshot)
    {
      extended_auto_enabled: snapshot&.extended_auto_enabled,
      extended_live_enabled: snapshot&.extended_live_enabled,
      planned_auto_action: snapshot&.planned_auto_action,
      planned_auto_order_size_eth: decimal_string(snapshot&.planned_auto_order_size_eth)
    }
  end

  def signer_summary(snapshot)
    {
      status: snapshot&.signer_status || "unknown",
      checked_at: snapshot&.signer_checked_at&.utc&.iso8601,
      age_seconds: age_seconds(snapshot&.signer_checked_at)
    }
  end

  def rebalance_summary(row)
    return nil unless row

    {
      id: row.id,
      status: row.status,
      old_short_size: decimal_string(row.old_short_size),
      new_short_size: decimal_string(row.new_short_size),
      order_side: row.order_side,
      reduce_only: row.reduce_only,
      rebalanced_at: (row.rebalanced_at || row.created_at)&.utc&.iso8601,
      age_seconds: age_seconds(row.rebalanced_at || row.created_at),
      message: row.message
    }
  end

  def status_for(snapshot:, warnings:, action_required:)
    return STATUS_ACTION_REQUIRED if action_required.any?
    return STATUS_UNKNOWN unless snapshot
    return STATUS_HEALTHY if healthy_snapshot?(snapshot) && warnings.empty?

    STATUS_WATCH
  end

  def healthy_snapshot?(snapshot)
    snapshot.production_venue == "extended" &&
      !snapshot.stale_now? &&
      snapshot.extended_status == "active" &&
      snapshot.extended_short_eth.present? &&
      snapshot.ethereal_status == "flat" &&
      snapshot.nado_status == "flat" &&
      snapshot.inside_tolerance == true &&
      snapshot.signer_status == "ok" &&
      snapshot.open_orders_count_extended.to_i.zero? &&
      no_pending_or_failed_since_last_success?
  end

  def no_pending_or_failed_since_last_success?
    last_success = extended_history.find { |row| row.status == ShortRebalance::STATUS_SUCCESS }
    return false unless last_success

    since = last_success.rebalanced_at || last_success.created_at
    extended_history.none? { |row| row.status != ShortRebalance::STATUS_SUCCESS && (row.rebalanced_at || row.created_at) > since }
  end

  def extended_history
    @extended_history ||= begin
      return [] unless position.hedge

      position.hedge.short_rebalances
        .where(venue: "extended", asset: [ nil, "ETH", "WETH" ])
        .order(rebalanced_at: :desc, created_at: :desc, id: :desc)
        .limit(50)
        .to_a
    end
  end

  def count_status(rows, status, since)
    rows.count { |row| row.status == status && (row.rebalanced_at || row.created_at) >= since }
  end

  def old_pending_rebalance?(rows)
    rows.any? do |row|
      row.status == ShortRebalance::STATUS_PENDING && age_seconds(row.rebalanced_at || row.created_at).to_i > pending_rebalance_stale_after_seconds
    end
  end

  def duplicate_risk?(rows)
    successes = rows.select { |row| row.status == ShortRebalance::STATUS_SUCCESS }.first(5)
    successes.combination(2).any? do |left, right|
      next false unless left.old_short_size && right.old_short_size

      (left.old_short_size - right.old_short_size).abs <= BigDecimal("0.00000001") &&
        ((left.rebalanced_at || left.created_at) - (right.rebalanced_at || right.created_at)).abs <= duplicate_guard_seconds
    end
  end

  def frequent_rebalance?(rows)
    since = frequent_rebalance_window_hours.hours.ago
    rows.count { |row| (row.rebalanced_at || row.created_at) >= since && row.status == ShortRebalance::STATUS_SUCCESS } > frequent_rebalance_count
  end

  def auto_enabled_outside_tolerance_without_attempt?(snapshot, latest)
    return false unless snapshot&.extended_auto_enabled && snapshot.inside_tolerance == false
    return true unless latest

    age_seconds(latest.rebalanced_at || latest.created_at).to_i > pending_rebalance_stale_after_seconds
  end

  def extended_exposure_unknown?(snapshot)
    snapshot.extended_short_eth.nil? && snapshot.extended_source_status.in?(%w[error not_configured unknown stale])
  end

  def short_positive?(value)
    BigDecimal(value.to_s).positive?
  rescue ArgumentError
    false
  end

  def age_seconds(time)
    return nil unless time

    (now.call - time).round
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def critical_stale_after_seconds
    Integer(env.fetch("POSITION_DASHBOARD_SNAPSHOT_CRITICAL_STALE_AFTER_SECONDS", DEFAULT_CRITICAL_STALE_AFTER_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_CRITICAL_STALE_AFTER_SECONDS
  end

  def pending_rebalance_stale_after_seconds
    Integer(env.fetch("EXTENDED_PENDING_REBALANCE_STALE_AFTER_SECONDS", DEFAULT_PENDING_REBALANCE_STALE_AFTER_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_PENDING_REBALANCE_STALE_AFTER_SECONDS
  end

  def frequent_rebalance_window_hours
    Integer(env.fetch("EXTENDED_FREQUENT_REBALANCE_WINDOW_HOURS", DEFAULT_FREQUENT_REBALANCE_WINDOW_HOURS.to_s))
  rescue ArgumentError
    DEFAULT_FREQUENT_REBALANCE_WINDOW_HOURS
  end

  def frequent_rebalance_count
    Integer(env.fetch("EXTENDED_FREQUENT_REBALANCE_COUNT", DEFAULT_FREQUENT_REBALANCE_COUNT.to_s))
  rescue ArgumentError
    DEFAULT_FREQUENT_REBALANCE_COUNT
  end

  def duplicate_guard_seconds
    Integer(env.fetch("EXTENDED_AUTO_RECENT_REBALANCE_GUARD_SECONDS", DEFAULT_DUPLICATE_GUARD_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_DUPLICATE_GUARD_SECONDS
  end
end
