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

  def plan(position:, from_venue:, to_venue:, mode: "preview", step_size_eth: nil, full_migration_allowed: false, migration_sequence: DEFAULT_SEQUENCE, execution_preflight: nil)
    from = HedgeVenues.normalize(from_venue)
    to = HedgeVenues.normalize(to_venue)
    mode = normalized_mode(mode)
    sequence = normalized_sequence(migration_sequence)
    snapshot = position.position_dashboard_snapshot
    critical_source = execution_preflight_source(execution_preflight)
    blockers = snapshot_blockers(snapshot, execution_preflight: execution_preflight, critical_source: critical_source)
    blockers << "from_venue and to_venue must differ" if from == to
    blockers << "Migration direction #{from} -> #{to} is not supported yet." unless SUPPORTED_DIRECTIONS.include?([ from, to ])

    receipt = base_receipt(position: position, snapshot: snapshot, from_venue: from, to_venue: to, mode: mode, sequence: sequence, critical_source: critical_source)
    if blockers.any?
      receipt[:blockers] = blockers.uniq
      return Result.new("blocked", receipt[:blockers], receipt[:warnings], receipt)
    end

    target = target_short(critical_source || snapshot)
    from_short = venue_short(critical_source || snapshot, from)
    to_short = venue_short(critical_source || snapshot, to)
    combined_short = combined_short(critical_source || snapshot)
    tolerance_abs = tolerance_abs(critical_source || snapshot)
    drift = drift_eth(critical_source || snapshot)
    step_size = decimal_or_nil(step_size_eth)
    full = mode == "full" || full_migration_allowed
    migration_size = planned_size(target: target, from_short: from_short, to_short: to_short, step_size: step_size, full: full)
    blockers << "target short is unavailable in migration planning source" unless target.positive?
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
      combined_short - BigDecimal(from_leg.fetch(:size_eth).to_s)
    else
      combined_short + BigDecimal(to_leg.fetch(:size_eth).to_s)
    end
    temporary_drift = target - temporary_combined
    expected_combined = expected_from + expected_to + other_venue_short(critical_source || snapshot, from, to)
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
      source_snapshot_id: snapshot&.id,
      source_snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      planning_source: critical_source ? "direct_execution_preflight" : "position_dashboard_snapshot",
      execution_preflight_source: critical_source&.fetch(:preflight_source, nil),
      execution_preflight_accepted: critical_source&.fetch(:accepted, nil),
      execution_preflight_warnings: Array(critical_source&.fetch(:warnings, nil)),
      extended_short_before: decimal_string(venue_short(critical_source || snapshot, "extended")),
      ethereal_short_before: decimal_string(venue_short(critical_source || snapshot, "ethereal")),
      nado_short_before: decimal_string(venue_short(critical_source || snapshot, "nado")),
      from_short_before: decimal_string(from_short),
      to_short_before: decimal_string(to_short),
      target_short: decimal_string(target),
      target_short_eth: decimal_string(target),
      tolerance_abs_eth: decimal_string(tolerance_abs),
      combined_before: decimal_string(combined_short),
      combined_short_before: decimal_string(combined_short),
      drift_before: decimal_string(drift),
      source_inside_tolerance_before: inside_tolerance(critical_source || snapshot),
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
      final_expected_inside_tolerance: tolerance_abs.present? ? expected_drift.abs <= tolerance_abs : nil,
      full_migration_allowed: full_migration_allowed,
      finalize_available: full && expected_from.zero? && tolerance_abs.present? && expected_drift.abs <= tolerance_abs,
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

  def base_receipt(position:, snapshot:, from_venue:, to_venue:, mode:, sequence:, critical_source:)
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
      planning_source: critical_source ? "direct_execution_preflight" : "position_dashboard_snapshot",
      blockers: [],
      warnings: [],
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
  end

  def snapshot_blockers(snapshot, execution_preflight:, critical_source:)
    return Array(critical_source[:blockers]).uniq if critical_source
    return Array(execution_preflight[:hard_blockers] || execution_preflight[:blockers]).uniq if execution_preflight.is_a?(Hash) && execution_preflight[:accepted] == false
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

  def execution_preflight_source(report)
    return nil unless report.is_a?(Hash) && report[:accepted] == true

    report
  end

  def target_short(source)
    return BigDecimal(source.dig(:target, :target_short_eth).to_s) if source.is_a?(Hash)

    BigDecimal(source.target_short_eth.to_s)
  rescue ArgumentError, TypeError, NoMethodError
    BigDecimal("0")
  end

  def venue_short(source, venue)
    if source.is_a?(Hash)
      return BigDecimal(source.dig(:venues, venue, :short_eth).to_s)
    end

    BigDecimal(source.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, TypeError, NoMethodError
    BigDecimal("0")
  end

  def combined_short(source)
    return BigDecimal(source[:combined_short_eth].to_s) if source.is_a?(Hash)

    BigDecimal(source.combined_short_eth.to_s)
  rescue ArgumentError, TypeError, NoMethodError
    BigDecimal("0")
  end

  def tolerance_abs(source)
    return decimal_or_nil(source[:tolerance_abs_eth]) if source.is_a?(Hash)

    decimal_or_nil(source.tolerance_abs_eth)
  end

  def drift_eth(source)
    return decimal_or_nil(source[:drift_eth]) if source.is_a?(Hash)

    decimal_or_nil(source.drift_eth)
  end

  def inside_tolerance(source)
    return source[:inside_tolerance] if source.is_a?(Hash)

    source.inside_tolerance
  end

  def other_venue_short(source, from, to)
    (%w[extended ethereal nado] - [ from, to ]).sum { |venue| venue_short(source, venue) }
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
