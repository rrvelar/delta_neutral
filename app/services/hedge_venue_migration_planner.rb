class HedgeVenueMigrationPlanner
  Result = Data.define(:status, :blockers, :warnings, :receipt)

  SUPPORTED_DIRECTIONS = [
    [ "ethereal", "extended" ],
    [ "extended", "ethereal" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze
  DEFAULT_SEQUENCE = "target_first".freeze

  def initialize(now: -> { Time.current })
    @now = now
  end

  def plan(position:, from_venue:, to_venue:, mode: "preview", step_size_eth: nil, full_migration_allowed: false, migration_sequence: DEFAULT_SEQUENCE)
    from = HedgeVenues.normalize(from_venue)
    to = HedgeVenues.normalize(to_venue)
    mode = normalized_mode(mode)
    sequence = normalized_sequence(migration_sequence)
    snapshot = position.position_dashboard_snapshot
    blockers = snapshot_blockers(snapshot)
    blockers << "from_venue and to_venue must differ" if from == to
    blockers << "Migration direction #{from} -> #{to} is not supported yet." unless SUPPORTED_DIRECTIONS.include?([ from, to ])

    receipt = base_receipt(position: position, snapshot: snapshot, from_venue: from, to_venue: to, mode: mode, sequence: sequence)
    if blockers.any?
      receipt[:blockers] = blockers.uniq
      return Result.new("blocked", receipt[:blockers], receipt[:warnings], receipt)
    end

    target = snapshot.target_short_eth || BigDecimal("0")
    from_short = venue_short(snapshot, from)
    to_short = venue_short(snapshot, to)
    step_size = decimal_or_nil(step_size_eth)
    full = mode == "full" || full_migration_allowed
    migration_size = planned_size(target: target, from_short: from_short, to_short: to_short, step_size: step_size, full: full)
    blockers << "target short is unavailable in dashboard snapshot" unless target.positive?
    blockers << "source venue #{HedgeVenues.label(from)} has no current short to migrate" unless from_short.positive?
    blockers << "planned migration size is zero" unless migration_size.positive?
    blockers << "full migration requires full_migration_allowed=true" if mode == "full" && !full_migration_allowed

    to_leg = build_to_leg(to, target_short: target, current_short: to_short, size: migration_size, full: full)
    from_leg = build_from_leg(from, current_short: from_short, size: full ? from_short : [ migration_size, from_short ].min, full: full)
    first_leg = sequence == "source_first" ? from_leg : to_leg
    second_leg = sequence == "source_first" ? to_leg : from_leg
    expected_to = to_short + BigDecimal(to_leg.fetch(:size_eth).to_s)
    expected_from = [ from_short - BigDecimal(from_leg.fetch(:size_eth).to_s), BigDecimal("0") ].max
    temporary_combined = if sequence == "source_first"
      snapshot.combined_short_eth.to_d - BigDecimal(from_leg.fetch(:size_eth).to_s)
    else
      snapshot.combined_short_eth.to_d + BigDecimal(to_leg.fetch(:size_eth).to_s)
    end
    temporary_drift = target - temporary_combined
    expected_combined = expected_from + expected_to + other_venue_short(snapshot, from, to)
    expected_drift = target - expected_combined

    warnings = receipt[:warnings]
    warnings << if sequence == "source_first"
      "Source-venue-first sequence temporarily underhedges or leaves the hedge unhedged until target venue open confirms."
    else
      "Target-venue-first sequence temporarily overhedges until source venue reduction confirms."
    end
    warnings << "Stepwise migration transfers only the step size and may leave the combined hedge unchanged unless a separate correction is planned." if mode == "stepwise"
    warnings << "Full migration plans final combined short at target_short_eth instead of preserving current combined exposure." if full
    warnings << "Live migration requires explicit migration gate, exact confirmation, venue live gates, zero open orders, and leg readback confirmation."

    receipt.merge!(
      current_production_venue: position.hedge&.execution_venue,
      production_venue: position.hedge&.execution_venue,
      source_snapshot_id: snapshot.id,
      source_snapshot_refreshed_at: snapshot.refreshed_at&.utc&.iso8601,
      extended_short_before: decimal_string(venue_short(snapshot, "extended")),
      ethereal_short_before: decimal_string(venue_short(snapshot, "ethereal")),
      nado_short_before: decimal_string(venue_short(snapshot, "nado")),
      from_short_before: decimal_string(from_short),
      to_short_before: decimal_string(to_short),
      target_short: decimal_string(target),
      target_short_eth: decimal_string(target),
      tolerance_abs_eth: decimal_string(snapshot.tolerance_abs_eth),
      combined_before: decimal_string(snapshot.combined_short_eth),
      combined_short_before: decimal_string(snapshot.combined_short_eth),
      drift_before: decimal_string(snapshot.drift_eth),
      source_inside_tolerance_before: snapshot.inside_tolerance,
      planned_from_leg: from_leg,
      planned_to_leg: to_leg,
      planned_source_leg: from_leg,
      planned_target_leg: to_leg,
      planned_first_leg: first_leg,
      planned_second_leg: second_leg,
      migration_sequence: sequence,
      max_step_size_eth: decimal_string(step_size),
      temporary_combined_short_eth: decimal_string(temporary_combined),
      temporary_exposure: decimal_string(temporary_combined),
      temporary_combined_after_first_leg: decimal_string(temporary_combined),
      temporary_drift_after_first_leg: decimal_string(temporary_drift),
      temporary_risk_type: sequence == "source_first" ? "underhedge/unhedged" : "overhedge",
      source_first_unhedged_warning: sequence == "source_first",
      expected_from_short_after: decimal_string(expected_from),
      expected_to_short_after: decimal_string(expected_to),
      expected_combined_short_after: decimal_string(expected_combined),
      expected_final_combined: decimal_string(expected_combined),
      expected_final_drift: decimal_string(expected_drift),
      final_expected_inside_tolerance: snapshot.tolerance_abs_eth.present? ? expected_drift.abs <= snapshot.tolerance_abs_eth : nil,
      full_migration_allowed: full_migration_allowed,
      finalize_available: full && expected_from.zero? && snapshot.tolerance_abs_eth.present? && expected_drift.abs <= snapshot.tolerance_abs_eth,
      required_gates: required_gates(from: from, to: to, mode: mode),
      live_gates: required_gates(from: from, to: to, mode: mode),
      blockers: blockers.uniq,
      warnings: warnings.uniq
    )

    Result.new(blockers.any? ? "blocked" : "preview", receipt[:blockers], receipt[:warnings], receipt)
  end

  private

  def normalized_mode(value)
    text = value.to_s
    return "preview" if text.blank?
    return text if text.in?(%w[preview stepwise full])

    "preview"
  end

  def normalized_sequence(value)
    text = value.to_s
    return DEFAULT_SEQUENCE if text.blank?
    return text if text.in?(%w[target_first source_first])

    DEFAULT_SEQUENCE
  end

  def base_receipt(position:, snapshot:, from_venue:, to_venue:, mode:, sequence:)
    {
      action: "hedge_venue_migration_preview",
      position_id: position.id,
      hedge_id: position.hedge&.id,
      from_venue: from_venue,
      to_venue: to_venue,
      mode: mode,
      migration_sequence: sequence,
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
    blockers << "Position dashboard snapshot is stale; refresh read-only data before planning migration." if snapshot.stale_at?(@now.call)
    blockers << "Position dashboard snapshot refresh_status=#{snapshot.refresh_status}; refresh read-only data before planning migration." if snapshot.refresh_status != "ok"
    blockers
  end

  def planned_size(target:, from_short:, to_short:, step_size:, full:)
    desired_add = [ target - to_short, BigDecimal("0") ].max
    return BigDecimal("0") unless desired_add.positive?
    return [ step_size, desired_add, from_short ].min if step_size&.positive? && !full

    desired_add
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
