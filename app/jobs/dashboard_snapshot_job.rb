class DashboardSnapshotJob < ApplicationJob
  queue_as :default

  DEFAULT_MIN_REFRESH_INTERVAL_SECONDS = 30

  def perform(position_id = nil, force: false)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    positions = dashboard_positions(position_id)
    Rails.logger.info("[DashboardSnapshotJob] starting position_id=#{position_id || 'all active Aerodrome'} count=#{positions.size} force=#{force}")
    statuses = []

    positions.each do |position|
      statuses << refresh_position(position, force: force)
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    Rails.logger.info("[DashboardSnapshotJob] complete position_id=#{position_id || 'all active Aerodrome'} duration_ms=#{duration_ms} statuses=#{statuses.inspect}")
  end

  private

  def dashboard_positions(position_id)
    scope = Position.includes(
      :dex,
      :hedge,
      :position_dashboard_snapshot,
      :position_rewards_fees_snapshot,
      :position_hedge_accounting_snapshot,
      wallet: :network
    )
    return scope.where(id: position_id).to_a if position_id

    scope
      .active
      .left_outer_joins(:dex)
      .where(
        "dexes.name = :aerodrome OR positions.source IN (:direct_sources)",
        aerodrome: "aerodrome_slipstream",
        direct_sources: [ Position::SOURCE_AERODROME_DIRECT ]
      )
      .to_a
  end

  def refresh_position(position, force:)
    lock_key = "dashboard_snapshot:position:#{position.id}"
    did_run = false
    status = nil
    JobConcurrencyGuard.with_lock(lock_key) do
      did_run = true
      if !force && fresh_enough?(position)
        status = skipped_status(position, "freshness")
        Rails.logger.info("[DashboardSnapshotJob] skipped position_id=#{position.id} reason=freshness refreshed_at=#{position.position_dashboard_snapshot&.refreshed_at}")
        next
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      exposure = DashboardSnapshotRefresh.new(position: position, force: force).refresh
      rewards = RewardsFeesSnapshotRefresh.new(position: position).refresh
      accounting = HedgeAccountingSnapshotRefresh.new(position: position).refresh
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
      status = {
        position_id: position.id,
        status: "refreshed",
        position: exposure.refresh_status,
        rewards_fees: rewards.refresh_status,
        hedge_accounting: accounting.refresh_status,
        duration_ms: duration_ms,
        orders_submitted: exposure.respond_to?(:orders_submitted) ? exposure.orders_submitted : 0,
        signatures_created: exposure.respond_to?(:signatures_created) ? exposure.signatures_created : 0
      }
      Rails.logger.info("[DashboardSnapshotJob] refreshed position_id=#{position.id} duration_ms=#{duration_ms} statuses=#{status.slice(:position, :rewards_fees, :hedge_accounting).inspect}")
    end

    unless did_run
      Rails.logger.info("[DashboardSnapshotJob] skipped position_id=#{position.id} reason=lock")
      return skipped_status(position, "lock")
    end

    status
  rescue => e
    Rails.logger.warn("[DashboardSnapshotJob] position_id=#{position.id} failed: #{e.class}: #{e.message}")
    {
      position_id: position.id,
      status: "error",
      error: "#{e.class}: #{e.message}"
    }
  end

  def fresh_enough?(position)
    refreshed_at = position.position_dashboard_snapshot&.refreshed_at
    refreshed_at && refreshed_at > min_refresh_interval_seconds.seconds.ago
  end

  def min_refresh_interval_seconds
    Integer(ENV.fetch("DASHBOARD_SNAPSHOT_MIN_REFRESH_INTERVAL_SECONDS", DEFAULT_MIN_REFRESH_INTERVAL_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_MIN_REFRESH_INTERVAL_SECONDS
  end

  def skipped_status(position, reason)
    {
      position_id: position.id,
      status: "skipped",
      reason: reason,
      orders_submitted: 0,
      signatures_created: 0
    }
  end
end
