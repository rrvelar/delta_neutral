module HedgeVenueAutoRebalanceAdapters
  class Nado
    def initialize(env: ENV, readiness: HedgeVenueAutoAdapters::Nado.new(env: env))
      @readiness = readiness
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:, one_shot: true)
      report = @readiness.readiness(position: position)
      blockers = Array(report[:blockers])
      receipt = report.slice(
        :venue, :position_id, :planned_auto_action, :current_short_eth, :target_short_eth,
        :requested_size_eth, :side, :reduce_only, :expected_after_short_eth
      ).merge(
        action: "auto_rebalance_once",
        dry_run: dry_run || !live,
        live: live && !dry_run,
        final_status: "blocked_before_submit",
        blockers: blockers,
        warnings: report[:warnings],
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0
      )
      HedgeVenueAutoRebalanceOnce::Result.new("blocked_before_submit", blockers, report[:warnings], receipt)
    end
  end
end
