require "digest"

class HedgeVenueMigrationExecutor
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_MIGRATES_HEDGE_BETWEEN_VENUES".freeze

  def initialize(env: ENV, planner: HedgeVenueMigrationPlanner.new, leg_runner: nil, now: -> { Time.current }, snapshot_refresher: nil, receipt_writer: nil, final_verifier_factory: nil, final_reconciliation_attempts: nil, final_reconciliation_interval: nil, sleeper: ->(seconds) { sleep(seconds) })
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
  end

  def run(position:, from_venue:, to_venue:, mode: "preview", dry_run: true, confirmation: nil, step_size_eth: nil, full_migration_allowed: false, migration_sequence: HedgeVenueMigrationPlanner::DEFAULT_SEQUENCE, execution_preflight: nil)
    refreshed_snapshot = nil
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
    receipt[:lifecycle_state] = "READY_FOR_TARGET_FIRST"
    mark_time!(receipt, :target_leg_submit_started_at)
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :target_leg_submit_finished_at)
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    record_target_acceptance_timing!(receipt, first_leg, first_planned_leg)
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
      mark_time!(receipt, :source_close_flat_confirmed_at) if receipt[:source_flat_after]
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
      return run_extended_source_close_leg(leg, context) if close_to_flat_leg?(leg)

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
        service.rebalance_short(position: context.fetch(:position), delta_eth: -size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
      end
      normalize_service_result(result, leg)
    end

    def run_extended_source_close_leg(leg, context)
      size = BigDecimal(leg.fetch(:size_eth).to_s)
      env = @env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => size.to_s("F"))
      venue = @venue_builder.build("extended", env: env)
      service = ExtendedHedgeExecutionService.new(venue: venue)
      current = venue.read_position(symbol: "ETH")
      result = service.close_short(position: context.fetch(:position), size_eth: size, current_position: current, confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION, max_slippage: max_slippage)
      normalize_service_result(result, leg)
    end

    def close_to_flat_leg?(leg)
      leg.fetch(:side) == "buy" && BigDecimal(leg.fetch(:expected_after_short_eth).to_s).zero?
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
      attempts_limit = nado_target_reconciliation_attempts(context)
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
    mark_time!(receipt, :target_leg_submit_started_at)
    first_leg = @leg_runner.call(first_planned_leg, context: leg_context(position, confirmation, receipt))
    mark_time!(receipt, :target_leg_submit_finished_at)
    receipt[:first_leg_execution] = sanitize_sensitive(first_leg)
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:to_venue]
    receipt[:from_leg_execution] = sanitize_sensitive(first_leg) if first_planned_leg.fetch(:venue) == receipt[:from_venue]
    receipt[:leg_readbacks] << first_leg[:readback] if first_leg[:readback]
    record_target_acceptance_timing!(receipt, first_leg, first_planned_leg)
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
      mark_time!(receipt, :source_close_flat_confirmed_at) if receipt[:source_flat_after]
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

  def record_target_acceptance_timing!(receipt, leg, planned_leg)
    return unless planned_leg.fetch(:venue) == receipt[:to_venue]
    return unless leg_order_count(leg).positive?

    timing = leg[:timing] || {}
    receipt[:target_action_timing] = timing if timing.present?
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

  def double_exposure_exceeds_threshold?(receipt)
    seconds = receipt[:double_exposure_seconds]
    seconds.present? && BigDecimal(seconds.to_s) > max_double_exposure_seconds
  rescue ArgumentError
    false
  end

  def max_double_exposure_seconds
    decimal_env("MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS", "10")
  end

  def apply_latency_incident!(position, receipt)
    pause_autonomous_migration!(position)
    receipt[:final_status] = "NOT_PRODUCTION_SAFE_LATENCY"
    receipt[:lifecycle_state] = "NOT_PRODUCTION_SAFE_LATENCY"
    receipt[:manual_action_required] = true
    receipt[:latency_incident] = true
    receipt[:production_safe_route] = false
    receipt[:route_production_safe] = false
    receipt[:blockers] = [ "double exposure lasted #{receipt[:double_exposure_seconds]}s, exceeding MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS=#{max_double_exposure_seconds.to_s('F')}" ]
    receipt[:recovery_command] ||= recovery_command(receipt)
    receipt[:random_and_auto_paused] = true
    receipt[:warnings] = (Array(receipt[:warnings]) + [
      "Route finalized safely but source close was too slow for production random; route must be re-proven with acceptable double-exposure latency."
    ]).uniq
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
    if first_planned_leg.fetch(:venue) == receipt[:to_venue] && receipt[:orders_placed].positive?
      apply_nado_manual_action_digest!(receipt, first_leg: first_leg, first_planned_leg: first_planned_leg)
      apply_target_open_source_still_open_manual_action!(
        position,
        receipt,
        Array(first_leg[:blockers]).presence || [ "Target leg was submitted but target readback did not confirm enough to safely close source." ]
      )
    else
      receipt[:final_status] = "TARGET_REJECTED_OR_NOT_CONFIRMED"
      receipt[:blockers] = Array(first_leg[:blockers]).presence || [ "First migration leg was not confirmed; second leg was not submitted." ]
      receipt[:manual_action_required] = true
    end
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  def apply_target_open_source_still_open_manual_action!(position, receipt, blockers)
    pause_autonomous_migration!(position)
    receipt[:final_status] = "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN"
    receipt[:lifecycle_state] = "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN"
    receipt[:manual_action_required] = true
    receipt[:blockers] = Array(blockers).uniq
    receipt[:recommended_action] = "close source venue reduce-only"
    receipt[:source_venue] = receipt[:from_venue]
    receipt[:target_venue] = receipt[:to_venue]
    receipt[:recovery_command] = recovery_command(receipt)
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

  def pause_autonomous_migration!(position)
    ActiveVenueAutoPolicy.new(position: position).disable_all!(reason: "migration executor pauses after target-open source-still-open manual action")
    %w[MIGRATION_AUTO_ENABLED MIGRATION_RANDOM_ROTATION_LIVE_ENABLED].each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "migration executor pauses after target-open source-still-open manual action")
    end
  end

  def live_blockers(position:, receipt:, dry_run:, confirmation:, execution_preflight: nil)
    return [] if dry_run

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
    receipt[:total_migration_latency_seconds] ||= seconds_between(
      receipt[:target_leg_submit_started_at],
      receipt[:source_close_flat_confirmed_at] || receipt[:source_close_submit_finished_at] || receipt[:target_leg_submit_finished_at]
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
