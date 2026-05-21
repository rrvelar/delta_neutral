class AerodromeRebalanceHistoryStatus
  LIMIT = 100

  def initialize(position:, dashboard_status: {})
    @position = position
    @dashboard_status = dashboard_status || {}
  end

  def report
    hedge = latest_hedge
    records = hedge ? hedge.short_rebalances.order(rebalanced_at: :desc, id: :desc).limit(LIMIT).to_a : []
    {
      database_write: false,
      external_api: false,
      hedge: hedge,
      records: records,
      summary: summary(records),
      blockers: [],
      warnings: []
    }
  end

  private

  def latest_hedge
    Hedge.where(position_id: @position.id).order(id: :desc).first
  end

  def summary(records)
    last = records.first
    {
      records_shown: records.size,
      last_rebalance_at: last&.rebalanced_at,
      last_status: last&.status,
      current_short_eth: @dashboard_status[:current_short_eth],
      current_drift_eth: @dashboard_status[:drift_eth]
    }
  end
end
