class MigrationRouteCompletionReconciler
  FLAT_TOLERANCE_ETH = BigDecimal("0.001")
  COMPLETE_STATUSES = %w[
    ALREADY_MIGRATED_CONFIRMED_BY_READBACK
    STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE
  ].freeze
  FINALIZED_STATUS = "MIGRATION_FINALIZED_BY_READBACK".freeze

  Result = Data.define(
    :status,
    :route_complete_by_readback,
    :source_flat,
    :target_matches_expected,
    :combined_inside_tolerance,
    :open_orders_zero,
    :finalize_safe,
    :production_venue_finalized,
    :next_action,
    :blockers,
    :warnings,
    :receipt
  )

  def initialize(position:, from:, to:, now: -> { Time.current }, receipt_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR)
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @now = now
    @receipt_dir = receipt_dir
  end

  def report
    snapshot = position.position_dashboard_snapshot
    blockers = snapshot_blockers(snapshot)
    receipt = base_receipt(snapshot: snapshot, blockers: blockers)
    return result("READBACK_UNAVAILABLE", receipt, blockers: blockers) if blockers.any?

    source_flat = venue_short(snapshot, from) <= FLAT_TOLERANCE_ETH
    target_matches = matches_expected?(venue_short(snapshot, to), snapshot.target_short_eth, snapshot.tolerance_abs_eth)
    combined_inside = snapshot.inside_tolerance == true
    open_orders_zero = open_orders_zero?(snapshot)
    complete = source_flat && target_matches && combined_inside && open_orders_zero
    finalized = HedgeVenues.normalize(position.hedge&.execution_venue) == to
    finalize_safe = complete && !finalized
    status = if complete && finalized
      "ALREADY_MIGRATED_CONFIRMED_BY_READBACK"
    elsif finalize_safe
      "SOURCE_CLOSED_TARGET_CONFIRMED_NOT_FINALIZED"
    else
      "NOT_COMPLETE_BY_READBACK"
    end

    complete_blockers = []
    complete_blockers << "#{HedgeVenues.label(from)} source venue is not flat" unless source_flat
    complete_blockers << "#{HedgeVenues.label(to)} target venue does not hold expected short" unless target_matches
    complete_blockers << "combined hedge is outside tolerance" unless combined_inside
    complete_blockers << "open orders must be zero after migration" unless open_orders_zero

    receipt.merge!(
      final_status: status,
      source_flat_after: source_flat,
      source_flat: source_flat,
      target_holds_expected_short: target_matches,
      target_holds_hedge_confirmed: target_matches,
      final_inside_tolerance: combined_inside,
      open_orders_after: open_orders_zero ? 0 : open_orders_count(snapshot),
      open_orders_clear_after: open_orders_zero,
      production_venue_finalized: finalized,
      final_venue: finalized ? to : nil,
      finalize_safe: finalize_safe,
      route_complete_by_readback: complete,
      blockers: complete ? [] : complete_blockers,
      warnings: warnings(snapshot)
    )
    result(status, receipt, blockers: receipt[:blockers])
  end

  def write_ready_receipt!(status: "ALREADY_MIGRATED_CONFIRMED_BY_READBACK")
    current = report
    return current unless current.route_complete_by_readback && current.production_venue_finalized

    receipt = current.receipt.merge(
      action: "manual_live_canary",
      final_status: status,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      manual_action_required: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )
    write_receipt(receipt)
    result(status, receipt, blockers: [])
  end

  def finalize!
    current = report
    return current unless current.finalize_safe || current.production_venue_finalized

    position.hedge&.update!(execution_venue: to) unless current.production_venue_finalized
    ActiveVenueAutoPolicy.new(position: position).enable_venue!(
      venue: to,
      reason: "migration finalization moved active venue auto"
    )
    receipt = current.receipt.merge(
      action: "manual_live_canary",
      final_status: current.production_venue_finalized ? "ALREADY_FINALIZED" : FINALIZED_STATUS,
      final_venue: to,
      production_venue: to,
      production_venue_finalized: true,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      manual_action_required: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )
    write_receipt(receipt)
    result(receipt[:final_status], receipt, blockers: [])
  end

  private

  attr_reader :position, :from, :to, :now, :receipt_dir

  def result(status, receipt, blockers:)
    Result.new(
      status,
      receipt[:route_complete_by_readback] == true,
      receipt[:source_flat_after] == true,
      receipt[:target_holds_expected_short] == true,
      receipt[:final_inside_tolerance] == true,
      receipt[:open_orders_clear_after] == true,
      receipt[:finalize_safe] == true,
      receipt[:production_venue_finalized] == true,
      next_action_for(status, receipt),
      Array(blockers),
      Array(receipt[:warnings]),
      receipt
    )
  end

  def next_action_for(status, receipt)
    return "prepare_next_route" if COMPLETE_STATUSES.include?(status) || status == FINALIZED_STATUS || status == "ALREADY_FINALIZED"
    return "finalize_migration" if receipt[:finalize_safe]

    "run_live_canary"
  end

  def base_receipt(snapshot:, blockers:)
    {
      action: "route_completion_reconciliation",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      current_production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      target_short_eth: decimal_string(snapshot&.target_short_eth),
      tolerance_abs_eth: decimal_string(snapshot&.tolerance_abs_eth),
      combined_short_eth: decimal_string(snapshot&.combined_short_eth),
      extended_short_eth: decimal_string(snapshot&.extended_short_eth),
      ethereal_short_eth: decimal_string(snapshot&.ethereal_short_eth),
      nado_short_eth: decimal_string(snapshot&.nado_short_eth),
      inside_tolerance: snapshot&.inside_tolerance,
      readback_snapshot_id: snapshot&.id,
      readback_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      blockers: blockers,
      warnings: [],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0,
      would_execute_live: false
    }
  end

  def snapshot_blockers(snapshot)
    return [ "Position dashboard snapshot is missing; refresh read-only data before reconciling migration." ] unless snapshot

    blockers = []
    blockers << "Position dashboard snapshot refresh_status=#{snapshot.refresh_status}; refresh read-only data before reconciling migration." unless snapshot.refresh_status == "ok"
    blockers << "target short is unavailable in dashboard snapshot" unless decimal(snapshot.target_short_eth).positive?
    blockers << "combined short is unavailable in dashboard snapshot" if snapshot.combined_short_eth.nil?
    blockers << "inside tolerance readback is unavailable" if snapshot.inside_tolerance.nil?
    blockers
  end

  def matches_expected?(actual, expected, tolerance)
    expected_value = decimal(expected)
    return false unless expected_value.positive?

    (actual - expected_value).abs <= [ decimal(tolerance), FLAT_TOLERANCE_ETH ].max
  end

  def open_orders_zero?(snapshot)
    open_orders_count(snapshot).to_i.zero?
  end

  def open_orders_count(snapshot)
    return snapshot.open_orders_count_extended if [ from, to ].include?("extended")

    0
  end

  def warnings(snapshot)
    return [] if [ from, to ].include?("extended")

    [ "Non-Extended open orders are treated as clear by the latest dashboard readback context." ]
  end

  def venue_short(snapshot, venue)
    decimal(snapshot.public_send("#{venue}_short_eth"))
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def write_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end
end
