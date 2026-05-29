class MellowExposureRefreshJob < ApplicationJob
  queue_as :default

  def perform(position_id = nil)
    unless enabled?
      Rails.logger.info("[MellowExposureRefreshJob] status=disabled orders_submitted=0 signatures_created=0")
      return { status: "disabled", orders_submitted: 0, signatures_created: 0 }
    end

    positions = positions_scope(position_id).to_a
    results = positions.map { |position| refresh_position(position) }
    { status: "complete", positions: results, orders_submitted: 0, signatures_created: 0 }
  end

  private

  def enabled?
    ENV.fetch("MELLOW_EXPOSURE_AUTO_REFRESH_ENABLED", "true").to_s.downcase != "false"
  end

  def positions_scope(position_id)
    scope = Position.includes(:hedge, :dex, :wallet)
      .active
      .joins(:hedge)
      .where(source: Position::SOURCE_MELLOW_AUTOPILOT, hedges: { active: true })
    position_id ? scope.where(id: position_id) : scope
  end

  def refresh_position(position)
    old_asset0 = position.asset0_amount&.to_s("F")
    old_asset1 = position.asset1_amount&.to_s("F")
    result = MellowAutopilotPositionSync.new(position: position).sync
    position.reload
    DashboardSnapshotJob.perform_later(position.id, force: true) if result.fetch(:status) == "synced"
    payload = {
      position_id: position.id,
      old_asset0: old_asset0,
      old_asset1: old_asset1,
      new_asset0: position.asset0_amount&.to_s("F"),
      new_asset1: position.asset1_amount&.to_s("F"),
      exposure_source: position.mellow_metadata_hash["exposure_source"],
      successful_method: position.mellow_metadata_hash["successful_method"],
      status: result.fetch(:status),
      blockers: result.fetch(:blockers, []),
      orders_submitted: 0,
      signatures_created: 0
    }
    Rails.logger.info("[MellowExposureRefreshJob] #{payload.to_json}")
    payload
  rescue => e
    payload = {
      position_id: position.id,
      status: "error",
      blockers: [ "#{e.class}: #{e.message}" ],
      orders_submitted: 0,
      signatures_created: 0
    }
    Rails.logger.warn("[MellowExposureRefreshJob] #{payload.to_json}")
    payload
  end
end
