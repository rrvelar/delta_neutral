require "digest"

class HedgeVenueMigrationExecutor
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_MIGRATES_HEDGE_BETWEEN_VENUES".freeze

  def initialize(env: ENV, planner: HedgeVenueMigrationPlanner.new, leg_runner: nil, now: -> { Time.current }, snapshot_refresher: nil, receipt_writer: nil, final_verifier_factory: nil, final_reconciliation_attempts: nil, final_reconciliation_interval: nil, sleeper: ->(seconds) { sleep(seconds) }, execution_preflight_factory: nil)
    @env = env
    @planner = planner
    @leg_runner = leg_runner || DefaultLegRunner.new(env: env)
    @now = now
    @snapshot_refresher = snapshot_refresher || method(:refresh_dashboard_snapshot)
    @receipt_writer = receipt_writer || HedgeVenueMigrationReceiptWriter.new(now: now)
    @final_verifier_factory = final_verifier_factory
    @final_reconciliation_attempts = final_reconciliation_attempts || env.fetch("MIGRATION_FINAL_RECONCILIATION_ATTEMPTS", MigrationTargetFirstFinalVerifier::DEFAULT_ATTEMPTS)
    @final_reconciliation_interval = final_reconciliation_interval || env.fetch("MIGRATION_FINAL_RECONCILIATION_INTERVAL_SECONDS", MigrationTargetFirstFinalVerifier::DEFAULT_INTERVAL_SECONDS)
    @sleeper = sleeper
    @execution_preflight_factory = execution_preflight_factory
  end

  def run(position:, from_venue:, to_venue:, mode: "preview", dry_run: true, confirmation: nil, step_size_eth: nil, full_migration_allowed: false, migration_sequence: HedgeVenueMigrationPlanner::DEFAULT_SEQUENCE, execution_preflight: nil)
    refreshed_snapshot = nil
    execution_preflight ||= live_execution_preflight(position: position, from_venue: from_venue, to_venue: to_venue, confirmation: confirmation, migration_sequence: migration_sequence) if !dry_run && live_preflight_gate_open?(confirmation) && @execution_preflight_factory
    if !dry_run && live_preflight_gate_open?(confirmation) && execution_preflight.blank?
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
      migration_sequence: migration_sequence,
      execution_preflight: execution_preflight
    )
    receipt = plan.receipt.merge(
      action: "hedge_venue_migration",
      dry_run: dry_run,
      live: !dry_run,
      source_snapshot_id: refreshed_snapshot&.id || plan.receipt[:source_snapshot_id],
      source_snapshot_refreshed_at: refreshed_snapshot&.refreshed_at&.utc&.iso8601 || plan.receipt[:source_snapshot_refreshed_at],
      confirmation_type: confirmation == CONFIRMATION ? "dashboard_migration_confirmation" : (confirmation.present? ? "invalid_confirmation" : "missing_confirmation"),
      preflight_status: execution_preflight&.fetch(:status, nil),
      preflight_hard_blockers: Array(execution_preflight&.fetch(:hard_blockers, nil)),
      preflight_warnings: Array(execution_preflight&.fetch(:warnings, nil)),
      preflight_diagnostics: execution_preflight&.fetch(:diagnostics, nil),
      orders_placed: 0,
      signatures_created: 0,
      exchange_order_ids: [],
      leg_readbacks: [],
      lifecycle_state: dry_run ? "READY_FOR_TARGET_FIRST" : "PRECHECK_BLOCKED",
      manual_action_required: true,
      final_status: dry_run ? plan.status : "blocked_before_submit"
    )
    pause_active_auto(position) unless dry_run
    blockers = Array(plan.blockers) + live_blockers(position: position, receipt: receipt, dry_run: dry_run, confirmation: confirmation, execution_preflight: execution_preflight)
    if dry_run || blockers.any?
      receipt[:blockers] = blockers.uniq
      receipt[:final_status] = dry_run ? "dry_run" : "blocked_before_submit"
      receipt[:manual_action_required] = !dry_run
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    first_planned_leg = receipt.fetch(:planned_first_leg)
    second_planned_leg = receipt.fetch(:planned_second_leg)
    return execute_source_first(position: position, receipt: receipt, confirmation: confirmation) if receipt[:migration_sequence] == "source_first"

    receipt[:lifecycle_state] = "READY_FOR_TARGET_FIRST"
    prewarm_extended_source_close!(receipt, second_planned_leg)
    mark_time!(receipt, :target_leg_submit_started_at)
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :target_leg_submit_finished_at)
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    record_target_acceptance_timing!(receipt, first_leg, first_planned_leg)
    apply_authoritative_target_open_confirmation!(receipt, first_leg)
    receipt[:target_leg_status] = leg_lifecycle_status(leg: first_leg, planned_leg: first_planned_leg, role: "target")
    receipt[:target_readback_attempts] = first_leg[:readback] if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:target_late_reconciliation] = late_reconciled?(first_leg)
    unless leg_confirmed?(first_leg)
      if target_leg_confirmed_for_source_close?(position: position, receipt: receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
        first_leg = first_leg.merge(status: "confirmed_by_target_readback", confirmed: true)
        receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
        receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
        receipt[:target_leg_status] = "TARGET_CONFIRMED_BY_CONTINUATION_READBACK"
      else
        return stop_after_unconfirmed_first_leg(position: position, receipt: receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
      end
    else
      mark_time!(receipt, :target_readback_confirmed_at)
    end
    receipt[:target_confirmation_polling_latency_seconds] = seconds_between(receipt[:target_readback_started_at], receipt[:target_readback_confirmed_at])

    receipt[:lifecycle_state] = late_reconciled?(first_leg) ? "TARGET_CONFIRMED_LATE_BY_RECONCILIATION" : receipt[:target_leg_status]
    if target_confirm_to_source_close_exceeds_threshold?(receipt)
      apply_target_open_source_still_open_manual_action!(position, receipt, [ "target confirmation to source close submit latency exceeded #{target_to_source_close_latency_threshold_seconds.to_s('F')}s before source close submit" ])
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end
    mark_time!(receipt, :source_close_submit_started_at)
    compute_target_to_source_latency!(receipt)
    second_leg = @leg_runner.call(second_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :source_close_submit_finished_at)
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
    receipt[:source_leg_submitted] = leg_order_count(second_leg).positive?
    receipt[:source_leg_exchange_order_id] = second_leg[:exchange_order_id]
    receipt[:source_close_order_id] = second_leg[:exchange_order_id]
    record_source_close_timing!(receipt, second_leg, second_planned_leg)
    receipt[:source_readback_attempts] = second_leg[:readback] if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:source_late_reconciliation] = late_reconciled?(second_leg)
    if leg_confirmed?(second_leg) || leg_order_count(second_leg).positive?
      receipt.merge!(final_readback_status(position: position, receipt: receipt))
      mark_time!(receipt, :final_all_venue_verification_at)
      record_source_close_position_readback_time!(receipt, second_leg) if receipt[:source_flat_after]
      receipt[:final_position_readback_confirmed_at] = receipt[:source_close_position_readback_confirmed_at]
      apply_authoritative_source_close_confirmation!(receipt, second_leg)
      record_target_open_fill_agreement!(receipt)
      compute_source_close_latency!(receipt)
      compute_double_exposure_latency!(receipt)
      if receipt[:final_status] != "success" && receipt[:migration_sequence] == "target_first"
        apply_target_open_source_still_open_manual_action!(position, receipt, Array(receipt[:blockers]).presence || [ "Source close did not confirm after target was opened." ])
      end
      finalize_production_venue(position, receipt) if receipt[:finalize_available] && receipt[:final_status] == "success"
      apply_latency_incident!(position, receipt) if receipt[:production_venue_finalized] && double_exposure_exceeds_threshold?(receipt)
      receipt[:lifecycle_state] = if receipt[:final_status] == "NOT_PRODUCTION_SAFE_LATENCY"
        "NOT_PRODUCTION_SAFE_LATENCY"
      elsif receipt[:production_venue_finalized]
        "MIGRATION_FINALIZED"
      elsif receipt[:final_status] == "success"
        "SOURCE_CLOSE_CONFIRMED"
      else
        receipt[:final_status]
      end
    else
      apply_target_open_source_still_open_manual_action!(position, receipt, Array(second_leg[:blockers]).presence || [ "Second migration leg was not confirmed after first leg succeeded." ])
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
    pause_active_auto(position)
    blockers = Array(plan[:blockers])
    if blockers.any?
      receipt[:blockers] = blockers.uniq
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    execute_receipt(position: position, receipt: receipt, confirmation: confirmation)
  end

  def execute_source_first(position:, receipt:, confirmation:)
    source_leg_plan = receipt.fetch(:planned_first_leg)
    target_leg_plan = receipt.fetch(:planned_second_leg)
    receipt[:lifecycle_state] = "READY_FOR_SOURCE_FIRST"
    mark_time!(receipt, :source_close_submit_started_at)
    source_leg = @leg_runner.call(source_leg_plan, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :source_close_submit_finished_at)
    receipt[:first_leg_execution] = sanitize_sensitive(source_leg)
    receipt[:from_leg_execution] = sanitize_sensitive(source_leg)
    receipt[:leg_readbacks] << source_leg[:readback] if source_leg[:readback]
    receipt[:orders_placed] = leg_order_count(source_leg)
    receipt[:orders_submitted] = receipt[:orders_placed]
    receipt[:signatures_created] = leg_signature_count(source_leg)
    receipt[:exchange_order_ids] = [ source_leg[:exchange_order_id] ].compact
    receipt[:source_leg_status] = leg_lifecycle_status(leg: source_leg, planned_leg: source_leg_plan, role: "source")
    receipt[:source_leg_submitted] = leg_order_count(source_leg).positive?
    receipt[:source_leg_exchange_order_id] = source_leg[:exchange_order_id]
    receipt[:source_close_order_id] = source_leg[:exchange_order_id]
    record_source_close_timing!(receipt, source_leg, source_leg_plan)
    receipt[:source_readback_attempts] = source_leg[:readback]

    unless leg_confirmed?(source_leg)
      receipt[:final_status] = "MANUAL_ACTION_REQUIRED_SOURCE_CLOSE_NOT_CONFIRMED"
      receipt[:lifecycle_state] = receipt[:final_status]
      receipt[:manual_action_required] = true
      receipt[:blockers] = Array(source_leg[:blockers]).presence || [ "Source-first source close did not confirm; target venue was not opened." ]
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    mark_time!(receipt, :source_close_flat_confirmed_at)
    compute_source_close_latency!(receipt)
    receipt[:underhedge_started_at] = receipt[:source_close_flat_confirmed_at]
    receipt[:lifecycle_state] = "SOURCE_FIRST_SOURCE_FLAT_CONFIRMED"
    configure_source_first_nado_reconciliation!(receipt, target_leg_plan)

    mark_time!(receipt, :target_leg_submit_started_at)
    target_leg = @leg_runner.call(target_leg_plan, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :target_leg_submit_finished_at)
    receipt[:second_leg_execution] = sanitize_sensitive(target_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(target_leg)
    receipt[:leg_readbacks] << target_leg[:readback] if target_leg[:readback]
    receipt[:orders_placed] += leg_order_count(target_leg)
    receipt[:orders_submitted] = receipt[:orders_placed]
    receipt[:signatures_created] += leg_signature_count(target_leg)
    receipt[:exchange_order_ids] << target_leg[:exchange_order_id] if target_leg[:exchange_order_id]
    receipt[:submitted] = receipt[:orders_placed].positive?
    receipt[:would_execute_live] = receipt[:submitted]
    record_target_acceptance_timing!(receipt, target_leg, target_leg_plan)
    receipt[:target_leg_status] = leg_lifecycle_status(leg: target_leg, planned_leg: target_leg_plan, role: "target")
    receipt[:target_readback_attempts] = target_leg[:readback]
    receipt[:nado_source_first_reconciliation_attempts] = target_leg.dig(:receipt, :migration_target_reconciliation_attempts) if source_first_nado_target?(receipt, target_leg_plan)
    receipt[:service_readback_attempts] = Array(receipt[:nado_source_first_reconciliation_attempts]).size if source_first_nado_target?(receipt, target_leg_plan)
    receipt[:canonical_readback_attempts] ||= 0 if source_first_nado_target?(receipt, target_leg_plan)
    receipt[:target_late_reconciliation] = late_reconciled?(target_leg)
    receipt[:target_readback_confirmed_at] ||= target_leg.dig(:timing, :readback_confirmed_at) if leg_confirmed?(target_leg)
    mark_time!(receipt, :target_readback_confirmed_at) if leg_confirmed?(target_leg) && receipt[:target_readback_confirmed_at].blank?
    receipt[:underhedge_ended_at] = receipt[:target_readback_confirmed_at] || receipt[:target_leg_submit_finished_at] if leg_order_count(target_leg).positive?
    annotate_source_first_nado_timing!(receipt, target_leg_plan)
    compute_underhedge_latency!(receipt)

    unless leg_confirmed?(target_leg)
      if source_first_nado_target_accepted?(receipt, target_leg_plan, target_leg)
        execution_confirmation = confirm_source_first_nado_execution_by_digest(receipt: receipt, target_leg: target_leg)
        apply_source_first_nado_execution_confirmation!(receipt, execution_confirmation) if execution_confirmation[:confirmed]
        canonical = confirm_source_first_nado_target_by_canonical_readback(position: position, receipt: receipt)
        if canonical[:confirmed]
          target_leg = mark_source_first_nado_target_confirmed_by_canonical_readback(target_leg, canonical)
          receipt[:second_leg_execution] = sanitize_sensitive(target_leg)
          receipt[:to_leg_execution] = sanitize_sensitive(target_leg)
          receipt[:target_leg_status] = leg_lifecycle_status(leg: target_leg, planned_leg: target_leg_plan, role: "target")
          receipt[:target_late_reconciliation] = true
          receipt[:target_readback_attempts] = canonical[:latest_attempt]
          receipt[:leg_readbacks] << canonical[:latest_attempt]
          receipt[:target_readback_confirmed_at] = canonical.dig(:latest_attempt, :timestamp) || @now.call.utc.iso8601(6)
          receipt[:underhedge_ended_at] = receipt[:target_readback_confirmed_at] unless receipt[:target_execution_confirmed_at].present?
          annotate_source_first_nado_timing!(receipt, target_leg_plan)
          compute_underhedge_latency!(receipt)
        else
          apply_source_first_nado_ambiguous_manual_action!(position, receipt, target_leg)
          write_receipt(receipt)
          return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
        end
      else
        apply_source_first_target_failed_manual_action!(position, receipt, Array(target_leg[:blockers]).presence || [ "Source-first target open did not confirm after source was closed." ])
        write_receipt(receipt)
        return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
      end
    end

    receipt.merge!(source_first_nado_canonical_final_status(receipt) || final_readback_status(position: position, receipt: receipt))
    finalize_production_venue(position, receipt) if receipt[:finalize_available] && receipt[:final_status] == "success"
    annotate_migration_latency!(receipt)
    receipt[:route_latency_proof] = true
    if source_first_nado_target?(receipt, target_leg_plan) && late_reconciled?(target_leg) && receipt[:production_venue_finalized] && receipt[:final_status] == "success"
      receipt[:final_status] = "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK"
      receipt[:lifecycle_state] = receipt[:final_status]
      receipt[:manual_action_required] = false
    end
    receipt[:route_complete_by_readback] ||= receipt[:production_venue_finalized] == true &&
      receipt[:source_flat_after] == true &&
      receipt[:target_holds_expected_short] == true &&
      receipt[:third_venue_flat] == true &&
      receipt[:final_inside_tolerance] == true &&
      receipt[:open_orders_clear_after] == true
    apply_latency_incident!(position, receipt) if receipt[:production_venue_finalized] && latency_safety_exceeds_threshold?(receipt)
    receipt[:production_safe_route] = receipt.fetch(:production_safe_route, receipt[:final_status].in?(%w[success MIGRATION_FINALIZED SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK]))
    receipt[:route_production_safe] = receipt[:production_safe_route]
    receipt[:latency_proof_status] ||= receipt[:route_production_safe] ? "passed" : "failed_latency_threshold"
    receipt[:lifecycle_state] = if receipt[:final_status] == "NOT_PRODUCTION_SAFE_LATENCY"
      "NOT_PRODUCTION_SAFE_LATENCY"
    elsif receipt[:final_status].in?(%w[SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK])
      receipt[:final_status]
    elsif receipt[:production_venue_finalized]
      "MIGRATION_FINALIZED"
    else
      receipt[:final_status]
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
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
      current = frozen_ethereal_source_position(leg, context) || venue.read_position(symbol: "ETH")
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
      return run_extended_source_close_leg(leg, context) if close_to_flat_leg?(leg)

      size = BigDecimal(leg.fetch(:size_eth).to_s)
      env = @env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => size.to_s("F"))
      venue = @venue_builder.build("extended", env: env)
      with_extended_read_snapshot(venue) do
        service = ExtendedHedgeExecutionService.new(venue: venue)
        current = venue.read_position(symbol: "ETH")
        result = if leg.fetch(:side) == "sell"
          if short_size(current).positive?
            service.rebalance_short(position: context.fetch(:position), delta_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
          else
            service.open_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
          end
        else
          service.rebalance_short(position: context.fetch(:position), delta_eth: -size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        end
        normalize_service_result(result, leg)
      end
    end

    def run_extended_source_close_leg(leg, context)
      size = BigDecimal(leg.fetch(:size_eth).to_s)
      prewarmed = consume_prewarmed_extended(size)
      if prewarmed
        venue = prewarmed.fetch(:venue)
        begin
          service = ExtendedHedgeExecutionService.new(venue: venue)
          current = frozen_source_position_for(leg, context, venue_key: "extended") || venue.read_position(symbol: "ETH")
          result = service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
          return normalize_service_result(result, leg)
        ensure
          venue.end_read_snapshot! if venue.respond_to?(:end_read_snapshot!)
        end
      end

      env = @env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => size.to_s("F"))
      venue = @venue_builder.build("extended", env: env)
      with_extended_read_snapshot(venue) do
        service = ExtendedHedgeExecutionService.new(venue: venue)
        current = frozen_source_position_for(leg, context, venue_key: "extended") || venue.read_position(symbol: "ETH")
        result = service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
        normalize_service_result(result, leg)
      end
    end

    # Pre-window read warming for a planned Extended source close (target_first):
    # opens the per-leg read snapshot BEFORE the target leg opens the
    # double-exposure window and performs the close build's static reads
    # (market metadata + slippage-bounded mark price, leverage/margin gate,
    # position, balance) so the in-window build is assembly-only. The
    # open-orders safety gate, submit, order fill confirmation, post-submit
    # readback (volatile reads are invalidated after submit) and the final
    # all-venue verification all remain fresh inside the window. Fail-closed:
    # any error discards the warmup and the close leg reads fresh as before.
    def prewarm_extended_source_close!(leg)
      return nil unless close_to_flat_leg?(leg)
      return nil unless leg.fetch(:venue).to_s == "extended"

      size = BigDecimal(leg.fetch(:size_eth).to_s)
      env = @env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => size.to_s("F"))
      venue = @venue_builder.build("extended", env: env)
      return nil unless venue.respond_to?(:begin_read_snapshot!)

      venue.begin_read_snapshot!
      warmed = []
      venue.read_position(symbol: "ETH")
      warmed << "positions"
      venue.market_metadata_diagnostics
      warmed << "market"
      venue.blockers
      warmed.concat(%w[leverage balance])
      @prewarmed_extended = { venue: venue, size: size }
      { reads: warmed, size_eth: size.to_s("F") }
    rescue StandardError => e
      venue.end_read_snapshot! if venue.respond_to?(:end_read_snapshot!)
      @prewarmed_extended = nil
      { error: "#{e.class}: #{e.message}" }
    end

    public :prewarm_extended_source_close!

    def consume_prewarmed_extended(size)
      prewarmed = @prewarmed_extended
      @prewarmed_extended = nil
      return nil unless prewarmed
      unless prewarmed.fetch(:size) == size
        prewarmed.fetch(:venue).end_read_snapshot! if prewarmed.fetch(:venue).respond_to?(:end_read_snapshot!)
        return nil
      end

      prewarmed
    end

    # Opens a per-leg Extended read snapshot so the pre-read + the lifecycle build reuse
    # one read per endpoint. Always closed; the lifecycle invalidates volatile reads
    # after submit and forces fresh reads for the readback.
    def with_extended_read_snapshot(venue)
      venue.begin_read_snapshot! if venue.respond_to?(:begin_read_snapshot!)
      yield
    ensure
      venue.end_read_snapshot! if venue.respond_to?(:end_read_snapshot!)
    end

    def close_to_flat_leg?(leg)
      leg.fetch(:side) == "buy" && BigDecimal(leg.fetch(:expected_after_short_eth).to_s).zero?
    end

    FROZEN_SOURCE_SIZE_TOLERANCE = BigDecimal("0.01")

    # Part A: for the Ethereal source close-to-flat in a target_first canary, use the
    # runner-provided FROZEN source position and skip the ~3s pre-submit read_position
    # ONLY when the runner proved every invariant (gates armed, source auto paused, open
    # orders zero, runner inactive, fresh pre-arm source snapshot) AND the planned close
    # size matches the frozen size within tolerance. The mandatory post-submit order-list
    # fill confirmation and the executor's final flat readback still read fresh. Any
    # missing/mismatched signal returns nil -> caller reads fresh (fail-closed to existing
    # behavior). Never confirms the close from this snapshot.
    def frozen_ethereal_source_position(leg, context)
      frozen_source_position_for(leg, context, venue_key: "ethereal")
    end

    def frozen_source_position_for(leg, context, venue_key:)
      return nil unless close_to_flat_leg?(leg)
      return nil unless leg.fetch(:venue).to_s == venue_key

      receipt = context[:receipt]
      return nil unless receipt.is_a?(Hash)
      return nil unless receipt[:migration_sequence].to_s == "target_first"

      proof = receipt[:frozen_source_position]
      return nil unless proof.is_a?(Hash) && proof[:invariants_proven] == true
      return nil unless proof[:source_venue].to_s == venue_key

      frozen = frozen_decimal(proof[:short_size])
      planned = frozen_decimal(leg[:size_eth])
      return nil unless frozen&.positive? && planned&.positive?
      return nil unless (frozen - planned).abs <= FROZEN_SOURCE_SIZE_TOLERANCE

      base = {
        side: "short", size: (-frozen).to_s("F"), short_size: frozen.to_s("F"),
        margin_mode: "cross", frozen_source_position: true
      }
      if venue_key == "ethereal"
        base.merge(venue: "Ethereal", symbol: "ETH-PERP", market_symbol: "ETH-PERP")
      else
        base.merge(venue: "Extended", symbol: "ETH", market_symbol: "ETH-USD")
      end
    end

    def frozen_decimal(value)
      return nil if value.nil? || value.to_s.strip.empty?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
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
      result = reconcile_nado_migration_leg(service: service, result: result, leg: leg, context: context)
      normalize_service_result(result, leg)
    end

    def reconcile_nado_migration_leg(service:, result:, leg:, context:)
      attempts = []
      attempts_limit = source_first_nado_target_leg?(leg, context) ? 1 : nado_target_reconciliation_attempts(context)
      attempts_limit.times do |index|
        result = service.reconcile_pending_result(
          result,
          expected_short: leg[:expected_after_short_eth],
          target_short: context.dig(:receipt, :target_short),
          tolerance_eth: context.dig(:receipt, :tolerance_abs_eth)
        )
        attempts << nado_reconciliation_attempt_payload(result: result, leg: leg, context: context, attempt: index + 1)
        break if service_result_confirmed?(result)
        break unless nado_pending_result?(result)

        @sleeper.call(nado_target_reconciliation_interval(context)) if index < attempts_limit - 1
      end
      result.receipt[:migration_target_reconciliation_attempts] = attempts
      result
    end

    def nado_pending_result?(result)
      result.status.to_s.in?(%w[submitted_but_readback_pending submitted_but_not_confirmed submitted_pending_readback])
    end

    def source_first_nado_target_leg?(leg, context)
      receipt = context[:receipt] || {}
      receipt[:migration_sequence].to_s == "source_first" &&
        HedgeVenues.normalize(leg[:venue]) == "nado" &&
        HedgeVenues.normalize(receipt[:to_venue]) == "nado"
    end

    def nado_target_reconciliation_attempts(context)
      value = context.dig(:receipt, :nado_target_reconciliation_attempts) || @env["MIGRATION_NADO_TARGET_RECONCILIATION_ATTEMPTS"] || 6
      [ value.to_i, 1 ].max
    end

    def nado_target_reconciliation_interval(context)
      value = context.dig(:receipt, :nado_target_reconciliation_interval_seconds) || @env["MIGRATION_NADO_TARGET_RECONCILIATION_INTERVAL_SECONDS"] || "0.5"
      BigDecimal(value.to_s).to_f
    rescue ArgumentError
      0.5
    end

    def nado_reconciliation_attempt_payload(result:, leg:, context:, attempt:)
      confirmation = result.receipt[:pending_reconciliation_confirmation] || {}
      readback = result.receipt[:pending_reconciliation_readback] || result.receipt[:post_submit_readback] || result.receipt[:after_readback]
      actual = confirmation[:actual_short_eth] || short_size(readback).to_s("F")
      expected = confirmation[:expected_short_eth] || leg[:expected_after_short_eth]
      expected_difference = confirmation[:expected_difference_eth] || decimal_difference(actual, expected)
      expected_tolerance = confirmation[:expected_tolerance_eth]
      route_tolerance = confirmation[:route_tolerance_eth] || context.dig(:receipt, :tolerance_abs_eth)
      {
        attempt: attempt,
        timestamp: Time.current.utc.iso8601(6),
        digest: result.receipt[:exchange_order_id],
        status: result.status,
        readback_confirmed: ActiveModel::Type::Boolean.new.cast(result.receipt[:readback_confirmed]),
        exchange_order_id: result.receipt[:exchange_order_id],
        actual_nado_short_eth: actual,
        expected_nado_short_eth: expected,
        difference_eth: expected_difference,
        size_increment_tolerance_eth: expected_tolerance,
        route_target_short_eth: confirmation[:target_short_eth] || context.dig(:receipt, :target_short),
        route_target_difference_eth: confirmation[:target_difference_eth],
        route_tolerance_eth: route_tolerance,
        confirmed_by_size_increment: confirmation[:confirmed_by_size_increment],
        confirmed_by_route_tolerance: confirmation[:confirmed_by_route_tolerance],
        confirmed: confirmation.fetch(:confirmed, ActiveModel::Type::Boolean.new.cast(result.receipt[:readback_confirmed])),
        reason: result.blockers.first || result.status,
        position_readback: readback,
        order_status_readback: result.receipt[:order_status_readback] || result.receipt[:pending_reconciliation_order_status],
        fills_readback: result.receipt[:fills_readback] || result.receipt[:pending_reconciliation_fills],
        readback_source: readback.present? ? "nado_position_readback" : "unavailable",
        readback: readback
      }.compact
    end

    def decimal_difference(left, right)
      (BigDecimal(left.to_s) - BigDecimal(right.to_s)).abs.to_s("F")
    rescue ArgumentError, TypeError
      nil
    end

    def normalize_service_result(result, leg)
      receipt = result.receipt
      timing = service_action_timing(receipt)
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
        timing: timing,
        slow_step: timing[:slow_step],
        close_fill_confirmation: receipt[:close_fill_confirmation],
        open_fill_confirmation: receipt[:open_fill_confirmation],
        receipt: receipt
      }
    end

    def service_action_timing(receipt)
      source = receipt[:execution_timing].presence || receipt.slice(
        :build_started_at, :build_finished_at, :sign_started_at, :sign_finished_at,
        :submit_started_at, :submit_finished_at, :submit_latency_seconds,
        :exchange_accept_at, :readback_started_at, :readback_confirmed_at,
        :readback_latency_seconds, :total_action_latency_seconds, :poll_attempts,
        :poll_interval_seconds, :slow_step
      )
      source.to_h.compact
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

  def live_execution_preflight(position:, from_venue:, to_venue:, confirmation:, migration_sequence:)
    factory = @execution_preflight_factory || ->(**kwargs) { MigrationExecutionPreflight.new(**kwargs).report }
    factory.call(
      position: position,
      from: from_venue,
      to: to_venue,
      strategy: migration_sequence,
      env: @env,
      live: true,
      confirmation: confirmation,
      expected_confirmation: CONFIRMATION,
      require_migration_live_gate: true,
      require_venue_live_gates: true
    )
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
    return execute_source_first(position: position, receipt: receipt, confirmation: confirmation) if receipt[:migration_sequence] == "source_first"

    receipt[:lifecycle_state] = "READY_FOR_TARGET_FIRST"
    prewarm_extended_source_close!(receipt, second_planned_leg)
    mark_time!(receipt, :target_leg_submit_started_at)
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :target_leg_submit_finished_at)
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    record_target_acceptance_timing!(receipt, first_leg, first_planned_leg)
    apply_authoritative_target_open_confirmation!(receipt, first_leg)
    receipt[:target_leg_status] = leg_lifecycle_status(leg: first_leg, planned_leg: first_planned_leg, role: "target")
    receipt[:target_readback_attempts] = first_leg[:readback] if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:target_late_reconciliation] = late_reconciled?(first_leg)
    unless leg_confirmed?(first_leg)
      if target_leg_confirmed_for_source_close?(position: position, receipt: receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
        first_leg = first_leg.merge(status: "confirmed_by_target_readback", confirmed: true)
        receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
        receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
        receipt[:target_leg_status] = "TARGET_CONFIRMED_BY_CONTINUATION_READBACK"
      else
        return stop_after_unconfirmed_first_leg(position: position, receipt: receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
      end
    else
      mark_time!(receipt, :target_readback_confirmed_at)
    end
    receipt[:target_confirmation_polling_latency_seconds] = seconds_between(receipt[:target_readback_started_at], receipt[:target_readback_confirmed_at])

    receipt[:lifecycle_state] = late_reconciled?(first_leg) ? "TARGET_CONFIRMED_LATE_BY_RECONCILIATION" : receipt[:target_leg_status]
    if target_confirm_to_source_close_exceeds_threshold?(receipt)
      apply_target_open_source_still_open_manual_action!(position, receipt, [ "target confirmation to source close submit latency exceeded #{target_to_source_close_latency_threshold_seconds.to_s('F')}s before source close submit" ])
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end
    mark_time!(receipt, :source_close_submit_started_at)
    compute_target_to_source_latency!(receipt)
    second_leg = @leg_runner.call(second_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :source_close_submit_finished_at)
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
    receipt[:source_leg_submitted] = leg_order_count(second_leg).positive?
    receipt[:source_leg_exchange_order_id] = second_leg[:exchange_order_id]
    receipt[:source_close_order_id] = second_leg[:exchange_order_id]
    record_source_close_timing!(receipt, second_leg, second_planned_leg)
    receipt[:source_readback_attempts] = second_leg[:readback] if second_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:source_late_reconciliation] = late_reconciled?(second_leg)
    if leg_confirmed?(second_leg) || leg_order_count(second_leg).positive?
      receipt.merge!(final_readback_status(position: position, receipt: receipt))
      mark_time!(receipt, :final_all_venue_verification_at)
      record_source_close_position_readback_time!(receipt, second_leg) if receipt[:source_flat_after]
      receipt[:final_position_readback_confirmed_at] = receipt[:source_close_position_readback_confirmed_at]
      apply_authoritative_source_close_confirmation!(receipt, second_leg)
      record_target_open_fill_agreement!(receipt)
      compute_source_close_latency!(receipt)
      compute_double_exposure_latency!(receipt)
      if receipt[:final_status] != "success" && receipt[:migration_sequence] == "target_first"
        apply_target_open_source_still_open_manual_action!(position, receipt, Array(receipt[:blockers]).presence || [ "Source close did not confirm after target was opened." ])
      end
      finalize_production_venue(position, receipt) if receipt[:finalize_available] && receipt[:final_status] == "success"
      apply_latency_incident!(position, receipt) if receipt[:production_venue_finalized] && double_exposure_exceeds_threshold?(receipt)
      receipt[:lifecycle_state] = if receipt[:final_status] == "NOT_PRODUCTION_SAFE_LATENCY"
        "NOT_PRODUCTION_SAFE_LATENCY"
      elsif receipt[:production_venue_finalized]
        "MIGRATION_FINALIZED"
      elsif receipt[:final_status] == "success"
        "SOURCE_CLOSE_CONFIRMED"
      else
        receipt[:final_status]
      end
    else
      apply_target_open_source_still_open_manual_action!(position, receipt, Array(second_leg[:blockers]).presence || [ "Second migration leg was not confirmed after first leg succeeded." ])
      if receipt[:migration_sequence] == "source_first"
        receipt[:warnings] = (Array(receipt[:warnings]) + [ "Source close confirmed but target open did not; hedge may be temporarily unhedged. Manual action required." ]).uniq
      end
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  def mark_time!(receipt, key)
    time = @now.call
    receipt[key] = time.utc.iso8601(6)
  end

  # Pre-window read warming for target_first Extended source closes. Runs
  # BEFORE the target leg (before the double-exposure window opens); records
  # what was warmed so the receipt shows which reads were static-warm vs fresh.
  # No-op unless the leg runner supports it; fail-closed to fresh reads.
  def prewarm_extended_source_close!(receipt, second_planned_leg)
    return unless receipt[:migration_sequence].to_s == "target_first"
    return unless second_planned_leg.is_a?(Hash) && second_planned_leg[:venue].to_s == "extended"
    return unless @leg_runner.respond_to?(:prewarm_extended_source_close!)

    mark_time!(receipt, :pre_window_warmup_started_at)
    result = @leg_runner.prewarm_extended_source_close!(second_planned_leg)
    mark_time!(receipt, :pre_window_warmup_finished_at)
    receipt[:pre_window_warmup_reads] = result.is_a?(Hash) ? result[:reads] : nil
    receipt[:pre_window_warmup_error] = result.is_a?(Hash) ? result[:error] : nil
    receipt[:metadata_source] = result.is_a?(Hash) && result[:reads].present? ? "pre_window_snapshot" : "live_read"
  rescue StandardError => e
    receipt[:pre_window_warmup_error] = "#{e.class}: #{e.message}"
    receipt[:metadata_source] = "live_read"
  end

  def record_target_acceptance_timing!(receipt, leg, planned_leg)
    return unless planned_leg.fetch(:venue) == receipt[:to_venue]
    return unless leg_order_count(leg).positive?

    timing = leg[:timing] || {}
    receipt[:target_action_timing] = timing if timing.present?
    receipt[:target_exchange_accept_at] ||= timing[:exchange_accept_at]
    receipt[:target_leg_accepted_at] ||= receipt[:target_leg_submit_finished_at]
    receipt[:target_leg_digest_or_order_id] ||= leg[:exchange_order_id]
    receipt[:target_readback_started_at] ||= receipt[:target_leg_submit_finished_at]
    receipt[:target_leg_submit_latency_seconds] = seconds_between(receipt[:target_leg_submit_started_at], receipt[:target_leg_submit_finished_at])
    receipt[:target_total_latency_seconds] = timing[:total_action_latency_seconds] || receipt[:target_leg_submit_latency_seconds]
    receipt[:target_submit_latency_seconds] = timing[:submit_latency_seconds] || receipt[:target_leg_submit_latency_seconds]
    receipt[:target_readback_latency_seconds] = timing[:readback_latency_seconds]
    receipt[:target_slow_step] = timing[:slow_step]
    receipt[:target_confirmation_polling_latency_seconds] = seconds_between(receipt[:target_readback_started_at], receipt[:target_readback_confirmed_at]) if receipt[:target_readback_confirmed_at]
  end

  def record_source_close_timing!(receipt, leg, planned_leg)
    return unless planned_leg.fetch(:venue) == receipt[:from_venue]

    timing = leg[:timing] || {}
    receipt[:source_close_action_timing] = timing if timing.present?
    receipt[:source_close_submit_latency_seconds] = seconds_between(receipt[:source_close_submit_started_at], receipt[:source_close_submit_finished_at])
    receipt[:source_close_total_latency_seconds] = timing[:total_action_latency_seconds] || receipt[:source_close_submit_latency_seconds]
    receipt[:source_close_exchange_submit_latency_seconds] = timing[:submit_latency_seconds] || receipt[:source_close_submit_latency_seconds]
    receipt[:source_close_readback_latency_seconds] = timing[:readback_latency_seconds]
    receipt[:source_close_slow_step] = timing[:slow_step]
    receipt[:source_close_readback_started_at] ||= receipt[:source_close_submit_finished_at] if leg_order_count(leg).positive?
  end

  def compute_target_to_source_latency!(receipt)
    receipt[:target_to_source_close_submit_latency_seconds] = seconds_between(receipt[:target_leg_submit_finished_at], receipt[:source_close_submit_started_at])
    receipt[:target_accept_to_source_close_submit_latency_seconds] = seconds_between(receipt[:target_leg_accepted_at], receipt[:source_close_submit_started_at])
    receipt[:target_confirm_to_source_close_submit_latency_seconds] = seconds_between(receipt[:target_readback_confirmed_at], receipt[:source_close_submit_started_at])
  end

  def compute_source_close_latency!(receipt)
    receipt[:source_close_submit_to_flat_seconds] = seconds_between(receipt[:source_close_submit_finished_at], receipt[:source_close_flat_confirmed_at])
    receipt[:source_close_submit_start_after_target_confirm_seconds] = receipt[:target_confirm_to_source_close_submit_latency_seconds]
  end

  # End the double-exposure window at the close leg's own flat readback timestamp
  # (its position readback already confirmed the source flat) instead of stamping
  # the wall clock after the slow final all-venue verification, which otherwise
  # inflates the window by the entire verification duration. The final verification
  # still runs first and still gates success — this only re-anchors the timestamp.
  # Falls back to stamping now when the leg carried no readback timestamp.
  def record_source_close_position_readback_time!(receipt, source_leg)
    leg_readback_confirmed_at = source_leg.is_a?(Hash) ? source_leg.dig(:timing, :readback_confirmed_at) : nil
    if leg_readback_confirmed_at.present?
      receipt[:source_close_position_readback_confirmed_at] = leg_readback_confirmed_at
    else
      mark_time!(receipt, :source_close_position_readback_confirmed_at)
    end
  end

  # For target_first migrations, end the overhedge window at the authoritative
  # reduce-only source-close FILL confirmation (when present) instead of the slow
  # position readback — but ONLY when the final position readback also confirms the
  # source is flat. Fail-closed: no authoritative fill, or a fill that disagrees
  # with the final readback, preserves the existing position-readback timestamp and
  # is flagged so the proof is not certified on the shortened window.
  def apply_authoritative_source_close_confirmation!(receipt, source_leg)
    return unless receipt[:migration_sequence].to_s == "target_first"

    position_ts = receipt[:source_close_position_readback_confirmed_at]
    fill = authoritative_source_close_fill(source_leg)

    if fill && receipt[:source_flat_after] == true
      receipt[:source_close_confirmation_source] = fill[:source]
      receipt[:source_close_fill_confirmed_at] = fill[:confirmed_at]
      receipt[:source_close_fill_readback_agreement] = true
      receipt[:source_close_authoritative_confirmed_at] = fill[:confirmed_at]
      receipt[:source_close_authoritative_confirmation_agreement] = true
      receipt[:source_close_flat_confirmed_at] = fill[:confirmed_at]
      receipt[:double_exposure_end_source] = fill[:source].to_s.start_with?("nado") ? fill[:source] : "authoritative_fill"
      apply_nado_close_confirmation_fields!(receipt, fill)
      return
    end

    if fill
      # Fill claims closed-to-flat but the final readback did not confirm source flat:
      # keep the slow window and flag the disagreement so the proof cannot certify.
      receipt[:source_close_confirmation_source] = fill[:source]
      receipt[:source_close_fill_confirmed_at] = fill[:confirmed_at]
      receipt[:source_close_fill_readback_agreement] = false
      receipt[:source_close_authoritative_confirmed_at] = fill[:confirmed_at]
      receipt[:source_close_authoritative_confirmation_agreement] = false
      apply_nado_close_confirmation_fields!(receipt, fill)
    else
      receipt[:source_close_confirmation_source] = "position_readback"
    end
    receipt[:source_close_flat_confirmed_at] = position_ts if receipt[:source_flat_after]
    receipt[:double_exposure_end_source] = "position_readback"
  end

  # Surfaces the Nado terminal-execution evidence in the mandated receipt fields
  # when the authoritative close confirmation came from Nado.
  def apply_nado_close_confirmation_fields!(receipt, fill)
    return unless fill[:source].to_s.start_with?("nado")

    receipt[:nado_close_confirmation_source] = fill[:source]
    receipt[:nado_close_tx_hash] = fill[:digest]
    receipt[:nado_close_tx_status] = fill[:order_status]
    receipt[:nado_close_tx_confirmed_at] = fill[:confirmed_at]
  end

  # For target_first migrations, START the overhedge window at the authoritative
  # Ethereal target-open FILL confirmation (when present) instead of after the slow
  # position readback. This corrects the measurement (the receipt no longer understates
  # the real overhedge) AND reflects that, with the fast target-open confirmation, the
  # source close is submitted immediately after a trusted target fill. Fail-closed: with
  # no authoritative open fill the existing submit-finished timestamp is preserved
  # unchanged. The window start can only move EARLIER (never later) than
  # target_leg_submit_finished_at, so it never masks real exposure.
  def apply_authoritative_target_open_confirmation!(receipt, target_leg)
    return unless receipt[:migration_sequence].to_s == "target_first"

    receipt[:open_fill_confirmation] = target_leg[:open_fill_confirmation] if target_leg.is_a?(Hash) && target_leg[:open_fill_confirmation].present?
    fill = authoritative_target_open_fill(target_leg)
    if fill
      receipt[:target_open_confirmation_source] = fill[:source]
      receipt[:target_open_fill_confirmed_at] = fill[:confirmed_at]
      receipt[:target_leg_accepted_at] = fill[:confirmed_at]
      receipt[:double_exposure_start_source] = "authoritative_fill"
    else
      receipt[:target_open_confirmation_source] = "position_readback"
      receipt[:double_exposure_start_source] = "position_readback"
    end
  end

  # Only trust a confirmed, non-reduce-only, timestamped target-open fill. Never marks
  # the target confirmed on submit alone -- the venue must have reported the open order
  # terminally FILLED for the expected size (validated by classify_open_fill).
  def authoritative_target_open_fill(target_leg)
    confirmation = target_leg.is_a?(Hash) ? target_leg[:open_fill_confirmation] : nil
    return nil unless confirmation.is_a?(Hash)
    return nil unless confirmation[:confirmed] == true
    return nil unless confirmation[:reduce_only] == false
    return nil if confirmation[:confirmed_at].blank?
    return nil if confirmation[:source].to_s.blank?

    confirmation
  end

  # Records whether the authoritative target-open fill agrees with the final position
  # readback (target actually holds the expected short). Certification already requires
  # target_holds_expected_short for success, so a disagreement fails closed; this only
  # surfaces the diagnostic. nil when there was no authoritative open fill.
  def record_target_open_fill_agreement!(receipt)
    return unless receipt[:migration_sequence].to_s == "target_first"

    receipt[:target_open_position_readback_confirmed_at] ||= receipt[:target_readback_confirmed_at]
    return if receipt[:target_open_fill_confirmed_at].blank?

    receipt[:target_open_fill_readback_agreement] = receipt[:target_holds_expected_short] == true
  end

  # Only trust a confirmed, reduce-only, timestamped close-to-flat fill.
  def authoritative_source_close_fill(source_leg)
    confirmation = source_leg.is_a?(Hash) ? source_leg[:close_fill_confirmation] : nil
    return nil unless confirmation.is_a?(Hash)
    return nil unless confirmation[:confirmed] == true
    return nil unless confirmation[:reduce_only] == true
    return nil if confirmation[:confirmed_at].blank?
    return nil if confirmation[:source].to_s.blank?

    confirmation
  end

  def compute_double_exposure_latency!(receipt)
    return unless receipt[:migration_sequence].to_s == "target_first"
    return unless receipt[:target_leg_accepted_at].present?

    receipt[:double_exposure_started_at] ||= receipt[:target_leg_accepted_at]
    receipt[:source_close_order_submitted_at] ||= receipt[:source_close_submit_finished_at]
    receipt[:double_exposure_ended_at] ||= receipt[:source_close_flat_confirmed_at] if receipt[:source_flat_after]
    receipt[:double_exposure_seconds] ||= seconds_between(receipt[:double_exposure_started_at], receipt[:double_exposure_ended_at])
    receipt[:source_close_exchange_latency_seconds] ||= receipt[:source_close_exchange_submit_latency_seconds] || receipt[:source_close_submit_latency_seconds]
    receipt[:source_close_readback_latency_seconds] ||= receipt[:source_close_submit_to_flat_seconds]
  end

  def compute_underhedge_latency!(receipt)
    return unless receipt[:migration_sequence].to_s == "source_first"
    return unless receipt[:underhedge_started_at].present?

    receipt[:underhedge_seconds] = seconds_between(receipt[:underhedge_started_at], receipt[:underhedge_ended_at])
    receipt[:double_exposure_seconds] ||= "0"
  end

  def double_exposure_exceeds_threshold?(receipt)
    seconds = receipt[:double_exposure_seconds]
    seconds.present? && BigDecimal(seconds.to_s) > max_double_exposure_seconds
  rescue ArgumentError
    false
  end

  def latency_safety_exceeds_threshold?(receipt)
    return source_first_latency_safety_exceeds_threshold?(receipt) if receipt[:migration_sequence].to_s == "source_first"

    double_exposure_exceeds_threshold?(receipt) ||
      latency_exceeds?(receipt[:underhedge_seconds], max_unhedged_seconds) ||
      latency_exceeds?(receipt[:total_migration_latency_seconds], max_total_route_seconds)
  end

  def source_first_latency_safety_exceeds_threshold?(receipt)
    latency_exceeds?(source_first_risk_latency(receipt), max_unhedged_seconds)
  end

  def source_first_risk_latency(receipt)
    if receipt[:target_execution_confirmed_at].present? && receipt[:route_complete_by_readback] == true
      return receipt[:source_flat_to_execution_confirmed_seconds]
    end

    receipt[:source_flat_to_target_confirmed_seconds] || receipt[:underhedge_seconds] || receipt[:source_flat_to_finalized_seconds]
  end

  def latency_exceeds?(value, threshold)
    value.present? && BigDecimal(value.to_s) > threshold
  rescue ArgumentError
    false
  end

  def max_double_exposure_seconds
    decimal_env("MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS", "5")
  end

  def max_unhedged_seconds
    decimal_env("MIGRATION_MAX_UNHEDGED_SECONDS", "10")
  end

  def max_total_route_seconds
    decimal_env("MIGRATION_MAX_TOTAL_ROUTE_SECONDS", "30")
  end

  def apply_latency_incident!(position, receipt)
    pause_autonomous_migration!(position, receipt)
    safe_finalized = receipt[:production_venue_finalized] == true &&
      receipt[:source_flat_after] == true &&
      receipt[:target_holds_expected_short] == true &&
      receipt[:third_venue_flat] == true &&
      receipt[:final_inside_tolerance] == true &&
      receipt[:open_orders_clear_after] == true
    receipt[:final_status] = "NOT_PRODUCTION_SAFE_LATENCY" unless safe_finalized
    receipt[:lifecycle_state] = safe_finalized ? receipt[:final_status] : "NOT_PRODUCTION_SAFE_LATENCY"
    receipt[:manual_action_required] = !safe_finalized
    receipt[:latency_incident] = true
    receipt[:latency_proof_status] = "failed_latency_threshold"
    receipt[:route_complete_by_readback] = safe_finalized
    receipt[:production_safe_route] = false
    receipt[:route_production_safe] = false
    receipt[:double_exposure_threshold_passed] = !double_exposure_exceeds_threshold?(receipt)
    receipt[:latency_threshold_blockers] = latency_safety_blockers(receipt)
    receipt[:blockers] = safe_finalized ? Array(receipt[:blockers]) : receipt[:latency_threshold_blockers]
    receipt[:recovery_command] ||= recovery_command(receipt) unless safe_finalized
    receipt[:random_and_auto_paused] = true
    receipt[:warnings] = (Array(receipt[:warnings]) + [
      "Route finalized safely but latency thresholds failed for production random; route must be re-proven with acceptable latency."
    ]).uniq
  end

  def latency_safety_blockers(receipt)
    blockers = []
    if double_exposure_exceeds_threshold?(receipt)
      blockers << "double exposure lasted #{receipt[:double_exposure_seconds]}s, exceeding MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS=#{max_double_exposure_seconds.to_s('F')}"
    end
    source_first = receipt[:migration_sequence].to_s == "source_first"
    underhedge_latency = source_first_risk_latency(receipt)
    if source_first && latency_exceeds?(underhedge_latency, max_unhedged_seconds)
      blockers << "source-flat-to-target-confirmed latency #{underhedge_latency}s exceeded MIGRATION_MAX_UNHEDGED_SECONDS=#{max_unhedged_seconds.to_s('F')}"
    elsif latency_exceeds?(receipt[:underhedge_seconds], max_unhedged_seconds)
      blockers << "underhedge lasted #{receipt[:underhedge_seconds]}s, exceeding MIGRATION_MAX_UNHEDGED_SECONDS=#{max_unhedged_seconds.to_s('F')}"
    end
    if !source_first && latency_exceeds?(receipt[:total_migration_latency_seconds], max_total_route_seconds)
      blockers << "total migration latency #{receipt[:total_migration_latency_seconds]}s exceeded MIGRATION_MAX_TOTAL_ROUTE_SECONDS=#{max_total_route_seconds.to_s('F')}"
    end
    blockers
  end

  def apply_source_first_target_failed_manual_action!(position, receipt, blockers)
    pause_autonomous_migration!(position, receipt)
    receipt[:final_status] = "MANUAL_ACTION_REQUIRED_SOURCE_FLAT_TARGET_NOT_OPEN"
    receipt[:lifecycle_state] = receipt[:final_status]
    receipt[:manual_action_required] = true
    receipt[:blockers] = blockers
    receipt[:recovery_command] = "bin/rails migration:run_manual_live_canary position_id=#{receipt[:position_id]} from=#{receipt[:from_venue]} to=#{receipt[:to_venue]} sequence=source_first confirmation=#{MigrationManualLiveCanaryRunner::CONFIRMATION}"
    receipt[:random_and_auto_paused] = true
    receipt[:warnings] = (Array(receipt[:warnings]) + [
      "Source-first route closed source but target venue did not confirm; hedge may be underhedged. Manual action required."
    ]).uniq
  end

  def configure_source_first_nado_reconciliation!(receipt, target_leg_plan)
    return unless source_first_nado_target?(receipt, target_leg_plan)

    receipt[:lifecycle_state] = "SOURCE_FIRST_SOURCE_FLAT_CONFIRMED"
    receipt[:nado_source_first_reconciliation_enabled] = true
    receipt[:nado_target_reconciliation_attempts] ||= nado_source_first_reconciliation_attempts
    receipt[:nado_target_reconciliation_interval_seconds] ||= nado_source_first_reconciliation_interval_seconds.to_s("F")
    receipt[:nado_source_first_max_confirmation_seconds] ||= nado_source_first_max_confirmation_seconds.to_s("F")
  end

  def source_first_nado_target?(receipt, target_leg_plan)
    receipt[:migration_sequence].to_s == "source_first" &&
      HedgeVenues.normalize(target_leg_plan.fetch(:venue)) == "nado" &&
      HedgeVenues.normalize(receipt[:to_venue]) == "nado"
  end

  def source_first_nado_target_accepted?(receipt, target_leg_plan, target_leg)
    source_first_nado_target?(receipt, target_leg_plan) &&
      (leg_order_count(target_leg).positive? || target_leg[:exchange_order_id].present? || receipt[:target_leg_digest_or_order_id].present?)
  end

  def apply_source_first_nado_ambiguous_manual_action!(position, receipt, target_leg)
    pause_autonomous_migration!(position, receipt)
    receipt[:final_status] = "SOURCE_FIRST_TARGET_AMBIGUOUS_AFTER_TIMEOUT"
    receipt[:lifecycle_state] = receipt[:final_status]
    receipt[:manual_action_required] = true
    receipt[:pending_nado_source_first_digest_unresolved] = true
    receipt[:nado_target_digest] ||= receipt[:target_leg_digest_or_order_id] || target_leg[:exchange_order_id]
    receipt[:nado_target_exchange_order_id] ||= receipt[:nado_target_digest]
    receipt[:blockers] = Array(target_leg[:blockers]).presence || [
      "Nado accepted target digest after source was closed, but bounded reconciliation could not confirm target position."
    ]
    receipt[:recovery_guidance] = [
      "refresh Nado readback",
      "query accepted Nado digest/order/fills",
      "if Nado target remains absent and it is safe, reopen source venue"
    ]
    receipt[:recovery_command] = "bin/rails migration:reconcile_nado_source_first position_id=#{receipt[:position_id]} from=#{receipt[:from_venue]} to=#{receipt[:to_venue]} digest=#{receipt[:nado_target_digest]} dry_run=true"
    receipt[:random_and_auto_paused] = true
    receipt[:warnings] = (Array(receipt[:warnings]) + [
      "Source-first route closed source and Nado accepted a target digest, but target readback remained ambiguous after the bounded reconciliation window. No duplicate Nado target order was submitted."
    ]).uniq
  end

  def confirm_source_first_nado_target_by_canonical_readback(position:, receipt:)
    receipt[:nado_accept_at] ||= receipt[:target_leg_accepted_at]
    mark_time!(receipt, :nado_first_canonical_readback_started_at)
    result = NadoMigrationReadback.confirm_target_short(
      position: position,
      from: receipt[:from_venue],
      to: receipt[:to_venue],
      expected_target_short: receipt[:target_short],
      tolerance_eth: receipt[:tolerance_abs_eth],
      env: @env,
      attempts: nado_source_first_reconciliation_attempts,
      interval_seconds: nado_source_first_reconciliation_interval_seconds,
      sleeper: @sleeper,
      now: @now
    )
    mark_time!(receipt, :nado_canonical_readback_finished_at)
    receipt[:nado_source_first_canonical_readback] = result.except(:verification)
    receipt[:nado_source_first_canonical_verification] = result[:verification]
    receipt[:canonical_readback_attempts] = Array(result.dig(:verification, :attempts)).size
    receipt[:nado_accept_to_first_canonical_readback_seconds] = seconds_between(receipt[:nado_accept_at], receipt[:nado_first_canonical_readback_started_at])
    receipt[:source_flat_to_first_canonical_readback_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:nado_first_canonical_readback_started_at])
    if result[:confirmed]
      receipt[:first_confirming_readback_source] = result[:readback_source]
      receipt[:nado_accept_to_canonical_confirmed_seconds] = seconds_between(receipt[:nado_accept_at], result.dig(:latest_attempt, :timestamp) || receipt[:nado_canonical_readback_finished_at])
    end
    result
  end

  def confirm_source_first_nado_execution_by_digest(receipt:, target_leg:)
    digest = target_leg[:exchange_order_id] || receipt[:target_leg_digest_or_order_id]
    return { confirmed: false, blockers: [ "Nado target digest is unavailable for execution confirmation" ] } if digest.blank?

    mark_time!(receipt, :nado_digest_execution_lookup_started_at)
    result = NadoExecutionConfirmation.confirm_digest(
      digest: digest,
      product_id: NadoHedgeExecutionService::ETH_PERP_PRODUCT_ID,
      env: @env,
      now: @now
    )
    receipt[:nado_digest_execution_confirmation] = result
    result
  end

  def apply_source_first_nado_execution_confirmation!(receipt, confirmation)
    receipt[:nado_digest_execution_confirmed_at] = confirmation[:confirmed_at] || @now.call.utc.iso8601(6)
    receipt[:target_execution_confirmed_at] = receipt[:nado_digest_execution_confirmed_at]
    receipt[:target_confirmation_source] = confirmation[:source]
    receipt[:nado_accept_to_execution_confirmed_seconds] = seconds_between(receipt[:nado_accept_at] || receipt[:target_leg_accepted_at], receipt[:target_execution_confirmed_at])
    receipt[:source_flat_to_execution_confirmed_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:target_execution_confirmed_at])
    receipt[:underhedge_ended_at] = receipt[:target_execution_confirmed_at]
    compute_underhedge_latency!(receipt)
  end

  def source_first_nado_canonical_final_status(receipt)
    verification = receipt[:nado_source_first_canonical_verification]
    return nil unless receipt[:migration_sequence].to_s == "source_first" && verification&.fetch(:confirmed, false)
    return nil unless %i[latest_attempt source_flat target_confirmed third_venue_flat combined_inside_tolerance open_orders_clear].all? { |key| verification.key?(key) }

    final_readback_status_from_verification(receipt: receipt, verification: verification).merge(
      final_reconciliation: verification,
      final_reconciliation_status: "MIGRATION_CONFIRMED",
      final_status: "success",
      manual_action_required: false,
      blockers: []
    )
  end

  def mark_source_first_nado_target_confirmed_by_canonical_readback(target_leg, canonical)
    leg_receipt = (target_leg[:receipt] || {}).merge(
      reconciled_after_pending: true,
      readback_confirmed: true,
      pending_reconciliation_readback: canonical[:latest_attempt],
      pending_reconciliation_confirmation: {
        confirmed: true,
        actual_short_eth: canonical[:target_short_eth],
        expected_short_eth: canonical[:expected_target_short_eth],
        route_tolerance_eth: canonical[:tolerance_eth],
        confirmed_by_route_tolerance: canonical[:target_confirmed]
      },
      final_status: "SOURCE_FIRST_TARGET_CONFIRMED_BY_CANONICAL_READBACK",
      lifecycle_state: "NADO_TARGET_CONFIRMED_LATE"
    )
    target_leg.merge(
      status: "confirmed_by_canonical_nado_readback",
      confirmed: true,
      readback: canonical[:latest_attempt],
      receipt: leg_receipt,
      blockers: []
    )
  end

  def annotate_source_first_nado_timing!(receipt, target_leg_plan)
    return unless source_first_nado_target?(receipt, target_leg_plan)

    receipt[:source_flat_to_nado_submit_started_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:target_leg_submit_started_at])
    receipt[:source_flat_to_nado_submit_finished_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:target_leg_submit_finished_at])
    receipt[:nado_submit_to_accept_seconds] = seconds_between(receipt[:target_leg_submit_started_at], receipt[:target_leg_accepted_at])
    receipt[:nado_accept_to_first_readback_seconds] = seconds_between(receipt[:target_leg_accepted_at], receipt[:target_readback_started_at])
    receipt[:nado_accept_to_confirmed_seconds] = seconds_between(receipt[:target_leg_accepted_at], receipt[:target_readback_confirmed_at])
    receipt[:target_accept_to_confirmed_seconds] = receipt[:nado_accept_to_confirmed_seconds]
    receipt[:source_flat_to_target_confirmed_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:target_readback_confirmed_at])
    receipt[:source_flat_to_position_confirmed_seconds] = receipt[:source_flat_to_target_confirmed_seconds]
    receipt[:source_flat_to_finalized_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:target_readback_confirmed_at])
  end

  def nado_source_first_reconciliation_attempts
    [ @env.fetch("NADO_SOURCE_FIRST_RECONCILIATION_ATTEMPTS", "60").to_i, 1 ].max
  end

  def nado_source_first_reconciliation_interval_seconds
    decimal_env("NADO_SOURCE_FIRST_RECONCILIATION_INTERVAL_SECONDS", "1")
  end

  def nado_source_first_max_confirmation_seconds
    decimal_env("NADO_SOURCE_FIRST_MAX_CONFIRMATION_SECONDS", "75")
  end

  def target_confirm_to_source_close_exceeds_threshold?(receipt)
    latency = seconds_between(receipt[:target_readback_confirmed_at], @now.call.utc.iso8601(6))
    latency && BigDecimal(latency.to_s) > target_to_source_close_latency_threshold_seconds
  end

  def target_to_source_close_latency_threshold_seconds
    BigDecimal(@env.fetch("MIGRATION_TARGET_TO_SOURCE_CLOSE_MAX_LATENCY_SECONDS", "10").to_s)
  rescue ArgumentError
    BigDecimal("10")
  end

  def seconds_between(start_at, finish_at)
    return nil if start_at.blank? || finish_at.blank?

    (Time.zone.parse(finish_at.to_s) - Time.zone.parse(start_at.to_s)).round(6)
  rescue ArgumentError, TypeError
    nil
  end

  def target_leg_confirmed_for_source_close?(position:, receipt:, first_leg:, first_planned_leg:)
    return false unless first_planned_leg.fetch(:venue) == receipt[:to_venue]
    return false unless leg_order_count(first_leg).positive?

    readback_short = target_short_from_readback(first_leg[:readback])
    if target_short_matches?(readback_short, receipt)
      mark_time!(receipt, :target_readback_confirmed_at)
      receipt[:target_continuation_readback] = { source: "first_leg_readback", target_confirmed: true, target_short_eth: readback_short.to_s("F") }
      return true
    end

    verification = final_verifier(position: position, receipt: receipt).verify
    receipt[:target_continuation_verification] = verification
    latest = verification.fetch(:latest_attempt)
    if verification[:target_confirmed]
      receipt[:target_readback_confirmed_at] = latest[:timestamp] || @now.call.utc.iso8601(6)
      receipt[:target_continuation_readback] = {
        source: latest[:readback_source],
        target_confirmed: true,
        target_short_eth: latest[:target_venue_short_eth],
        source_short_eth: latest[:source_short_eth],
        third_venue_shorts: latest[:third_venue_shorts],
        open_orders_count: latest[:open_orders_count]
      }
      return true
    end

    false
  end

  def stop_after_unconfirmed_first_leg(position:, receipt:, first_leg:, first_planned_leg:)
    receipt[:orders_placed] = leg_order_count(first_leg)
    receipt[:orders_submitted] = receipt[:orders_placed]
    receipt[:signatures_created] = leg_signature_count(first_leg)
    receipt[:exchange_order_ids] = [ first_leg[:exchange_order_id] ].compact
    receipt[:submitted] = receipt[:orders_placed].positive?
    receipt[:would_execute_live] = receipt[:submitted]
    receipt[:lifecycle_state] = receipt[:orders_placed].positive? ? "TARGET_SUBMITTED_PENDING_READBACK" : "TARGET_REJECTED_OR_NOT_CONFIRMED"
    target_leg = first_planned_leg.fetch(:venue) == receipt[:to_venue]
    if target_leg && receipt[:orders_placed].positive?
      apply_nado_manual_action_digest!(receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
      apply_target_open_source_still_open_manual_action!(
        position,
        receipt,
        Array(first_leg[:blockers]).presence || [ "Target leg was submitted but target readback did not confirm enough to safely close source." ]
      )
    elsif target_leg && indeterminate_target_leg_failure?(first_leg)
      # A timeout / connection error during the target submit means the order's
      # fate is UNKNOWN, not "definitely not filled": the request may have
      # reached the venue and filled even though no confirmation came back. We
      # must NOT treat this as a clean rejection (which would leave a
      # possibly-live target leg unmanaged next to the still-open source). Do an
      # authoritative target-venue position readback and fail closed.
      classify_indeterminate_target_leg!(position: position, receipt: receipt, first_leg: first_leg)
    else
      receipt[:final_status] = "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:blockers] = Array(first_leg[:blockers]).presence || [ "First migration leg was not confirmed; second leg was not submitted." ]
      receipt[:manual_action_required] = true
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  # A target leg whose submit raised (DefaultLegRunner rescues every exception
  # into status "failed_before_submit"), errored at the venue ("submit_failed",
  # e.g. HTTP 503), or whose blockers name a timeout / socket / HTTP-5xx error is
  # INDETERMINATE: we cannot conclude the order failed to reach the venue. A
  # clean venue-side rejection, by contrast, returns normally and carries no
  # such blocker.
  INDETERMINATE_LEG_FAILURE_PATTERN = /timeout|timed out|ReadTimeout|OpenTimeout|WriteTimeout|execution expired|EOFError|Errno::|ECONNRESET|connection reset|connection refused|broken pipe|Net::|HTTP 5\d\d|submit failed|acceptance unknown/i
  INDETERMINATE_LEG_FAILURE_STATUSES = %w[failed_before_submit submit_failed].freeze
  INDETERMINATE_TARGET_FLAT_EPSILON = BigDecimal("0.001")

  def indeterminate_target_leg_failure?(leg)
    return true if INDETERMINATE_LEG_FAILURE_STATUSES.include?(leg[:status].to_s)

    Array(leg[:blockers]).any? { |blocker| blocker.to_s.match?(INDETERMINATE_LEG_FAILURE_PATTERN) }
  end

  def classify_indeterminate_target_leg!(position:, receipt:, first_leg:)
    receipt[:target_confirmation_timed_out] = true
    target_short = authoritative_target_short(position: position, receipt: receipt)
    receipt[:target_authoritative_readback_short_eth] = target_short&.to_s("F")
    base_blockers = Array(first_leg[:blockers])

    if target_short.nil?
      # The authoritative readback itself is unavailable — we cannot prove the
      # target is flat, so we fail closed and treat it as a possible double
      # exposure requiring recovery.
      receipt[:target_possibly_live] = true
      receipt[:target_leg_status] = "TARGET_CONFIRMATION_TIMEOUT"
      apply_target_open_source_still_open_manual_action!(
        position,
        receipt,
        (base_blockers + [ "Target leg submit timed out and the authoritative target readback is unavailable; the target may be live. Fail-closed: treat as possible double exposure until recovery confirms the actual state." ]).uniq
      )
    elsif target_short > INDETERMINATE_TARGET_FLAT_EPSILON
      # The target venue actually holds a short: the order filled despite the
      # inline confirmation timing out.
      receipt[:target_possibly_live] = true
      receipt[:target_leg_status] = "TARGET_FILLED_CONFIRMATION_UNKNOWN"
      apply_target_open_source_still_open_manual_action!(
        position,
        receipt,
        (base_blockers + [ "Target leg submit timed out but the authoritative readback shows #{receipt[:to_venue]} holds #{target_short.to_s('F')} ETH short; the target filled with an unconfirmed inline confirmation. Source is still open." ]).uniq
      )
    else
      # The authoritative readback proves the target venue is flat: the order did
      # not reach the venue, so a clean abort that preserves the source is safe.
      receipt[:target_leg_status] = "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:lifecycle_state] = "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:final_status] = "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:blockers] = (base_blockers + [ "Target leg submit timed out; the authoritative readback confirms #{receipt[:to_venue]} is flat, so the source is preserved and no double exposure exists." ]).uniq
      receipt[:manual_action_required] = true
    end
  end

  # Fresh authoritative read of the target venue short. Returns a BigDecimal, or
  # nil when the read itself is unavailable (so callers can fail closed).
  def authoritative_target_short(position:, receipt:)
    verification = final_verifier(position: position, receipt: receipt).verify
    receipt[:target_timeout_reconciliation] = verification
    latest = verification.fetch(:latest_attempt)
    return nil if latest[:readback_source].to_s == "venue_readback_error"

    raw = latest[:target_venue_short_eth]
    return nil if raw.nil?

    BigDecimal(raw.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def apply_target_open_source_still_open_manual_action!(position, receipt, blockers)
    pause_autonomous_migration!(position, receipt)
    receipt[:final_status] = "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN"
    receipt[:lifecycle_state] = "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN"
    receipt[:manual_action_required] = true
    receipt[:blockers] = Array(blockers).uniq
    receipt[:recommended_action] = "close source venue reduce-only"
    receipt[:source_venue] = receipt[:from_venue]
    receipt[:target_venue] = receipt[:to_venue]
    receipt[:target_order_id] = target_open_order_id(receipt)
    receipt[:recovery_command] = recovery_command(receipt)
    receipt[:recovery_options] = recovery_options(receipt)
    receipt[:random_and_auto_paused] = true
    receipt[:warnings] = (Array(receipt[:warnings]) + [
      "Target-first migration has target exposure with source not confirmed flat; autonomous random/auto loops paused until recovery finalizes."
    ]).uniq
  end

  def apply_nado_manual_action_digest!(receipt, first_leg:, first_planned_leg:)
    return unless first_planned_leg.fetch(:venue) == "nado"
    return unless first_planned_leg.fetch(:venue) == receipt[:to_venue]

    receipt[:nado_target_digest] = first_leg[:exchange_order_id]
    receipt[:nado_target_exchange_order_id] = first_leg[:exchange_order_id]
    receipt[:target_confirmation_attempts] = first_leg.dig(:receipt, :migration_target_reconciliation_attempts) || []
    receipt[:pending_migration_id] = Digest::SHA256.hexdigest([ receipt[:position_id], receipt[:from_venue], receipt[:to_venue], first_leg[:exchange_order_id] ].join(":"))[0, 16]
  end

  def target_short_from_readback(readback)
    payload = readback.is_a?(Array) ? readback.last : readback
    return nil unless payload.respond_to?(:dig)

    value = payload[:short_size] || payload["short_size"] ||
      payload[:current_short_eth] || payload["current_short_eth"] ||
      payload[:actual_short_eth] || payload["actual_short_eth"]
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def target_short_matches?(actual, receipt)
    return false unless actual

    expected = decimal(receipt[:target_short])
    tolerance = [ decimal(receipt[:tolerance_abs_eth]), MigrationTargetFirstFinalVerifier::FLAT_TOLERANCE_ETH ].max
    expected.positive? && (actual - expected).abs <= tolerance
  end

  # Records which venue autos were enabled before the defensive pause so the
  # receipt shows what a safe recovery must restore (the runner re-asserts the
  # active venue's auto once recovery reconciles safe; without that the active
  # venue loses its hold rebalance and the runner stops on the next drift).
  def pause_autonomous_migration!(position, receipt = nil)
    previously_enabled = OperationalSettings::AUTO_KEYS_BY_VENUE.values.select do |key|
      OperationalSettings.enabled?(key, env: @env)
    end
    ActiveVenueAutoPolicy.new(position: position).disable_all!(reason: "migration executor pauses after target-open source-still-open manual action")
    %w[MIGRATION_AUTO_ENABLED MIGRATION_RANDOM_ROTATION_LIVE_ENABLED].each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "migration executor pauses after target-open source-still-open manual action")
    end
    receipt[:defensively_paused_venue_autos] = previously_enabled if receipt
  end

  def live_blockers(position:, receipt:, dry_run:, confirmation:, execution_preflight: nil)
    return [] if dry_run
    return [] if execution_preflight.is_a?(Hash) && execution_preflight[:accepted] == false

    direct = accepted_execution_preflight(execution_preflight)
    blockers = []
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "Nado must be flat before dashboard migration." if ![ receipt[:from_venue], receipt[:to_venue] ].include?("nado") && !nado_flat?(position.position_dashboard_snapshot, direct)
    blockers << "position hedge execution_venue must be #{receipt[:from_venue]} before migration" unless HedgeVenues.normalize(position.hedge&.execution_venue) == receipt[:from_venue]
    blockers << "#{HedgeVenues.label(receipt[:from_venue])} live gate must be enabled." unless venue_live_enabled?(receipt[:from_venue])
    blockers << "#{HedgeVenues.label(receipt[:to_venue])} live gate must be enabled." unless venue_live_enabled?(receipt[:to_venue])
    blockers << "#{HedgeVenues.label(receipt[:from_venue])} auto must be disabled during migration." if venue_auto_enabled?(receipt[:from_venue])
    blockers << "#{HedgeVenues.label(receipt[:to_venue])} auto must be disabled during migration." if venue_auto_enabled?(receipt[:to_venue])
    blockers << "target venue readiness failed or is not cached." unless target_readiness_cached?(position.position_dashboard_snapshot, receipt[:to_venue], direct)
    blockers << "source current position must exist." unless decimal(receipt[:from_short_before]).positive?
    blockers << "target/source open orders must be zero." unless open_orders_clear?(position.position_dashboard_snapshot, receipt[:from_venue], receipt[:to_venue], direct)
    blockers << "dashboard snapshot must be fresh immediately before live migration." if direct.blank? && position.position_dashboard_snapshot&.stale_now?
    blockers.concat(recent_rebalance_blockers(position, receipt[:from_venue], receipt[:to_venue]))
    blockers
  end

  def accepted_execution_preflight(report)
    return nil unless report.is_a?(Hash) && report[:accepted] == true

    report
  end

  def target_readiness_cached?(snapshot, venue, direct = nil)
    return true if direct && direct.dig(:venues, venue, :position_status).to_s == "ok"
    return false unless snapshot
    return true if venue == "ethereal"
    return true if venue == "nado"
    return false unless venue == "extended"

    snapshot.open_orders_count_extended.to_i.zero? && snapshot.leverage_margin_gate_status.to_s.in?(%w[ok pass passed ready confirmed])
  end

  def open_orders_clear?(snapshot, from, to, direct = nil)
    if direct
      return [ from, to ].all? { |venue| direct.dig(:venues, venue, :open_orders_status).to_s == "zero" }
    end
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

  def venue_auto_enabled?(venue)
    key = OperationalSettings.auto_key_for(venue)
    return true unless key

    bool_env(key)
  end

  def recent_rebalance_blockers(position, from, to)
    return [] unless position.hedge

    venues = [ from, to ]
    pending = position.hedge.short_rebalances.where(venue: venues, status: ShortRebalance::STATUS_PENDING).order(created_at: :desc).find do |rebalance|
      rebalance.venue == "nado" ? NadoStalePendingRebalanceResolver.new.active_pending?(rebalance, position: position) : true
    end
    blockers = []
    blockers << "pending #{HedgeVenues.label(pending.venue)} ShortRebalance ##{pending.id} must be resolved before migration." if pending
    recent = position.hedge.short_rebalances.where(venue: venues).where("created_at >= ?", 2.minutes.ago).order(created_at: :desc).first
    blockers << "recent #{HedgeVenues.label(recent.venue)} ShortRebalance ##{recent.id} is too recent for migration; refresh and retry after the guard window." if recent
    blockers
  end

  def nado_flat?(snapshot, direct = nil)
    return decimal(direct.dig(:venues, "nado", :short_eth)).zero? if direct

    snapshot && BigDecimal(snapshot.nado_short_eth.to_s).zero?
  rescue ArgumentError
    false
  end

  def final_readback_status(position:, receipt:)
    verification = final_verifier(position: position, receipt: receipt).verify
    final_readback_status_from_verification(receipt: receipt, verification: verification)
  end

  def final_readback_status_from_verification(receipt:, verification:)
    latest = verification.fetch(:latest_attempt)
    from_after = decimal(latest[:source_short_eth])
    to_after = decimal(latest[:target_venue_short_eth])
    combined = decimal(latest[:combined_short_eth])
    target = decimal(latest[:expected_target_short_eth])
    drift = target - combined
    source_flat = verification.fetch(:source_flat)
    target_holds = verification.fetch(:target_confirmed)
    third_venue_flat = verification.fetch(:third_venue_flat)
    open_orders_clear = verification.fetch(:open_orders_clear)
    inside = verification.fetch(:combined_inside_tolerance)
    full = receipt[:mode].to_s == "full" || ActiveModel::Type::Boolean.new.cast(receipt[:full_migration_allowed])
    success = !full || (source_flat && target_holds && third_venue_flat && inside && open_orders_clear)
    {
      from_short_after_readback: from_after.to_s("F"),
      to_short_after_readback: to_after.to_s("F"),
      final_combined: combined.to_s("F"),
      final_drift: drift.to_s("F"),
      source_flat_confirmed: source_flat,
      source_flat_after: source_flat,
      target_holds_hedge_confirmed: target_holds,
      target_holds_expected_short: target_holds,
      third_venue_flat: third_venue_flat,
      final_inside_tolerance: inside,
      open_orders_after: latest[:open_orders_count].to_i,
      open_orders_clear_after: open_orders_clear,
      final_reconciliation: verification,
      final_reconciliation_status: success ? (verification.fetch(:attempts).size > 1 ? "MIGRATION_CONFIRMED_LATE" : "MIGRATION_CONFIRMED") : "FINAL_READBACK_RECHECK_REQUIRED",
      finalize_available: success && full,
      final_status: success ? "success" : "FINAL_READBACK_RECHECK_REQUIRED",
      manual_action_required: !success,
      recovery_command: success ? nil : recovery_command(receipt),
      blockers: success ? [] : Array(verification[:blockers]).presence || [ "Final migration readback did not confirm source flat, target hedge, third venue flat, zero open orders, and combined exposure inside tolerance." ]
    }
  end

  def apply_nado_target_continuation!(receipt, first_leg:, first_planned_leg:)
    return unless first_planned_leg.fetch(:venue) == "nado"
    return unless first_planned_leg.fetch(:venue) == receipt[:to_venue]
    return unless leg_order_count(first_leg).positive?

    receipt[:final_status] = "TARGET_ACCEPTED_AWAITING_CONTINUATION"
    receipt[:lifecycle_state] = "TARGET_SUBMITTED_PENDING_READBACK"
    receipt[:nado_target_digest] = first_leg[:exchange_order_id]
    receipt[:nado_target_exchange_order_id] = first_leg[:exchange_order_id]
    receipt[:target_confirmation_attempts] = first_leg.dig(:receipt, :migration_target_reconciliation_attempts) || []
    receipt[:continuation_pending] = true
    receipt[:pending_migration_id] = Digest::SHA256.hexdigest([ receipt[:position_id], receipt[:from_venue], receipt[:to_venue], first_leg[:exchange_order_id] ].join(":"))[0, 16]
    receipt[:continuation_command] = "bin/rails migration:continue_target_first_after_nado_confirmed position_id=#{receipt[:position_id]} from=#{receipt[:from_venue]} to=#{receipt[:to_venue]} dry_run=true"
    receipt[:source_close_plan] = receipt[:planned_second_leg]
  end

  def final_verifier(position:, receipt:)
    if @final_verifier_factory
      return @final_verifier_factory.call(position: position, receipt: receipt)
    end

    MigrationTargetFirstFinalVerifier.new(
      position: position,
      from: receipt.fetch(:from_venue),
      to: receipt.fetch(:to_venue),
      expected_target_short: receipt[:target_short],
      tolerance_eth: receipt[:tolerance_abs_eth],
      env: @env,
      attempts: @final_reconciliation_attempts,
      interval_seconds: @final_reconciliation_interval,
      sleeper: @sleeper,
      now: @now
    )
  end

  def finalize_production_venue(position, receipt)
    return unless position.hedge

    position.hedge.update!(execution_venue: receipt[:to_venue])
    ActiveVenueAutoPolicy.new(position: position).enable_venue!(
      venue: receipt[:to_venue],
      reason: "migration executor finalized production venue"
    )
    receipt[:production_venue_finalized] = true
    mark_time!(receipt, :production_venue_finalized_at)
    receipt[:source_flat_to_finalized_seconds] = seconds_between(receipt[:source_close_flat_confirmed_at], receipt[:production_venue_finalized_at]) if receipt[:migration_sequence].to_s == "source_first"
    receipt[:finalized_hedge_id] = position.hedge.id
  end

  def pause_active_auto(position)
    ActiveVenueAutoPolicy.new(position: position).disable_all!(
      reason: "migration executor pauses venue auto during migration"
    )
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: @env) if OperationalSettings.allowed_key?(key)

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

  def revert_recovery_command(receipt)
    "bin/rails migration:revert_target_first_target_close position_id=#{receipt[:position_id]} from=#{receipt[:from_venue]} to=#{receipt[:to_venue]} dry_run=true"
  end

  # The three operator choices for a target-first cycle that left the target
  # possibly live with the source still open. The runner surfaces these; nothing
  # is executed autonomously.
  def recovery_options(receipt)
    [
      { option: "A", action: "complete_migration", reduce_only: true,
        description: "Confirm the target is filled and inside tolerance, then close the source reduce-only and finalize the production venue to #{receipt[:to_venue]}.",
        command: recovery_command(receipt) },
      { option: "B", action: "revert_migration", reduce_only: true,
        description: "Close the target (#{receipt[:to_venue]}) reduce-only and keep the source (#{receipt[:from_venue]}) as the production venue.",
        command: revert_recovery_command(receipt) },
      { option: "C", action: "no_op", reduce_only: nil,
        description: "If the authoritative readback proves the target never filled, keep the source and take no action." }
    ]
  end

  def target_open_order_id(receipt)
    receipt[:nado_target_exchange_order_id] ||
      Array(receipt[:exchange_order_ids]).compact.first ||
      receipt.dig(:to_leg_execution, :exchange_order_id)
  end

  def leg_order_count(leg)
    leg[:orders_placed].to_i
  end

  def leg_signature_count(leg)
    leg[:signatures_created].to_i
  end

  def write_receipt(receipt)
    annotate_migration_latency!(receipt)
    @receipt_writer.write(sanitize_sensitive(receipt))
  end

  def annotate_migration_latency!(receipt)
    receipt[:route] ||= "#{receipt[:from_venue]}->#{receipt[:to_venue]}"
    receipt[:target_venue] ||= receipt[:to_venue]
    receipt[:source_venue] ||= receipt[:from_venue]
    receipt[:source_close_submit_start_after_target_confirm_seconds] ||= receipt[:target_confirm_to_source_close_submit_latency_seconds]
    started_at = receipt[:migration_sequence] == "source_first" ? receipt[:source_close_submit_started_at] : receipt[:target_leg_submit_started_at]
    ended_at = if receipt[:migration_sequence] == "source_first"
      receipt[:target_readback_confirmed_at] || receipt[:target_leg_submit_finished_at]
    else
      receipt[:source_close_flat_confirmed_at] || receipt[:source_close_submit_finished_at] || receipt[:target_leg_submit_finished_at]
    end
    receipt[:total_migration_latency_seconds] ||= seconds_between(
      started_at,
      ended_at
    )
    exceeded = latency_threshold_exceeded_entries(receipt)
    return if exceeded.empty?

    receipt[:latency_threshold_exceeded] = true
    receipt[:latency_thresholds_exceeded] = exceeded
    receipt[:warnings] = (Array(receipt[:warnings]) + exceeded.map do |entry|
      "LATENCY_THRESHOLD_EXCEEDED: #{entry[:field]} #{entry[:actual_seconds]}s > #{entry[:threshold_seconds]}s"
    end).uniq
  end

  def latency_threshold_exceeded_entries(receipt)
    [
      latency_threshold_entry(receipt, :target_total_latency_seconds, max_target_leg_latency_seconds),
      latency_threshold_entry(receipt, :source_close_total_latency_seconds, max_source_close_latency_seconds),
      latency_threshold_entry(receipt, :total_migration_latency_seconds, max_total_route_latency_seconds),
      latency_threshold_entry(receipt, :target_confirm_to_source_close_submit_latency_seconds, target_to_source_close_latency_threshold_seconds)
    ].compact
  end

  def latency_threshold_entry(receipt, field, threshold)
    actual = receipt[field]
    return nil if actual.blank?

    actual_decimal = BigDecimal(actual.to_s)
    return nil unless actual_decimal > threshold

    { field: field, actual_seconds: actual_decimal.to_s("F"), threshold_seconds: threshold.to_s("F") }
  rescue ArgumentError
    nil
  end

  def max_target_leg_latency_seconds
    decimal_env("MIGRATION_MAX_TARGET_LEG_LATENCY_SECONDS", "15")
  end

  def max_source_close_latency_seconds
    decimal_env("MIGRATION_MAX_SOURCE_CLOSE_LATENCY_SECONDS", "15")
  end

  def max_total_route_latency_seconds
    decimal_env("MIGRATION_MAX_TOTAL_ROUTE_LATENCY_SECONDS", "45")
  end

  def decimal_env(key, default)
    BigDecimal(@env.fetch(key, default).to_s)
  rescue ArgumentError
    BigDecimal(default)
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
