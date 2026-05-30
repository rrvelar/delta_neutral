module HedgeVenueAutoAdapters
  class Extended < Base
    def initialize(env: ENV, readiness: nil, **kwargs)
      super(env: env, **kwargs)
      @readiness = readiness || ExtendedAutoReadiness.new(env: env)
    end

    def readiness(position:)
      report = @readiness.report(position: position)
      report.merge(
        active_auto_venue: "extended",
        active_current_short_eth: report[:extended_current_short_eth],
        active_target_short_eth: report[:target_short_eth],
        active_drift_eth: report[:drift_eth],
        active_tolerance_eth: report[:tolerance_eth],
        active_within_tolerance: report[:within_tolerance],
        active_planned_auto_action: report[:planned_auto_action],
        active_auto_enabled: report[:extended_auto_rebalance_enabled],
        active_live_enabled: report[:extended_live_enabled],
        active_auto_ready: report[:continuous_auto_ready],
        active_auto_blockers: report[:blockers],
        active_auto_warnings: report[:warnings],
        orders_submitted: 0,
        signatures_created: 0
      )
    end
  end
end
