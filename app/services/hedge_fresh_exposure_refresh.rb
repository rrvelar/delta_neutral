class HedgeFreshExposureRefresh
  def initialize(position:, mellow_sync_factory: nil, direct_sync: nil)
    @position = position
    @mellow_sync_factory = mellow_sync_factory || ->(pos) { MellowAutopilotPositionSync.new(position: pos) }
    @direct_sync = direct_sync || ->(position_id) { PositionSyncJob.perform_now(position_id) }
  end

  def refresh
    before = exposure_snapshot
    result = if @position.mellow_autopilot?
      @mellow_sync_factory.call(@position).sync
    else
      @direct_sync.call(@position.id)
      { status: "synced", blockers: [] }
    end
    @position.reload
    after = exposure_snapshot
    blockers = Array(result.respond_to?(:fetch) ? result.fetch(:blockers, []) : [])
    blockers << "fresh Mellow exposure required before hedge sizing" if @position.mellow_autopilot? && result.respond_to?(:fetch) && result.fetch(:status, nil).to_s == "blocked"
    blockers << "fresh WETH exposure required before hedge sizing" unless @position.asset0_amount.present?

    {
      status: blockers.empty? ? "synced" : "blocked",
      before: before,
      after: after,
      blockers: blockers.uniq,
      result: result
    }
  rescue => e
    {
      status: "blocked",
      before: exposure_snapshot,
      after: exposure_snapshot,
      blockers: [ "fresh Mellow exposure required before hedge sizing", "exposure refresh failed: #{e.class}: #{e.message}" ],
      result: nil
    }
  end

  private

  def exposure_snapshot
    {
      asset0_amount: @position.asset0_amount&.to_s("F"),
      asset1_amount: @position.asset1_amount&.to_s("F"),
      asset0_price_usd: @position.asset0_price_usd&.to_s("F"),
      asset1_price_usd: @position.asset1_price_usd&.to_s("F"),
      hedge_ready: @position.hedge_ready?,
      mellow_last_probe_at: @position.mellow_metadata_hash["last_probe_at"]
    }
  end
end
