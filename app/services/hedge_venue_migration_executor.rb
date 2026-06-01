class HedgeVenueMigrationExecutor
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_MIGRATES_HEDGE_BETWEEN_VENUES".freeze

  def initialize(env: ENV, planner: HedgeVenueMigrationPlanner.new, leg_runner: nil, now: -> { Time.current }, snapshot_refresher: nil, receipt_writer: nil)
    @env = env
    @planner = planner
    @leg_runner = leg_runner || DefaultLegRunner.new(env: env)
    @now = now
    @snapshot_refresher = snapshot_refresher || method(:refresh_dashboard_snapshot)
    @receipt_writer = receipt_writer || HedgeVenueMigrationReceiptWriter.new(now: now)
  end

  def run(position:, from_venue:, to_venue:, mode: "preview", dry_run: true, confirmation: nil, step_size_eth: nil, full_migration_allowed: false, migration_sequence: HedgeVenueMigrationPlanner::DEFAULT_SEQUENCE)
    refreshed_snapshot = nil
    if !dry_run && live_preflight_gate_open?(confirmation)
      refreshed_snapshot = @snapshot_refresher.call(position)
      position.reload
    end

    plan = @planner.plan(
      position: position,
      from_venue: from_venue,
      to_venue: to_venue,
      mode: mode,
      step_size_eth: step_size_eth,
      full_migration_allowed: full_migration_allowed,
      migration_sequence: migration_sequence
    )
    receipt = plan.receipt.merge(
      action: "hedge_venue_migration",
      dry_run: dry_run,
      live: !dry_run,
      source_snapshot_id: refreshed_snapshot&.id || plan.receipt[:source_snapshot_id],
      source_snapshot_refreshed_at: refreshed_snapshot&.refreshed_at&.utc&.iso8601 || plan.receipt[:source_snapshot_refreshed_at],
      confirmation_type: confirmation == CONFIRMATION ? "dashboard_migration_confirmation" : (confirmation.present? ? "invalid_confirmation" : "missing_confirmation"),
      orders_placed: 0,
      signatures_created: 0,
      exchange_order_ids: [],
      leg_readbacks: [],
      lifecycle_state: dry_run ? "READY_FOR_TARGET_FIRST" : "PRECHECK_BLOCKED",
      manual_action_required: true,
      final_status: dry_run ? plan.status : "blocked_before_submit"
    )
    blockers = Array(plan.blockers) + live_blockers(position: position, receipt: receipt, dry_run: dry_run, confirmation: confirmation)
    if dry_run || blockers.any?
      receipt[:blockers] = blockers.uniq
      receipt[:final_status] = dry_run ? "dry_run" : "blocked_before_submit"
      receipt[:manual_action_required] = !dry_run
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    first_planned_leg = receipt.fetch(:planned_first_leg)
    second_planned_leg = receipt.fetch(:planned_second_leg)
    receipt[:lifecycle_state] = "READY_FOR_TARGET_FIRST"
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    receipt[:target_leg_status] = leg_lifecycle_status(leg: first_leg, planned_leg: first_planned_leg, role: "target")
    receipt[:target_readback_attempts] = first_leg[:readback] if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:target_late_reconciliation] = late_reconciled?(first_leg)
    unless leg_confirmed?(first_leg)
      receipt[:orders_placed] = leg_order_count(first_leg)
      receipt[:orders_submitted] = receipt[:orders_placed]
      receipt[:signatures_created] = leg_signature_count(first_leg)
      receipt[:exchange_order_ids] = [ first_leg[:exchange_order_id] ].compact
      receipt[:submitted] = receipt[:orders_placed].positive?
      receipt[:would_execute_live] = receipt[:submitted]
      receipt[:lifecycle_state] = receipt[:orders_placed].positive? ? "TARGET_SUBMITTED_PENDING_READBACK" : "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:final_status] = receipt[:orders_placed].positive? ? "TARGET_SUBMITTED_BUT_NOT_CONFIRMED" : "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:blockers] = Array(first_leg[:blockers]).presence || [ "First migration leg was not confirmed; second leg was not submitted." ]
      receipt[:manual_action_required] = true
      receipt[:recovery_command] = recovery_command(receipt) if first_planned_leg.fetch(:venue) == receipt[:to_venue] && receipt[:orders_placed].positive?
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    receipt[:lifecycle_state] = late_reconciled?(first_leg) ? "TARGET_CONFIRMED_LATE_BY_RECONCILIATION" : "TARGET_SUBMITTED_AND_CONFIRMED"
    second_leg = @leg_runner.call(second_planned_leg, context: leg_context(position, confirmation, receipt))
    receipt[:second_leg_execution] = sanitize_sensitive(second_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(second_leg) if second_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(second_leg) if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << second_leg[:readback] if second_leg[:readback]
    receipt[:orders_placed] = leg_order_count(first_leg) + leg_order_count(second_leg)
    receipt[:orders_submitted] = receipt[:orders_placed]
    receipt[:signatures_created] = leg_signature_count(first_leg) + leg_signature_count(second_leg)
    receipt[:exchange_order_ids] = [ first_leg[:exchange_order_id], second_leg[:exchange_order_id] ].compact
    receipt[:submitted] = receipt[:orders_placed].positive?
    receipt[:would_execute_live] = receipt[:submitted]
    receipt[:source_leg_status] = leg_lifecycle_status(leg: second_leg, planned_leg: second_planned_leg, role: "source")
    receipt[:source_readback_attempts] = second_leg[:readback] if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:source_late_reconciliation] = late_reconciled?(second_leg)
    if leg_confirmed?(second_leg)
      final = final_readback_status(receipt: receipt, first_leg: first_leg, second_leg: second_leg)
      receipt.merge!(final)
      finalize_production_venue(position, receipt) if receipt[:finalize_available] && receipt[:final_status] == "success"
      receipt[:lifecycle_state] = receipt[:production_venue_finalized] ? "MIGRATION_FINALIZED" : "SOURCE_CLOSE_CONFIRMED"
    else
      receipt[:lifecycle_state] = receipt[:orders_placed].positive? ? "SOURCE_CLOSE_PENDING_READBACK" : "RECOVERY_REQUIRED"
      receipt[:final_status] = "partial_migration_manual_action_required"
      receipt[:manual_action_required] = true
      receipt[:blockers] = Array(second_leg[:blockers]).presence || [ "Second migration leg was not confirmed after first leg succeeded." ]
      receipt[:recovery_command] = recovery_command(receipt) if receipt[:migration_sequence] == "target_first"
      if receipt[:migration_sequence] == "source_first"
        receipt[:warnings] = (Array(receipt[:warnings]) + [ "Source close confirmed but target open did not; hedge may be temporarily unhedged. Manual action required." ]).uniq
      end
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  def run_precomputed_plan(position:, plan:, confirmation:)
    receipt = plan.merge(
      action: "hedge_venue_migration",
      dry_run: false,
      live: true,
      confirmation_type: confirmation == CONFIRMATION ? "dashboard_migration_confirmation" : (confirmation.present? ? "invalid_confirmation" : "missing_confirmation"),
      orders_placed: 0,
      signatures_created: 0,
      exchange_order_ids: [],
      leg_readbacks: [],
      lifecycle_state: "READY_FOR_TARGET_FIRST",
      manual_action_required: true,
      final_status: "blocked_before_submit"
    )
    blockers = Array(plan[:blockers])
    if blockers.any?
      receipt[:blockers] = blockers.uniq
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    execute_receipt(position: position, receipt: receipt, confirmation: confirmation)
  end

  class FailClosedLegRunner
    def call(_leg, context: {})
      {
        status: "blocked",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 0,
        blockers: [ "Fallback migration leg runner is unavailable for this direction." ]
      }
    end
  end

  class DefaultLegRunner
    def initialize(env: ENV, venue_builder: HedgeVenues, sleeper: ->(seconds) { sleep(seconds) })
      @env = env
      @venue_builder = venue_builder
      @sleeper = sleeper
    end

    def call(leg, context:)
      venue = HedgeVenues.normalize(leg.fetch(:venue))
      case venue
      when "ethereal"
        run_ethereal_leg(leg, context)
      when "extended"
        run_extended_leg(leg, context)
      when "nado"
        run_nado_leg(leg, context)
      else
        blocked_leg(leg, [ "Migration live execution is unsupported for #{venue}." ])
      end
    rescue => e
      blocked_leg(leg, [ "#{e.class}: #{e.message}" ], status: "failed_before_submit")
    end

    private

    def run_ethereal_leg(leg, context)
      venue = @venue_builder.build("ethereal", env: @env)
      service = EtherealHedgeExecutionService.new(env: @env, venue: venue, sleeper: @sleeper)
      current = venue.read_position(symbol: "ETH")
      size = BigDecimal(leg.fetch(:size_eth).to_s)
      result = if leg.fetch(:side) == "sell"
        if short_size(current).positive?
          service.rebalance_short(position: context.fetch(:position), delta_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        else
          service.open_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        end
      else
        if BigDecimal(leg.fetch(:expected_after_short_eth).to_s).zero?
          service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        else
          service.rebalance_short(position: context.fetch(:position), delta_eth: -size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        end
      end
      normalize_service_result(result, leg)
    end

    def run_extended_leg(leg, context)
      size = BigDecimal(leg.fetch(:size_eth).to_s)
      env = @env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => size.to_s("F"))
      venue = @venue_builder.build("extended", env: env)
      service = ExtendedHedgeExecutionService.new(venue: venue)
      current = venue.read_position(symbol: "ETH")
      result = if leg.fetch(:side) == "sell"
        if short_size(current).positive?
          service.rebalance_short(position: context.fetch(:position), delta_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        else
          service.open_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        end
      else
        if BigDecimal(leg.fetch(:expected_after_short_eth).to_s).zero?
          service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        else
          service.rebalance_short(position: context.fetch(:position), delta_eth: -size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        end
      end
      normalize_service_result(result, leg)
    end

    def run_nado_leg(leg, context)
      venue = @venue_builder.build("nado", env: @env)
      service = NadoHedgeExecutionService.new(env: @env, venue: venue, sleeper: @sleeper)
      current = venue.read_position(symbol: "ETH")
      size = BigDecimal(leg.fetch(:size_eth).to_s)
      result = if leg.fetch(:side) == "sell"
        if short_size(current).positive?
          service.rebalance_short(position: context.fetch(:position), delta_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        else
          service.open_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        end
      else
        if BigDecimal(leg.fetch(:expected_after_short_eth).to_s).zero?
          service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        else
          service.rebalance_short(position: context.fetch(:position), delta_eth: -size, current_position: current, confirmation: nil, max_slippage: max_slippage, require_confirmation: false, migration: true)
        end
      end
      result = service.reconcile_pending_result(
        result,
        expected_short: leg[:expected_after_short_eth],
        target_short: context.dig(:receipt, :target_short),
        tolerance_eth: context.dig(:receipt, :tolerance_abs_eth)
      )
      normalize_service_result(result, leg)
    end

    def normalize_service_result(result, leg)
      receipt = result.receipt
      {
        status: result.status,
        confirmed: service_result_confirmed?(result),
        orders_placed: receipt[:orders_placed] || receipt[:orders_submitted] || (receipt[:submitted] ? 1 : 0),
        signatures_created: receipt[:signatures_created].to_i,
        exchange_order_id: receipt[:exchange_order_id],
        readback: receipt[:post_submit_readback] || receipt[:final_readback] || receipt[:readback_attempts] || receipt[:readback_poll_attempts],
        after_short_eth: confirmed_short_from_receipt(receipt, leg),
        blockers: result.blockers,
        warnings: result.warnings,
        receipt: receipt
      }
    end

    def service_result_confirmed?(result)
      return true if result.status.to_s.in?(%w[success submitted_and_confirmed rebalance_confirmed_late])

      ActiveModel::Type::Boolean.new.cast(result.receipt[:readback_confirmed])
    end

    def confirmed_short_from_receipt(receipt, leg)
      value = receipt.dig(:post_submit_readback, :short_size) ||
        receipt.dig(:final_readback, :short_size) ||
        receipt[:expected_short_eth] ||
        leg[:expected_after_short_eth]
      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError, TypeError
      leg[:expected_after_short_eth]
    end

    def blocked_leg(leg, blockers, status: "blocked")
      { status: status, confirmed: false, orders_placed: 0, signatures_created: 0, blockers: blockers, leg: leg }
    end

    def short_size(position)
      BigDecimal(position&.fetch(:short_size, 0).to_s)
    rescue ArgumentError
      BigDecimal("0")
    end

    def max_slippage
      @env.fetch("MIGRATION_MAX_SLIPPAGE", @env.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01"))
    end
  end

  private

  def live_preflight_gate_open?(confirmation)
    bool_env("MIGRATION_LIVE_ENABLED") && confirmation == CONFIRMATION
  end

  def refresh_dashboard_snapshot(position)
    DashboardSnapshotRefresh.new(position: position, force: true).refresh
  end

  def leg_context(position, confirmation, receipt)
    {
      position: position,
      confirmation: confirmation,
      receipt: receipt
    }
  end

  def execute_receipt(position:, receipt:, confirmation:)
    first_planned_leg = receipt.fetch(:planned_first_leg)
    second_planned_leg = receipt.fetch(:planned_second_leg)
    receipt[:lifecycle_state] = "READY_FOR_TARGET_FIRST"
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    receipt[:target_leg_status] = leg_lifecycle_status(leg: first_leg, planned_leg: first_planned_leg, role: "target")
    receipt[:target_readback_attempts] = first_leg[:readback] if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:target_late_reconciliation] = late_reconciled?(first_leg)
    unless leg_confirmed?(first_leg)
      receipt[:orders_placed] = leg_order_count(first_leg)
      receipt[:orders_submitted] = receipt[:orders_placed]
      receipt[:signatures_created] = leg_signature_count(first_leg)
      receipt[:exchange_order_ids] = [ first_leg[:exchange_order_id] ].compact
      receipt[:submitted] = receipt[:orders_placed].positive?
      receipt[:would_execute_live] = receipt[:submitted]
      receipt[:lifecycle_state] = receipt[:orders_placed].positive? ? "TARGET_SUBMITTED_PENDING_READBACK" : "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:final_status] = receipt[:orders_placed].positive? ? "TARGET_SUBMITTED_BUT_NOT_CONFIRMED" : "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:blockers] = Array(first_leg[:blockers]).presence || [ "First migration leg was not confirmed; second leg was not submitted." ]
      receipt[:manual_action_required] = true
      receipt[:recovery_command] = recovery_command(receipt) if first_planned_leg.fetch(:venue) == receipt[:to_venue] && receipt[:orders_placed].positive?
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    receipt[:lifecycle_state] = late_reconciled?(first_leg) ? "TARGET_CONFIRMED_LATE_BY_RECONCILIATION" : "TARGET_SUBMITTED_AND_CONFIRMED"
    second_leg = @leg_runner.call(second_planned_leg, context: leg_context(position, confirmation, receipt))
    receipt[:second_leg_execution] = sanitize_sensitive(second_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(second_leg) if second_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(second_leg) if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << second_leg[:readback] if second_leg[:readback]
    receipt[:orders_placed] = leg_order_count(first_leg) + leg_order_count(second_leg)
    receipt[:orders_submitted] = receipt[:orders_placed]
    receipt[:signatures_created] = leg_signature_count(first_leg) + leg_signature_count(second_leg)
    receipt[:exchange_order_ids] = [ first_leg[:exchange_order_id], second_leg[:exchange_order_id] ].compact
    receipt[:submitted] = receipt[:orders_placed].positive?
    receipt[:would_execute_live] = receipt[:submitted]
    receipt[:source_leg_status] = leg_lifecycle_status(leg: second_leg, planned_leg: second_planned_leg, role: "source")
    receipt[:source_readback_attempts] = second_leg[:readback] if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:source_late_reconciliation] = late_reconciled?(second_leg)
    if leg_confirmed?(second_leg)
      final = final_readback_status(receipt: receipt, first_leg: first_leg, second_leg: second_leg)
      receipt.merge!(final)
      finalize_production_venue(position, receipt) if receipt[:finalize_available] && receipt[:final_status] == "success"
      receipt[:lifecycle_state] = receipt[:production_venue_finalized] ? "MIGRATION_FINALIZED" : "SOURCE_CLOSE_CONFIRMED"
    else
      receipt[:lifecycle_state] = receipt[:orders_placed].positive? ? "SOURCE_CLOSE_PENDING_READBACK" : "RECOVERY_REQUIRED"
      receipt[:final_status] = "partial_migration_manual_action_required"
      receipt[:manual_action_required] = true
      receipt[:blockers] = Array(second_leg[:blockers]).presence || [ "Second migration leg was not confirmed after first leg succeeded." ]
      receipt[:recovery_command] = recovery_command(receipt) if receipt[:migration_sequence] == "target_first"
      if receipt[:migration_sequence] == "source_first"
        receipt[:warnings] = (Array(receipt[:warnings]) + [ "Source close confirmed but target open did not; hedge may be temporarily unhedged. Manual action required." ]).uniq
      end
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  def live_blockers(position:, receipt:, dry_run:, confirmation:)
    return [] if dry_run

    blockers = []
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "Nado must be flat before dashboard migration." if ![ receipt[:from_venue], receipt[:to_venue] ].include?("nado") && !nado_flat?(position.position_dashboard_snapshot)
    blockers << "position hedge execution_venue must be #{receipt[:from_venue]} before migration" unless HedgeVenues.normalize(position.hedge&.execution_venue) == receipt[:from_venue]
    blockers << "#{HedgeVenues.label(receipt[:from_venue])} live gate must be enabled." unless venue_live_enabled?(receipt[:from_venue])
    blockers << "#{HedgeVenues.label(receipt[:to_venue])} live gate must be enabled." unless venue_live_enabled?(receipt[:to_venue])
    blockers << "#{HedgeVenues.label(receipt[:from_venue])} auto must be disabled during migration." if venue_auto_enabled?(position.position_dashboard_snapshot, receipt[:from_venue])
    blockers << "#{HedgeVenues.label(receipt[:to_venue])} auto must be disabled during migration." if venue_auto_enabled?(position.position_dashboard_snapshot, receipt[:to_venue])
    blockers << "target venue readiness failed or is not cached." unless target_readiness_cached?(position.position_dashboard_snapshot, receipt[:to_venue])
    blockers << "source current position must exist." unless decimal(receipt[:from_short_before]).positive?
    blockers << "target/source open orders must be zero." unless open_orders_clear?(position.position_dashboard_snapshot, receipt[:from_venue], receipt[:to_venue])
    blockers << "dashboard snapshot must be fresh immediately before live migration." if position.position_dashboard_snapshot&.stale_now?
    blockers.concat(recent_rebalance_blockers(position, receipt[:from_venue], receipt[:to_venue]))
    blockers
  end

  def target_readiness_cached?(snapshot, venue)
    return false unless snapshot
    return true if venue == "ethereal"
    return true if venue == "nado"
    return false unless venue == "extended"

    snapshot.open_orders_count_extended.to_i.zero? && snapshot.leverage_margin_gate_status.to_s.in?(%w[ok pass passed ready confirmed])
  end

  def open_orders_clear?(snapshot, from, to)
    return false unless snapshot
    return true unless [ from, to ].include?("extended")

    snapshot.open_orders_count_extended.to_i.zero?
  end

  def venue_live_enabled?(venue)
    case venue
    when "extended" then bool_env("EXTENDED_LIVE_ENABLED")
    when "ethereal" then bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    when "nado" then bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED") && bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    else false
    end
  end

  def venue_auto_enabled?(snapshot, venue)
    return true unless snapshot

    case venue
    when "extended" then ActiveModel::Type::Boolean.new.cast(snapshot.extended_auto_enabled)
    when "ethereal" then ActiveModel::Type::Boolean.new.cast(snapshot.ethereal_auto_enabled)
    when "nado" then bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    else true
    end
  end

  def recent_rebalance_blockers(position, from, to)
    return [] unless position.hedge

    venues = [ from, to ]
    pending = position.hedge.short_rebalances.where(venue: venues, status: ShortRebalance::STATUS_PENDING).order(created_at: :desc).first
    blockers = []
    blockers << "pending #{HedgeVenues.label(pending.venue)} ShortRebalance ##{pending.id} must be resolved before migration." if pending
    recent = position.hedge.short_rebalances.where(venue: venues).where("created_at >= ?", 2.minutes.ago).order(created_at: :desc).first
    blockers << "recent #{HedgeVenues.label(recent.venue)} ShortRebalance ##{recent.id} is too recent for migration; refresh and retry after the guard window." if recent
    blockers
  end

  def nado_flat?(snapshot)
    snapshot && BigDecimal(snapshot.nado_short_eth.to_s).zero?
  rescue ArgumentError
    false
  end

  def final_readback_status(receipt:, first_leg:, second_leg:)
    legs = [
      [ receipt.fetch(:planned_first_leg), first_leg ],
      [ receipt.fetch(:planned_second_leg), second_leg ]
    ]
    from_result = legs.find { |planned, _actual| planned.fetch(:venue) == receipt[:from_venue] }
    to_result = legs.find { |planned, _actual| planned.fetch(:venue) == receipt[:to_venue] }
    from_after = decimal(from_result&.last&.fetch(:after_short_eth, nil) || receipt.dig(:planned_source_leg, :expected_after_short_eth))
    to_after = decimal(to_result&.last&.fetch(:after_short_eth, nil) || receipt.dig(:planned_target_leg, :expected_after_short_eth))
    target = decimal(receipt[:target_short])
    tolerance = decimal(receipt[:tolerance_abs_eth])
    tolerance = decimal(receipt[:target_short]) * BigDecimal("0.03") unless tolerance.positive?
    combined = from_after + to_after
    drift = target - combined
    source_flat = from_after <= BigDecimal("0.001")
    target_holds = (to_after - target).abs <= [ tolerance, BigDecimal("0.001") ].max
    inside = drift.abs <= [ tolerance, BigDecimal("0.001") ].max
    full = receipt[:mode].to_s == "full" || ActiveModel::Type::Boolean.new.cast(receipt[:full_migration_allowed])
    success = !full || (source_flat && target_holds && inside)
    {
      from_short_after_readback: from_after.to_s("F"),
      to_short_after_readback: to_after.to_s("F"),
      final_combined: combined.to_s("F"),
      final_drift: drift.to_s("F"),
      source_flat_confirmed: source_flat,
      target_holds_hedge_confirmed: target_holds,
      final_inside_tolerance: inside,
      finalize_available: success && full,
      final_status: success ? "success" : "combined_outside_tolerance_manual_action_required",
      manual_action_required: !success,
      blockers: success ? [] : [ "Final migration readback did not confirm source flat, target hedge, and combined exposure inside tolerance." ]
    }
  end

  def finalize_production_venue(position, receipt)
    return unless position.hedge

    position.hedge.update!(execution_venue: receipt[:to_venue])
    receipt[:production_venue_finalized] = true
    receipt[:finalized_hedge_id] = position.hedge.id
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def leg_confirmed?(leg)
    ActiveModel::Type::Boolean.new.cast(leg[:confirmed]) || leg[:status] == "confirmed"
  end

  def late_reconciled?(leg)
    ActiveModel::Type::Boolean.new.cast(leg.dig(:receipt, :reconciled_after_pending))
  end

  def leg_lifecycle_status(leg:, planned_leg: nil, role:)
    return "#{role.upcase}_CONFIRMED_LATE_BY_RECONCILIATION" if leg_confirmed?(leg) && late_reconciled?(leg)
    return role == "target" ? "TARGET_SUBMITTED_AND_CONFIRMED" : "SOURCE_CLOSE_CONFIRMED" if leg_confirmed?(leg)
    return role == "target" ? "TARGET_SUBMITTED_PENDING_READBACK" : "SOURCE_CLOSE_PENDING_READBACK" if leg_order_count(leg).positive?

    role == "target" ? "TARGET_REJECTED_OR_NOT_CONFIRMED" : "RECOVERY_REQUIRED"
  end

  def recovery_command(receipt)
    "bin/rails migration:recover_target_first_source_close position_id=#{receipt[:position_id]} from=#{receipt[:from_venue]} to=#{receipt[:to_venue]} dry_run=true"
  end

  def leg_order_count(leg)
    leg[:orders_placed].to_i
  end

  def leg_signature_count(leg)
    leg[:signatures_created].to_i
  end

  def write_receipt(receipt)
    @receipt_writer.write(sanitize_sensitive(receipt))
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = sensitive_key?(key) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end

  def sensitive_key?(key)
    text = key.to_s
    return false if text == "confirmation_type"
    return false if text == "signatures_created"

    text.match?(/api[_-]?key|private|authorization|cookie|signature|secret/i)
  end
end
