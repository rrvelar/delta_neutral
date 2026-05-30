class HedgeVenueAutoReadiness
  def initialize(env: ENV, adapters: nil)
    @env = env
    @adapters = adapters || {
      "extended" => HedgeVenueAutoAdapters::Extended.new(env: env),
      "ethereal" => HedgeVenueAutoAdapters::Ethereal.new(env: env),
      "nado" => HedgeVenueAutoAdapters::Nado.new(env: env)
    }
  end

  def report(position:)
    venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    adapter = @adapters[venue]
    return unknown_venue(position, venue) unless adapter

    adapter.readiness(position: position)
  end

  private

  def unknown_venue(position, venue)
    {
      venue: venue,
      action: "auto_readiness",
      position_id: position.id,
      execution_venue: venue,
      active_auto_venue: venue,
      continuous_auto_ready: false,
      active_auto_ready: false,
      blockers: [ "Unsupported hedge execution_venue #{venue.inspect}" ],
      warnings: [],
      orders_submitted: 0,
      signatures_created: 0
    }
  end
end
