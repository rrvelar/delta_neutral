class HedgeFreshTarget
  DEFAULT_MELLOW_STALE_AFTER_SECONDS = 300

  def initialize(position:, env: ENV, exposure_refresher: nil, now: -> { Time.current })
    @position = position
    @env = env
    @exposure_refresher = exposure_refresher || HedgeFreshExposureRefresh.new(position: position)
    @now = now
  end

  def resolve(refresh_if_stale: true)
    return blocked([ "active hedge is required" ]) unless active_hedge?
    return direct_target unless @position.mellow_autopilot?

    refresh = nil
    if refresh_if_stale && exposure_stale?
      refresh = @exposure_refresher.refresh
      @position.reload
    end

    return mellow_target(refresh: refresh) if mellow_exposure_fresh?

    blockers = Array(refresh&.fetch(:blockers, []))
    blockers << "fresh Mellow exposure required before hedge sizing"
    blocked(blockers.uniq, refresh: refresh)
  end

  private

  def direct_target
    return blocked([ "position asset0_amount is unavailable" ]) unless @position.asset0_amount

    ok(
      target_short_eth: @position.asset0_amount * @position.hedge.target,
      target_source: "position_asset0_amount",
      target_fresh: true,
      exposure_source: @position.position_source,
      exposure_refreshed_at: nil,
      exposure_stale: false,
      refresh: nil
    )
  end

  def active_hedge?
    hedge = @position.hedge
    return false unless hedge
    return hedge.active? if hedge.respond_to?(:active?)

    true
  end

  def mellow_target(refresh:)
    metadata = @position.mellow_metadata_hash
    ok(
      target_short_eth: @position.asset0_amount * @position.hedge.target,
      target_source: metadata["exposure_source"].presence || "current_mellow_metadata",
      target_fresh: true,
      exposure_source: metadata["exposure_source"],
      exposure_refreshed_at: metadata["last_current_exposure_at"] || metadata["last_probe_at"],
      exposure_stale: false,
      refresh: refresh
    )
  end

  def mellow_exposure_fresh?
    return false unless @position.asset0_amount.present? && @position.hedge_ready?

    !exposure_stale?
  end

  def exposure_stale?
    return false unless @position.mellow_autopilot?

    timestamp = current_exposure_at
    return true unless timestamp

    timestamp <= stale_after_seconds.seconds.ago
  end

  def current_exposure_at
    raw = @position.mellow_metadata_hash["last_current_exposure_at"].presence || @position.mellow_metadata_hash["last_probe_at"].presence
    Time.zone.parse(raw.to_s) if raw
  rescue ArgumentError
    nil
  end

  def stale_after_seconds
    Integer(@env.fetch("MELLOW_EXPOSURE_STALE_AFTER_SECONDS", DEFAULT_MELLOW_STALE_AFTER_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_MELLOW_STALE_AFTER_SECONDS
  end

  def ok(target_short_eth:, target_source:, target_fresh:, exposure_source:, exposure_refreshed_at:, exposure_stale:, refresh:)
    {
      status: "ok",
      target_short_eth: target_short_eth,
      target_source: target_source,
      target_fresh: target_fresh,
      exposure_source: exposure_source,
      exposure_refreshed_at: exposure_refreshed_at,
      exposure_stale: exposure_stale,
      exposure_refresh: refresh,
      blockers: [],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def blocked(blockers, refresh: nil)
    {
      status: "blocked",
      target_short_eth: nil,
      target_source: nil,
      target_fresh: false,
      exposure_source: @position.mellow_metadata_hash["exposure_source"],
      exposure_refreshed_at: @position.mellow_metadata_hash["last_current_exposure_at"] || @position.mellow_metadata_hash["last_probe_at"],
      exposure_stale: @position.mellow_autopilot? ? exposure_stale? : nil,
      exposure_refresh: refresh,
      blockers: blockers,
      orders_submitted: 0,
      signatures_created: 0
    }
  end
end
