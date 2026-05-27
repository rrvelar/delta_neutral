class DashboardSnapshotJob < ApplicationJob
  queue_as :default

  def perform(position_id = nil)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    positions = dashboard_positions(position_id)
    Rails.logger.info("[DashboardSnapshotJob] starting position_id=#{position_id || 'all active Aerodrome'} count=#{positions.size}")
    statuses = []

    positions.each do |position|
      statuses << refresh_position(position)
    end

    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    Rails.logger.info("[DashboardSnapshotJob] complete position_id=#{position_id || 'all active Aerodrome'} duration_ms=#{duration_ms} statuses=#{statuses.inspect}")
  end

  private

  def dashboard_positions(position_id)
    scope = Position.includes(:dex, :hedge, wallet: :network)
    return scope.where(id: position_id).to_a if position_id

    scope.active.joins(:dex).where(dexes: { name: "aerodrome_slipstream" }).to_a
  end

  def refresh_position(position)
    exposure = DashboardSnapshotRefresh.new(position: position).refresh
    rewards = RewardsFeesSnapshotRefresh.new(position: position).refresh
    accounting = HedgeAccountingSnapshotRefresh.new(position: position).refresh
    {
      position_id: position.id,
      position: exposure.refresh_status,
      rewards_fees: rewards.refresh_status,
      hedge_accounting: accounting.refresh_status,
      orders_submitted: exposure.respond_to?(:orders_submitted) ? exposure.orders_submitted : 0,
      signatures_created: exposure.respond_to?(:signatures_created) ? exposure.signatures_created : 0
    }
  rescue => e
    Rails.logger.warn("[DashboardSnapshotJob] position_id=#{position.id} failed: #{e.class}: #{e.message}")
    { position_id: position.id, status: "error", error: "#{e.class}: #{e.message}" }
  end
end
