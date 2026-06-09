class HedgeVenueAutoRebalanceOnce
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, adapters: nil)
    @env = env
    @adapters = adapters || {
      "extended" => HedgeVenueAutoRebalanceAdapters::Extended.new(env: env),
      "ethereal" => HedgeVenueAutoRebalanceAdapters::Ethereal.new(env: env),
      "nado" => HedgeVenueAutoRebalanceAdapters::Nado.new(env: env)
    }
  end

  def run(position:, dry_run: true, live: false, confirmation: nil, max_slippage: "0.01", one_shot: true, **options)
    venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    adapter = @adapters[venue]
    return blocked(position: position, venue: venue, blocker: "Unsupported hedge execution_venue #{venue.inspect}") unless adapter

    adapter.run(position: position, dry_run: dry_run, live: live, confirmation: confirmation, max_slippage: max_slippage, one_shot: one_shot, **options)
  end

  private

  def blocked(position:, venue:, blocker:)
    Result.new(
      "blocked_before_submit",
      [ blocker ],
      [],
      {
        venue: venue,
        action: "auto_rebalance_once",
        position_id: position.id,
        final_status: "blocked_before_submit",
        blockers: [ blocker ],
        orders_submitted: 0,
        signatures_created: 0
      }
    )
  end
end
