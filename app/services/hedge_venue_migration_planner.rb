class HedgeVenueMigrationPlanner
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  SUPPORTED_DIRECTIONS = [
    [ "ethereal", "extended" ],
    [ "extended", "ethereal" ]
  ].freeze
  DEFAULT_SEQUENCE = "target_first".freeze

  def initialize(now: -> { Time.current })
    @now = now
  end

  def plan(position:, from_venue:, to_venue:, mode: "preview", step_size_eth: nil, full_migration_allowed: false)
    from = HedgeVenues.normalize(from_venue)
    to = HedgeVenues.normalize(to_venue)
    snapshot = position.position_dashboard_snapshot
    blockers = snapshot_blockers(snapshot)
    blockers << "from_venue and to_venue must differ" if from == to
    blockers << "Nado migration readiness is not implemented." if [ from, to ].include?("nado")
    blockers << "Migration direction #{from} -> #{to} is not supported yet." unless SUPPORTED_DIRECTIONS.include?([ from, to ])

    receipt = base_receipt(position: position, snapshot: snapshot, from_venue: from, to_venue: to, mode: mode)
    if blockers.any?
      receipt[:blockers] = blockers.uniq
      return Result.new("blocked", receipt[:blockers], receipt[:warnings], receipt)
    end

    target = snapshot.target_short_eth || BigDecimal("0")
    from_short = venue_short(snapshot, from)
    to_short = venue_short(snapshot, to)
    step_size = decimal_or_nil(step_size_eth)
    full = mode.to_s == "full" || full_migration_allowed
    migration_size = planned_size(target: target, from_short: from_short, to_short: to_short, step_size: step_size, full: full)
    blockers << "target short is unavailable in dashboard snapshot" unless target.positive?
    blockers << "source venue #{HedgeVenues.label(from)} has no current short to migrate" unless from_short.positive?
    blockers << "planned migration size is zero" unless migration_size.positive?

    to_leg = build_to_leg(to, target_short: target, current_short: to_short, size: migration_size, full: full)
    from_leg = build_from_leg(from, current_short: from_short, size: [ migration_size, from_short ].min, full: full)
    expected_to = to_short + BigDecimal(to_leg.fetch(:size_eth).to_s)
    expected_from = [ from_short - BigDecimal(from_leg.fetch(:size_eth).to_s), BigDecimal("0") ].max
    temporary_combined = snapshot.combined_short_eth.to_d + BigDecimal(to_leg.fetch(:size_eth).to_s)
    expected_combined = expected_from + expected_to + other_venue_short(snapshot, from, to)

    warnings = receipt[:warnings]
    warnings << "Target-venue-first sequence temporarily overhedges until source venue reduction confirms."
    warnings << "Extended -> Ethereal is dry-run/preflight only in the generic dashboard migration path." if from == "extended" && to == "ethereal"
    warnings << "Full migration requires an explicit live gate and confirmation; production venue is not switched by this planner." if full

    receipt.merge!(
      current_production_venue: position.hedge&.execution_venue,
      from_short_before: decimal_string(from_short),
      to_short_before: decimal_string(to_short),
      target_short_eth: decimal_string(target),
      combined_short_before: decimal_string(snapshot.combined_short_eth),
      planned_from_leg: from_leg,
      planned_to_leg: to_leg,
      migration_sequence: DEFAULT_SEQUENCE,
      temporary_combined_short_eth: decimal_string(temporary_combined),
      expected_from_short_after: decimal_string(expected_from),
      expected_to_short_after: decimal_string(expected_to),
      expected_combined_short_after: decimal_string(expected_combined),
      required_gates: required_gates(from: from, to: to, mode: mode),
      blockers: blockers.uniq,
      warnings: warnings.uniq
    )

    Result.new(blockers.any? ? "blocked" : "preview", receipt[:blockers], receipt[:warnings], receipt)
  end

  private

  def base_receipt(position:, snapshot:, from_venue:, to_venue:, mode:)
    {
      action: "hedge_venue_migration_preview",
      position_id: position.id,
      hedge_id: position.hedge&.id,
      from_venue: from_venue,
      to_venue: to_venue,
      mode: mode,
      dry_run: true,
      timestamp: @now.call.utc.iso8601,
      snapshot_id: snapshot&.id,
      snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      blockers: [],
      warnings: [],
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
  end

  def snapshot_blockers(snapshot)
    return [ "Position dashboard snapshot is missing; refresh read-only data before planning migration." ] unless snapshot

    blockers = []
    blockers << "Position dashboard snapshot is stale; refresh read-only data before planning migration." if snapshot.stale_now?
    blockers << "Position dashboard snapshot refresh_status=#{snapshot.refresh_status}; refresh read-only data before planning migration." if snapshot.refresh_status != "ok"
    blockers
  end

  def planned_size(target:, from_short:, to_short:, step_size:, full:)
    desired_add = [ target - to_short, BigDecimal("0") ].max
    return BigDecimal("0") unless desired_add.positive?
    return [ step_size, desired_add, from_short ].min if step_size&.positive? && !full

    [ desired_add, from_short ].min
  end

  def build_to_leg(venue, target_short:, current_short:, size:, full:)
    {
      venue: venue,
      action: current_short.positive? ? "increase_short" : "open_short",
      side: "sell",
      reduce_only: false,
      size_eth: decimal_string(size),
      expected_after_short_eth: decimal_string(full ? target_short : current_short + size),
      confirmation_required: true
    }
  end

  def build_from_leg(venue, current_short:, size:, full:)
    {
      venue: venue,
      action: full ? "close_short" : "decrease_short",
      side: "buy",
      reduce_only: true,
      size_eth: decimal_string(size),
      expected_after_short_eth: decimal_string([ current_short - size, BigDecimal("0") ].max),
      confirmation_required: true
    }
  end

  def venue_short(snapshot, venue)
    BigDecimal(snapshot.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, NoMethodError
    BigDecimal("0")
  end

  def other_venue_short(snapshot, from, to)
    (%w[extended ethereal nado] - [ from, to ]).sum { |venue| venue_short(snapshot, venue) }
  end

  def required_gates(from:, to:, mode:)
    [
      "MIGRATION_LIVE_ENABLED=true for live execution",
      "exact dashboard migration confirmation phrase",
      "#{HedgeVenues.label(from)} live enabled",
      "#{HedgeVenues.label(to)} live enabled",
      "source and target auto disabled during migration",
      "open_orders_count=0 on both venues",
      "#{HedgeVenues.label(to)} readiness passes",
      "readback confirmation after each leg",
      ("MIGRATION_FULL_ALLOWED=true for full migration" if mode.to_s == "full")
    ].compact
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def decimal_string(value)
    value&.to_s("F")
  end
end
