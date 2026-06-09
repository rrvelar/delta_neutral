class ActiveVenueRebalanceCapabilityMatrix
  VENUES = ActiveVenueOneShotRebalance::VENUES
  ACTIVE_VENUE_REBALANCE_MAX_SIZE_DEFAULT = ActiveVenueOneShotRebalance::ACTIVE_VENUE_REBALANCE_MAX_SIZE_DEFAULT

  def initialize(position:, env: ENV, required_max_drift_eth: nil, now: -> { Time.current }, venue_overrides: {})
    @position = position
    @env = env
    @required_max_drift_eth = decimal_or_nil(required_max_drift_eth)
    @now = now
    @venue_overrides = venue_overrides.transform_keys { |key| HedgeVenues.normalize(key) }
  end

  def report
    reports = VENUES.map { |venue| venue_report(venue) }
    blockers = reports.flat_map { |row| Array(row[:blockers]) }.uniq
    {
      action: "active_venue_rebalance_capabilities",
      checked_at: now.call.utc.iso8601,
      position_id: position.id,
      all_supported: blockers.empty?,
      venues: reports,
      blockers: blockers,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def blockers
    report.fetch(:blockers)
  end

  private

  attr_reader :position, :env, :required_max_drift_eth, :now, :venue_overrides

  def venue_report(venue)
    base = {
      venue: venue,
      active_venue_rebalance_supported: true,
      increase_short_supported: true,
      decrease_short_supported: true,
      large_drift_supported: true,
      pending_readback_recheck_supported: true,
      scoped_live_gates_supported: true,
      dry_run_supported: true,
      live_mock_verified: true,
      max_rebalance_size_eth: max_size_for(venue).to_s("F"),
      blockers: []
    }
    merged = base.merge(venue_overrides.fetch(venue, {}))
    merged[:blockers] = capability_blockers(venue: venue, report: merged)
    merged
  end

  def capability_blockers(venue:, report:)
    blockers = Array(report[:blockers])
    blockers << "#{HedgeVenues.label(venue)} active rebalance is not supported" unless report[:active_venue_rebalance_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance cannot increase short" unless report[:increase_short_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance cannot decrease short" unless report[:decrease_short_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance does not support pending readback recheck" unless report[:pending_readback_recheck_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance does not support scoped live gates" unless report[:scoped_live_gates_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance dry-run is not supported" unless report[:dry_run_supported]
    blockers << "#{HedgeVenues.label(venue)} active rebalance live mock is not verified" unless report[:live_mock_verified]
    blockers.concat(large_drift_blockers(venue: venue, report: report))
    blockers.uniq
  end

  def large_drift_blockers(venue:, report:)
    return [] if required_max_drift_eth.nil?
    return [] if report[:large_drift_supported] && decimal(report[:max_rebalance_size_eth]) >= required_max_drift_eth

    [
      "#{HedgeVenues.label(venue)} active rebalance cannot handle drift #{required_max_drift_eth.to_s('F')} ETH; max active rebalance size is #{decimal(report[:max_rebalance_size_eth]).to_s('F')} ETH."
    ]
  end

  def max_size_for(venue)
    case venue
    when "extended"
      decimal(env["EXTENDED_MIGRATION_REBALANCE_MAX_SIZE_ETH"].presence || shared_max_size)
    when "ethereal"
      decimal(env["AERODROME_ETHEREAL_MIGRATION_REBALANCE_MAX_SIZE_ETH"].presence || shared_max_size)
    when "nado"
      decimal(env["AERODROME_NADO_MIGRATION_REBALANCE_MAX_SIZE_ETH"].presence || shared_max_size)
    else
      BigDecimal("0")
    end
  end

  def shared_max_size
    env["ACTIVE_VENUE_REBALANCE_MAX_SIZE_ETH"].presence || ACTIVE_VENUE_REBALANCE_MAX_SIZE_DEFAULT
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    decimal(value)
  end
end
