class MigrationRandomBurnInRunner
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_30_MIN_LIVE_RANDOM_BURN_IN".freeze
  LOG_DIR = Rails.root.join("storage/random_rotation_burn_in")
  VENUES = %w[extended ethereal nado].freeze
  BASIC_SUCCESS_STATUSES = %w[success MIGRATION_FINALIZED].freeze
  SOURCE_FIRST_NADO_FINALIZED_STATUSES = %w[
    SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK
    SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK
  ].freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt_path, :summary)

  def initialize(position:, duration_minutes:, interval_seconds:, max_cycles:, live: false, disable_after: true,
                 confirmation: nil, env: ENV, proof_registry: nil, executor_factory: nil, now: -> { Time.current },
                 sleeper: ->(seconds) { sleep(seconds) }, selector: nil, log_dir: LOG_DIR, stdout: $stdout,
                 readiness_factory: nil, snapshot_refresher: nil, rebalance_before_cycle: false,
                 max_target_change_per_cycle_eth: "0.15", preflight_factory: nil,
                 burn_in_tolerance_multiplier: "1.0", burn_in_extra_tolerance_eth: "0",
                 burn_in_max_allowed_drift_eth: "0.15", burn_in_max_allowed_drift_ratio: "0.08",
                 rebalance_after_migration: true, rebalance_during_hold: false,
                 rebalance_hold_interval_seconds: 300, rebalance_before_next_migration: true,
                 rebalance_only_if_outside_tolerance: true, rebalance_max_attempts_per_cycle: 2,
                 rebalance_readback_recheck_attempts: 4, rebalance_readback_recheck_interval_seconds: 5,
                 active_rebalance_factory: nil, event_callback: nil, stop_requested: nil,
                 hold_monitor_warning_grace_seconds: 5)
    @position = position
    @duration_minutes = duration_minutes.to_i
    @interval_seconds = interval_seconds.to_i
    @max_cycles = max_cycles.to_i
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @disable_after = ActiveModel::Type::Boolean.new.cast(disable_after)
    @confirmation = confirmation.to_s
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @executor_factory = executor_factory
    @now = now
    @sleeper = sleeper
    @selector = selector
    @log_dir = Pathname(log_dir)
    @stdout = stdout
    @readiness_factory = readiness_factory
    @snapshot_refresher = snapshot_refresher
    @preflight_factory = preflight_factory
    @rebalance_before_cycle = ActiveModel::Type::Boolean.new.cast(rebalance_before_cycle)
    @max_target_change_per_cycle_eth = decimal(max_target_change_per_cycle_eth)
    @burn_in_tolerance_multiplier = decimal(burn_in_tolerance_multiplier)
    @burn_in_extra_tolerance_eth = decimal(burn_in_extra_tolerance_eth)
    @burn_in_max_allowed_drift_eth = decimal(burn_in_max_allowed_drift_eth)
    @burn_in_max_allowed_drift_ratio = decimal(burn_in_max_allowed_drift_ratio)
    @rebalance_after_migration = ActiveModel::Type::Boolean.new.cast(rebalance_after_migration)
    @rebalance_during_hold = ActiveModel::Type::Boolean.new.cast(rebalance_during_hold)
    @rebalance_hold_interval_seconds = rebalance_hold_interval_seconds.to_i
    @rebalance_before_next_migration = ActiveModel::Type::Boolean.new.cast(rebalance_before_next_migration)
    @rebalance_only_if_outside_tolerance = ActiveModel::Type::Boolean.new.cast(rebalance_only_if_outside_tolerance)
    @rebalance_max_attempts_per_cycle = rebalance_max_attempts_per_cycle.to_i
    @rebalance_readback_recheck_attempts = rebalance_readback_recheck_attempts.to_i
    @rebalance_readback_recheck_interval_seconds = rebalance_readback_recheck_interval_seconds.to_i
    @active_rebalance_factory = active_rebalance_factory
    @event_callback = event_callback
    @stop_requested = stop_requested
    @hold_monitor_warning_grace_seconds = hold_monitor_warning_grace_seconds.to_i
    @orders_submitted = 0
    @orders_placed = 0
    @signatures_created = 0
    @cycles_attempted = 0
    @cycles_succeeded = 0
    @initial_target_short_eth = nil
    @final_target_short_eth = nil
    @max_target_delta_eth = BigDecimal("0")
    @target_refresh_failures = 0
    @last_readiness_report = {}
    @snapshot_refresh_status = nil
    @snapshot_accepted_for_burn_in = false
    @snapshot_warnings = []
    @snapshot_blockers = []
    @last_direct_preflight_report = {}
    @last_blocker_status = nil
    @last_manual_action_execution = nil
    @last_manual_action_route = nil
    @started_at = @now.call
    @receipt_path = @log_dir.join("#{@started_at.utc.strftime('%Y%m%d_%H%M%S')}_position_#{position.id}.jsonl")
  end

  def run
    prepare_log!
    return stopped_before_start if stop_requested?

    start_blockers = preflight_blockers
    pre_start_rebalance = nil
    if pre_start_rebalance_allowed?(start_blockers)
      return stopped_before_start if stop_requested?

      pre_start_rebalance = run_active_rebalance(reason: "pre_start")
      accumulate_rebalance_counts(pre_start_rebalance)
      return stopped_before_start if stop_requested?

      start_blockers = pre_start_blockers_after_rebalance(start_blockers, pre_start_rebalance)
    end
    if start_blockers.any?
      write_event(readiness_diagnostics.merge(event: "burn_in_start", status: "blocked_before_start", blocker_status: preflight_status(start_blockers), blockers: start_blockers, pre_start_rebalance: pre_start_rebalance || unchecked_rebalance_payload("pre_start")))
      disable_after_run if disable_after && pre_start_rebalance
      finish(status: "blocked", blockers: start_blockers)
      return result("blocked", start_blockers)
    end

    return stopped_before_start if stop_requested?
    normalize_gates_before_start if live?
    return stopped_after_gates_enabled if stop_requested?

    write_event(event: "burn_in_started", status: live? ? "live" : "dry_run", position_id: position.id, duration_minutes: duration_minutes, interval_seconds: interval_seconds, max_cycles: max_cycles, log_path: receipt_path.to_s, pre_start_rebalance: pre_start_rebalance || unchecked_rebalance_payload("pre_start"))

    deadline = duration_minutes.positive? ? started_at + duration_minutes.minutes : nil
    status = "success"
    blockers = []
    while cycles_attempted < max_cycles && !deadline_reached?(deadline)
      if stop_requested?
        status = "stopped"
        blockers = [ "stop requested" ]
        break
      end
      cycle_result = run_cycle(cycles_attempted + 1, deadline: deadline)
      blockers = Array(cycle_result[:blockers])
      status = cycle_result[:status] == "success" ? "success" : burn_in_status_for_cycle(cycle_result[:status])
      self.last_blocker_status = cycle_result[:status] unless cycle_result[:status] == "success"
      break unless cycle_result[:status] == "success"
      break if cycles_attempted >= max_cycles || deadline_reached?(deadline) || stop_requested?

      sleeper.call(interval_seconds) if interval_seconds.positive? && !cycle_result[:hold_monitored]
    end

    disable_after_run if disable_after
    finish(status: status, blockers: blockers)
    result(status, blockers)
  rescue => e
    write_event(event: "exception", status: "failed", error_class: e.class.name, error_message: e.message)
    disable_after_run if disable_after
    finish(status: "failed", blockers: [ "#{e.class}: #{e.message}" ])
    result("failed", [ "#{e.class}: #{e.message}" ])
  end

  private

  attr_reader :position, :duration_minutes, :interval_seconds, :max_cycles, :confirmation, :env, :proof_registry,
    :executor_factory, :now, :sleeper, :selector, :log_dir, :stdout, :started_at, :receipt_path, :disable_after,
    :readiness_factory, :snapshot_refresher, :rebalance_before_cycle, :max_target_change_per_cycle_eth,
    :preflight_factory, :burn_in_tolerance_multiplier, :burn_in_extra_tolerance_eth,
    :burn_in_max_allowed_drift_eth, :burn_in_max_allowed_drift_ratio,
    :rebalance_after_migration, :rebalance_during_hold, :rebalance_hold_interval_seconds,
    :rebalance_before_next_migration, :rebalance_only_if_outside_tolerance,
    :rebalance_max_attempts_per_cycle, :rebalance_readback_recheck_attempts,
    :rebalance_readback_recheck_interval_seconds, :active_rebalance_factory,
    :event_callback, :stop_requested, :hold_monitor_warning_grace_seconds
  attr_accessor :orders_submitted, :orders_placed, :signatures_created, :cycles_attempted, :cycles_succeeded,
    :initial_target_short_eth, :final_target_short_eth, :max_target_delta_eth, :target_refresh_failures,
    :last_readiness_report, :snapshot_refresh_status, :snapshot_accepted_for_burn_in, :snapshot_warnings,
    :snapshot_blockers, :last_direct_preflight_report, :last_blocker_status,
    :last_manual_action_execution, :last_manual_action_route

  def live?
    @live
  end

  def deadline_reached?(deadline)
    deadline && now.call >= deadline
  end

  def stop_requested?
    stop_requested&.call == true
  end

  def prepare_log!
    FileUtils.mkdir_p(log_dir)
    FileUtils.touch(receipt_path)
    update_latest!
  end

  def preflight_blockers
    position.reload
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    blockers = []
    blockers << "submitted confirmation must equal #{CONFIRMATION}" if live? && confirmation != CONFIRMATION
    blockers << "rebalance_before_cycle=true is not supported for random burn-in yet; rerun with rebalance_before_cycle=false" if rebalance_before_cycle
    blockers << "current production venue must be extended, ethereal, or nado" unless VENUES.include?(current)
    direct = direct_preflight("preflight")
    record_direct_preflight(direct)
    blockers.concat(direct.fetch(:blockers))
    refresh_dashboard_snapshot_for_diagnostics("preflight")
    blockers.uniq
  end

  def pre_start_rebalance_allowed?(blockers)
    rebalance_before_next_migration &&
      Array(blockers).present? &&
      Array(blockers).all? { |blocker| rebalance_trigger_blocker?(blocker) }
  end

  def pre_start_blockers_after_rebalance(start_blockers, pre_start_rebalance)
    rebalance_blockers = Array(pre_start_rebalance[:blockers])
    return rebalance_blockers.uniq if rebalance_blockers.any?

    refreshed = direct_preflight("preflight_after_pre_start_rebalance")
    record_direct_preflight(refreshed)
    refreshed_blockers = Array(refreshed.fetch(:blockers))
    return refreshed_blockers.reject { |blocker| rebalance_trigger_blocker?(blocker) }.uniq if pre_start_rebalance_succeeded?(pre_start_rebalance)

    (start_blockers + [ "active venue one-shot rebalance final readback is outside tolerance" ]).uniq
  end

  def pre_start_rebalance_succeeded?(payload)
    return true if !live? && Array(payload[:blockers]).empty?

    payload[:final_inside_tolerance] == true
  end

  def normalize_gates_before_start
    set_setting("MIGRATION_LIVE_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_AUTO_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_MANUAL_LIVE_CANARY_ENABLED", false, "random burn-in start")
    set_setting("MIGRATION_FULL_ALLOWED", false, "random burn-in start")
    set_setting("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED", false, "random burn-in start")
    enable_nado_live_gates(reason: "random burn-in start nado route support")
    ActiveVenueAutoPolicy.new(position: position).enable_current!(reason: "random burn-in start active venue auto")
  end

  def readiness_report
    return readiness_factory.call(position: position, proof_registry: proof_registry) if readiness_factory

    MigrationRandomReadiness.new(position: position, proof_registry: proof_registry).report
  end

  def disable_after_run
    return unless live?

    set_setting("MIGRATION_LIVE_ENABLED", false, "random burn-in disable_after")
    set_setting("MIGRATION_AUTO_ENABLED", false, "random burn-in disable_after")
    set_setting("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", false, "random burn-in disable_after")
    ActiveVenueAutoPolicy.new(position: position).disable_all!(reason: "random burn-in disable_after")
    set_setting("AERODROME_NADO_HEDGE_LIVE_ENABLED", false, "random burn-in disable_after")
    set_setting("AERODROME_NADO_LIVE_MIGRATION_ENABLED", false, "random burn-in disable_after")
  end

  def set_setting(key, enabled, reason)
    OperationalSettings.set!(key: key, enabled: enabled, reason: reason)
  end

  def run_cycle(cycle, deadline:)
    return stopped_cycle_result(cycle, "stop requested before cycle") if stop_requested?

    self.cycles_attempted += 1
    pre_report = direct_preflight("pre_cycle")
    record_direct_preflight(pre_report)
    refresh_dashboard_snapshot_for_diagnostics("pre_cycle")
    pre_target = target_payload(pre_report)
    pre_hedge = hedge_payload(pre_report)
    pre_blockers, pre_status = pre_cycle_blockers(pre_report)
    return stopped_cycle_result(cycle, "stop requested before pre-next-cycle rebalance") if stop_requested?

    pre_next_cycle_rebalance = run_active_rebalance(reason: "pre_next_cycle") if rebalance_before_next_migration && pre_cycle_rebalance_allowed?(pre_report)
    accumulate_rebalance_counts(pre_next_cycle_rebalance)
    return stopped_cycle_result(cycle, "stop requested before migration") if stop_requested?

    if pre_next_cycle_rebalance && Array(pre_next_cycle_rebalance[:blockers]).any?
      pre_blockers = (pre_blockers + Array(pre_next_cycle_rebalance[:blockers])).uniq
      pre_status = "stopped_active_rebalance"
    end
    if pre_blockers.any?
      event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: nil, execution: zero_execution(status: "blocked"), post_target: nil, post_hedge: nil, status: pre_status, blockers: pre_blockers, pre_next_cycle_rebalance: pre_next_cycle_rebalance)
      write_event(event)
      return { status: pre_status, blockers: pre_blockers }
    end

    route = select_route
    unless route
      event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: nil, execution: zero_execution(status: "blocked"), post_target: nil, post_hedge: nil, status: "blocked", blockers: [ "no READY_FOR_RANDOM route from current production venue" ], pre_next_cycle_rebalance: pre_next_cycle_rebalance)
      write_event(event)
      return { status: "blocked", blockers: event.fetch(:blockers) }
    end

    if live?
      return stopped_cycle_result(cycle, "stop requested before migration submit") if stop_requested?

      begin
        result = nil
        MigrationExecutionLock.with_lock(position) do
          enable_route_live_gates(route)
          raise StopRequestedDuringCycle if stop_requested?
          result = executor.run(
            position: position,
            from_venue: route.fetch(:from_venue),
            to_venue: route.fetch(:to_venue),
            mode: "full",
            dry_run: false,
            confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
            full_migration_allowed: true,
            migration_sequence: route.fetch(:migration_sequence, "target_first"),
            execution_preflight: pre_report
          )
        end
        execution = execution_payload(result)
      rescue StopRequestedDuringCycle
        return stopped_cycle_result(cycle, "stop requested before route execution")
      end
    else
      result = nil
      execution = zero_execution(status: "dry_run")
    end

    return stopped_cycle_result(cycle, "stop requested after migration") if stop_requested?

    post_report = direct_preflight("post_cycle")
    record_direct_preflight(post_report)
    refresh_dashboard_snapshot_for_diagnostics("post_cycle")
    post_target = target_payload(post_report, previous_target: decimal_or_nil(pre_target[:target_short_eth]))
    post_hedge = hedge_payload(post_report)
    blockers, status = cycle_blockers(route: route, execution: execution, post_report: post_report, post_target: post_target)
    if status == "success" && direct_market_safe?(post_report, active_venues: active_short_venues(post_report))
      restore_active_venue_auto_after_safe_recovery!(post_report)
    end
    post_migration_rebalance = run_active_rebalance(reason: "post_migration") if status == "success" && rebalance_after_migration
    if post_migration_rebalance && Array(post_migration_rebalance[:blockers]).any?
      blockers = (blockers + Array(post_migration_rebalance[:blockers])).uniq
      status = "stopped_active_rebalance"
    end
    write_event(cycle_progress_event(cycle: cycle, route: route, execution: execution, post_target: post_target, post_hedge: post_hedge, status: status, blockers: blockers, post_migration_rebalance: post_migration_rebalance)) if live? || rebalance_during_hold
    hold_rebalance = empty_hold_rebalance_payload
    if status == "success"
      return stopped_cycle_result(cycle, "stop requested before hold monitor") if stop_requested?

      hold_rebalance = self.hold_rebalance_checks(deadline: deadline, cycle: cycle, route: route)
      hold_rebalance_checks = hold_rebalance.fetch(:checks)
      hold_blockers = hold_rebalance_checks.flat_map { |check| Array(check[:blockers]) }.uniq
      if hold_blockers.any?
        blockers = (blockers + hold_blockers).uniq
        status = "stopped_active_rebalance"
      end
      if stop_requested? && hold_blockers.empty?
        blockers = (blockers + [ "stop requested during hold monitor" ]).uniq
        status = "stopped"
      end
    end
    self.orders_submitted += execution.fetch(:orders_submitted)
    self.orders_placed += execution.fetch(:orders_placed)
    self.signatures_created += execution.fetch(:signatures_created)
    accumulate_rebalance_counts(post_migration_rebalance)
    record_manual_action(route: route, execution: execution) if target_open_source_still_open?(execution)
    self.cycles_succeeded += 1 if status == "success"
    event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: route, execution: execution, post_target: post_target, post_hedge: post_hedge, status: status, blockers: blockers, post_migration_rebalance: post_migration_rebalance, hold_rebalance: hold_rebalance, pre_next_cycle_rebalance: pre_next_cycle_rebalance)
    write_event(event)
    { status: status, blockers: blockers, hold_monitored: hold_rebalance.fetch(:monitored) }
  end

  def select_route
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    policy = MigrationRouteOperationalPolicy.new(env: env)
    routes = proof_registry.report(position: position).fetch(:routes).select do |route|
      route[:from_venue] == current &&
        route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] &&
        policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
    return nil if routes.empty?
    return routes.find { |route| route[:route] == selector.call(routes) } || routes.first if selector

    preferred_target = next_daily_coverage_target(current)
    preferred = routes.find { |route| route[:to_venue] == preferred_target }
    return preferred if preferred

    routes.first.merge(
      coverage_fallback_reason: "preferred daily coverage target #{preferred_target} was not READY_FOR_RANDOM"
    )
  end

  def next_daily_coverage_target(current)
    index = VENUES.index(current)
    return VENUES.first unless index

    VENUES[(index + 1) % VENUES.size]
  end

  def executor
    return executor_factory.call if executor_factory

    HedgeVenueMigrationExecutor.new(env: env)
  end

  def cycle_blockers(route:, execution:, post_report:, post_target:)
    blockers = Array(post_report.fetch(:blockers))
    blockers = blockers.reject { |blocker| rebalance_trigger_blocker?(blocker) } if rebalance_after_migration
    target_delta = decimal_or_nil(post_target[:target_delta_eth]) || BigDecimal("0")
    self.max_target_delta_eth = [ max_target_delta_eth, target_delta ].max
    blockers << "target changed #{target_delta.to_s('F')} ETH during cycle; max allowed is #{max_target_change_per_cycle_eth.to_s('F')} ETH" if target_delta > max_target_change_per_cycle_eth
    if live?
      if target_open_source_still_open?(execution)
        blockers = (Array(execution[:blockers]) + blockers).uniq
        return [ blockers, "manual_action_required" ]
      end
      if blocked_before_submit?(execution)
        blockers = (Array(execution[:blockers]) + blockers).uniq
        return [ blockers, "blocked_before_submit" ]
      end
      blockers << "migration result status is #{execution[:status]}" unless successful_migration_result?(route: route, execution: execution, post_report: post_report)
      blockers << "source venue #{route.fetch(:from_venue)} is not flat after migration" unless venue_short(post_report, route.fetch(:from_venue)).zero?
      blockers << "target venue #{route.fetch(:to_venue)} does not hold expected short after migration" unless venue_short(post_report, route.fetch(:to_venue)).positive?
      third = (VENUES - [ route.fetch(:from_venue), route.fetch(:to_venue) ]).first
      blockers << "third venue #{third} is not flat after migration" unless venue_short(post_report, third).zero?
      blockers << "app production venue was not finalized to #{route.fetch(:to_venue)}" unless HedgeVenues.normalize(position.hedge&.execution_venue) == route.fetch(:to_venue)
      blockers << "route result is partial" if execution[:status].to_s.match?(/partial|pending|unknown|blocked/i)
    end
    [ blockers, post_cycle_status(blockers) ]
  end

  def execution_payload(result)
    receipt = result.receipt
    {
      status: result.status,
      orders_submitted: receipt.fetch(:orders_submitted, 0).to_i,
      orders_placed: receipt.fetch(:orders_placed, 0).to_i,
      signatures_created: receipt.fetch(:signatures_created, 0).to_i,
      receipt_path: receipt[:receipt_path],
      blockers: Array(result.blockers),
      timing: migration_timing_payload(receipt)
    }.merge(
      recovery_command: receipt[:recovery_command],
      recovery_options: receipt[:recovery_options],
      recommended_action: receipt[:recommended_action],
      source_venue: receipt[:source_venue],
      target_venue: receipt[:target_venue],
      target_order_id: receipt[:target_order_id],
      target_possibly_live: receipt[:target_possibly_live],
      target_confirmation_timed_out: receipt[:target_confirmation_timed_out],
      target_authoritative_readback_short_eth: receipt[:target_authoritative_readback_short_eth],
      random_and_auto_paused: receipt[:random_and_auto_paused]
    ).merge(
      source_flat_after: receipt[:source_flat_after],
      source_flat_confirmed: receipt[:source_flat_confirmed],
      target_holds_expected_short: receipt[:target_holds_expected_short],
      target_holds_hedge_confirmed: receipt[:target_holds_hedge_confirmed],
      third_venue_flat: receipt[:third_venue_flat],
      open_orders_clear_after: receipt[:open_orders_clear_after],
      open_orders_after: receipt[:open_orders_after],
      final_inside_tolerance: receipt[:final_inside_tolerance],
      production_venue_finalized: receipt[:production_venue_finalized],
      manual_action_required: receipt[:manual_action_required]
    ).merge(
      # Modern latency evidence must travel with the cycle wrapper: the proof
      # registry no longer trusts blank-latency cycle events as production-safe
      # (2026-07-12 hardening), so a cycle can only certify a route when its
      # honest measurements are present here.
      double_exposure_seconds: receipt[:double_exposure_seconds],
      underhedge_seconds: receipt[:underhedge_seconds],
      total_route_seconds: receipt[:total_route_seconds] || receipt[:total_migration_latency_seconds],
      double_exposure_start_source: receipt[:double_exposure_start_source],
      double_exposure_end_source: receipt[:double_exposure_end_source],
      route_production_safe: receipt[:route_production_safe],
      latency_incident: receipt[:latency_incident]
    ).compact
  end

  def zero_execution(status:)
    { status: status, orders_submitted: 0, orders_placed: 0, signatures_created: 0, receipt_path: nil, blockers: [] }
  end

  def migration_timing_payload(receipt)
    keys = %i[
      target_leg_submit_started_at
      target_leg_submit_finished_at
      target_leg_accepted_at
      target_leg_digest_or_order_id
      target_readback_started_at
      target_readback_confirmed_at
      source_close_submit_started_at
      source_close_submit_finished_at
      source_close_order_id
      source_close_readback_started_at
      source_close_flat_confirmed_at
      target_to_source_close_submit_latency_seconds
      target_accept_to_source_close_submit_latency_seconds
      target_confirm_to_source_close_submit_latency_seconds
      source_close_submit_to_flat_seconds
      target_leg_submit_latency_seconds
      target_confirmation_polling_latency_seconds
      source_close_submit_latency_seconds
    ]
    keys.index_with { |key| receipt[key] }.compact
  end

  def blocked_before_submit?(execution)
    execution[:status].to_s == "blocked_before_submit" &&
      execution.fetch(:orders_submitted).to_i.zero? &&
      execution.fetch(:orders_placed).to_i.zero? &&
      execution.fetch(:signatures_created).to_i.zero?
  end

  def target_open_source_still_open?(execution)
    execution[:status].to_s == "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN"
  end

  def record_manual_action(route:, execution:)
    self.last_manual_action_route = route
    self.last_manual_action_execution = execution
  end

  def successful_migration_result?(route:, execution:, post_report:)
    status = execution[:status].to_s
    return true if BASIC_SUCCESS_STATUSES.include?(status)
    return false unless SOURCE_FIRST_NADO_FINALIZED_STATUSES.include?(status)

    source_flat_after?(route, execution, post_report) &&
      target_holds_expected_short?(route, execution, post_report) &&
      third_venue_flat?(route, execution, post_report) &&
      open_orders_clear_after?(execution, post_report) &&
      final_inside_tolerance?(execution, post_report) &&
      production_venue_finalized?(route, execution) &&
      !truthy?(execution[:manual_action_required])
  end

  def source_flat_after?(route, execution, post_report)
    return boolean_any?(execution, :source_flat_after, :source_flat_confirmed) if execution.key?(:source_flat_after) || execution.key?(:source_flat_confirmed)

    venue_short(post_report, route.fetch(:from_venue)).zero?
  end

  def target_holds_expected_short?(route, execution, post_report)
    if execution.key?(:target_holds_expected_short) || execution.key?(:target_holds_hedge_confirmed)
      return boolean_any?(execution, :target_holds_expected_short, :target_holds_hedge_confirmed)
    end

    venue_short(post_report, route.fetch(:to_venue)).positive?
  end

  def third_venue_flat?(route, execution, post_report)
    return truthy?(execution[:third_venue_flat]) if execution.key?(:third_venue_flat)

    third = (VENUES - [ route.fetch(:from_venue), route.fetch(:to_venue) ]).first
    venue_short(post_report, third).zero?
  end

  def open_orders_clear_after?(execution, post_report)
    return true if truthy?(execution[:open_orders_clear_after])
    return decimal(execution[:open_orders_after]).zero? if execution.key?(:open_orders_after)

    direct_open_orders_zero?(post_report)
  end

  def final_inside_tolerance?(execution, post_report)
    return truthy?(execution[:final_inside_tolerance]) if execution.key?(:final_inside_tolerance)

    post_report[:inside_tolerance] == true
  end

  def production_venue_finalized?(route, execution)
    return truthy?(execution[:production_venue_finalized]) if execution.key?(:production_venue_finalized)

    HedgeVenues.normalize(position.hedge&.execution_venue) == route.fetch(:to_venue)
  end

  def direct_open_orders_zero?(report)
    VENUES.all? { |venue| report.dig(:venues, venue, :open_orders_status) == "zero" }
  end

  def boolean_any?(hash, *keys)
    keys.any? { |key| truthy?(hash[key]) }
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def run_active_rebalance(reason:)
    active_rebalancer.run(reason: reason)
  end

  def active_rebalancer
    return active_rebalance_factory.call if active_rebalance_factory

    ActiveVenueOneShotRebalance.new(
      position: position,
      live: live?,
      env: env,
      preflight_factory: ->(position: _position, stage:) { direct_preflight(stage) },
      max_attempts: rebalance_max_attempts_per_cycle,
      only_if_outside_tolerance: rebalance_only_if_outside_tolerance,
      recheck_attempts: rebalance_readback_recheck_attempts,
      recheck_interval_seconds: rebalance_readback_recheck_interval_seconds,
      sleeper: sleeper,
      now: now
    )
  end

  def hold_rebalance_checks(deadline:, cycle: nil, route: nil)
    return empty_hold_rebalance_payload unless rebalance_during_hold
    return empty_hold_rebalance_payload unless rebalance_hold_interval_seconds.positive? && interval_seconds >= rebalance_hold_interval_seconds

    checks = []
    check_times = []
    started_at = now.call
    target_at = [ started_at + interval_seconds.seconds, deadline ].compact.min
    next_check_at = started_at + rebalance_hold_interval_seconds.seconds
    while next_check_at <= target_at && !deadline_reached?(deadline) && !stop_requested?
      sleep_until(next_check_at)
      break if stop_requested?

      check = run_active_rebalance(reason: "hold_monitor")
      check = recover_hold_rebalance_check(check) if Array(check[:blockers]).any?
      check_times << now.call
      accumulate_rebalance_counts(check)
      checks << check
      write_event(hold_check_event(cycle: cycle, route: route, check: check, check_time: check_times.last, checks_count: checks.size))
      break if Array(check[:blockers]).any?

      next_check_at += rebalance_hold_interval_seconds.seconds
    end
    sleep_until(target_at) if checks.none? { |check| Array(check[:blockers]).any? } && !stop_requested?
    finished_at = now.call

    hold_rebalance_payload(
      started_at: started_at,
      finished_at: finished_at,
      target_seconds: (target_at - started_at).round,
      check_times: check_times,
      checks: checks
    )
  end

  def empty_hold_rebalance_payload
    {
      monitored: false,
      checks: [],
      started_at: nil,
      finished_at: nil,
      target_seconds: nil,
      interval_seconds: nil,
      checks_count: 0,
      actual_span_seconds: nil,
      gap_warning: nil
    }
  end

  def hold_rebalance_payload(started_at:, finished_at:, target_seconds:, check_times:, checks:)
    expected_checks = target_seconds / rebalance_hold_interval_seconds
    expected_span = [ expected_checks - 1, 0 ].max * rebalance_hold_interval_seconds
    actual_span = if check_times.size >= 2
      (check_times.last - check_times.first).round
    else
      0
    end
    {
      monitored: true,
      checks: checks,
      started_at: started_at.utc.iso8601,
      finished_at: finished_at.utc.iso8601,
      target_seconds: target_seconds,
      interval_seconds: rebalance_hold_interval_seconds,
      checks_count: checks.size,
      actual_span_seconds: actual_span,
      gap_warning: hold_monitor_gap_warning(
        expected_checks: expected_checks,
        expected_span: expected_span,
        actual_span: actual_span,
        checks: checks
      )
    }
  end

  def hold_monitor_gap_warning(expected_checks:, expected_span:, actual_span:, checks:)
    return nil if checks.any? { |check| Array(check[:blockers]).any? }
    return nil if expected_checks.zero?
    return "hold monitor ran #{checks.size} checks; expected #{expected_checks}" unless checks.size == expected_checks
    return nil if expected_span.zero? || actual_span >= expected_span - hold_monitor_warning_grace_seconds

    "hold monitor covered #{actual_span}s; expected at least #{expected_span}s"
  end

  def hold_check_event(cycle:, route:, check:, check_time:, checks_count:)
    {
      event: "hold_check",
      cycle: cycle,
      checked_at: check_time.utc.iso8601,
      from_venue: route&.fetch(:from_venue, nil),
      to_venue: route&.fetch(:to_venue, nil),
      route: route&.fetch(:route, nil),
      hold_rebalance_checks_count: checks_count,
      hold_rebalance_check: check,
      status: Array(check[:blockers]).any? ? "blocked" : "running",
      blockers: Array(check[:blockers])
    }
  end

  def sleep_until(target_time)
    remaining = target_time - now.call
    if stop_requested.nil?
      sleeper.call(remaining) if remaining.positive?
      return
    end

    while !stop_requested?
      remaining = target_time - now.call
      break unless remaining.positive?

      sleeper.call([ remaining, 5 ].min)
    end
  end

  def accumulate_rebalance_counts(payload)
    return unless payload

    self.orders_submitted += payload[:orders_submitted].to_i
    self.orders_placed += payload[:orders_placed].to_i
    self.signatures_created += payload[:signatures_created].to_i
  end

  def cycle_event(cycle:, pre_target:, pre_hedge:, route:, execution:, post_target:, post_hedge:, status:, blockers:, post_migration_rebalance: nil, hold_rebalance: empty_hold_rebalance_payload, pre_next_cycle_rebalance: nil)
    {
      event: "cycle",
      cycle: cycle,
      started_at: now.call.utc.iso8601,
      from_venue: route&.fetch(:from_venue, nil),
      to_venue: route&.fetch(:to_venue, nil),
      route: route&.fetch(:route, nil),
      pre_cycle_target: pre_target,
      pre_cycle_hedge: pre_hedge,
      before: pre_hedge,
      execution: execution,
      post_cycle_target: post_target,
      post_cycle_hedge: post_hedge,
      after: post_hedge,
      post_migration_rebalance: post_migration_rebalance || unchecked_rebalance_payload("post_migration"),
      hold_rebalance_checks: hold_rebalance.fetch(:checks),
      hold_started_at: hold_rebalance.fetch(:started_at),
      hold_finished_at: hold_rebalance.fetch(:finished_at),
      hold_target_seconds: hold_rebalance.fetch(:target_seconds),
      hold_rebalance_interval_seconds: hold_rebalance.fetch(:interval_seconds),
      hold_rebalance_checks_count: hold_rebalance.fetch(:checks_count),
      hold_monitor_actual_span_seconds: hold_rebalance.fetch(:actual_span_seconds),
      hold_monitor_gap_warning: hold_rebalance.fetch(:gap_warning),
      pre_next_cycle_rebalance: pre_next_cycle_rebalance || unchecked_rebalance_payload("pre_next_cycle"),
      status: status,
      blockers: blockers
    }
  end

  def cycle_progress_event(cycle:, route:, execution:, post_target:, post_hedge:, status:, blockers:, post_migration_rebalance:)
    {
      event: "cycle_progress",
      progress: "post_migration_finalized",
      cycle: cycle,
      timestamp: now.call.utc.iso8601,
      from_venue: route&.fetch(:from_venue, nil),
      to_venue: route&.fetch(:to_venue, nil),
      route: route&.fetch(:route, nil),
      execution: execution,
      post_cycle_target: post_target,
      post_cycle_hedge: post_hedge,
      after: post_hedge,
      post_migration_rebalance: post_migration_rebalance || unchecked_rebalance_payload("post_migration"),
      status: status,
      blockers: blockers
    }
  end

  def unchecked_rebalance_payload(reason)
    {
      checked: false,
      needed: false,
      reason: reason,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def finish(status:, blockers:)
    summary = final_summary(status: status, blockers: blockers)
    write_event(summary)
  end

  class StopRequestedDuringCycle < StandardError; end

  def stopped_before_start
    blockers = [ "stop requested" ]
    write_event(event: "burn_in_start", status: "stopped", blockers: blockers, orders_submitted: 0, orders_placed: 0, signatures_created: 0)
    disable_after_run if disable_after
    finish(status: "stopped", blockers: blockers)
    result("stopped", blockers)
  end

  def stopped_after_gates_enabled
    blockers = [ "stop requested" ]
    disable_after_run if disable_after
    finish(status: "stopped", blockers: blockers)
    result("stopped", blockers)
  end

  def stopped_cycle_result(cycle, reason)
    blockers = [ reason ]
    write_event(
      event: "cycle",
      cycle: cycle,
      status: "stopped",
      blockers: blockers,
      execution: zero_execution(status: "stopped"),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )
    { status: "stopped", blockers: blockers, hold_monitored: false }
  end

  def final_summary(status:, blockers:)
    position.reload
    snapshot = position.position_dashboard_snapshot
    {
      event: "burn_in_finished",
      status: status,
      blockers: blockers,
      cycles_attempted: cycles_attempted,
      cycles_succeeded: cycles_succeeded,
      duration_seconds: (now.call - started_at).round(3),
      orders_submitted: orders_submitted,
      orders_placed: orders_placed,
      signatures_created: signatures_created,
      final_production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      final_combined_inside_tolerance: last_direct_preflight_report[:inside_tolerance] == true,
      blocker_status: final_blocker_status(blockers),
      stale_pending_continuation_ignored: stale_pending_continuation_ignored?,
      pending_nado_target_continuation_blocking: pending_nado_target_continuation_blocking?,
      pending_continuation_classification: pending_continuation_classification,
      preflight_source: last_direct_preflight_report[:preflight_source] || "migration_random_execution_preflight",
      direct_preflight_blockers: Array(last_direct_preflight_report[:blockers]),
      direct_preflight_warnings: Array(last_direct_preflight_report[:warnings]),
      direct_venue_shorts: direct_venue_shorts(last_direct_preflight_report),
      direct_open_orders: direct_open_orders(last_direct_preflight_report),
      fresh_target: serializable_target(last_direct_preflight_report[:target]),
      tolerance_policy: tolerance_policy_payload(last_direct_preflight_report),
      snapshot_refresh_status: snapshot_refresh_status || snapshot&.refresh_status,
      snapshot_accepted_for_burn_in: snapshot_accepted_for_burn_in,
      snapshot_warnings: snapshot_warnings,
      snapshot_blockers: snapshot_blockers,
      initial_target_short_eth: decimal_string(initial_target_short_eth),
      final_target_short_eth: decimal_string(final_target_short_eth),
      max_target_delta_eth: decimal_string(max_target_delta_eth),
      target_refresh_failures: target_refresh_failures,
      disable_after: disable_after,
      migration_live_enabled_final: OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED"),
      migration_auto_enabled_final: OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED"),
      migration_random_rotation_live_enabled_final: OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    }.merge(manual_action_summary_fields).compact
  end

  def result(status, blockers)
    Result.new(status, blockers, [], receipt_path.to_s, final_summary(status: status, blockers: blockers))
  end

  # Intentionally does NOT restore venue autos here: this runs during shutdown,
  # after disable_after has quiesced every gate/auto, and the fail-closed exit
  # posture (everything off until an operator or the next runner start
  # re-establishes autos) must win. Mid-run restoration is handled at the cycle
  # success and hold-rebalance recovery points instead.
  def final_blocker_status(blockers)
    if last_blocker_status == "stopped_active_rebalance" &&
        direct_market_safe?(last_direct_preflight_report, active_venues: active_short_venues(last_direct_preflight_report))
      return "recovered_after_direct_market_safe_preflight"
    end

    last_blocker_status || preflight_status(blockers)
  end

  def hedge_payload(report)
    {
      production_venue: report[:production_venue],
      extended_short_eth: decimal_string(report.dig(:venues, "extended", :short_eth)),
      ethereal_short_eth: decimal_string(report.dig(:venues, "ethereal", :short_eth)),
      nado_short_eth: decimal_string(report.dig(:venues, "nado", :short_eth)),
      target_short_eth: decimal_string(report.dig(:target, :target_short_eth)),
      combined_short_eth: decimal_string(report[:combined_short_eth]),
      inside_tolerance: report[:inside_tolerance] == true,
      open_orders_count: report.fetch(:venues, {}).values.filter_map { |venue| venue[:open_orders_count] }.sum,
      drift_eth: decimal_string(report[:drift_eth]),
      recommended_rebalance_eth: decimal_string(report[:drift_eth]),
      strict_inside_tolerance: report[:strict_inside_tolerance],
      burn_in_inside_tolerance: report[:burn_in_inside_tolerance],
      strict_tolerance_eth: decimal_string(report[:strict_tolerance_eth]),
      effective_burn_in_tolerance_eth: decimal_string(report[:effective_burn_in_tolerance_eth]),
      burn_in_tolerance_multiplier: decimal_string(report[:burn_in_tolerance_multiplier]),
      burn_in_extra_tolerance_eth: decimal_string(report[:burn_in_extra_tolerance_eth]),
      burn_in_max_allowed_drift_eth: decimal_string(report[:burn_in_max_allowed_drift_eth]),
      burn_in_max_allowed_drift_ratio: decimal_string(report[:burn_in_max_allowed_drift_ratio]),
      drift_ratio: decimal_string(report[:drift_ratio]),
      recommended_rebalance_side: report[:recommended_rebalance_side],
      recommended_rebalance_size_eth: decimal_string(report[:recommended_rebalance_size_eth])
    }
  end

  def target_payload(report, previous_target: nil)
    current_target = decimal_or_nil(report.dig(:target, :target_short_eth))
    self.initial_target_short_eth ||= current_target
    self.final_target_short_eth = current_target if current_target
    target_delta = current_target && previous_target ? (current_target - previous_target).abs : nil
    self.max_target_delta_eth = [ max_target_delta_eth, target_delta ].compact.max if target_delta
    {
      asset0_amount: decimal_string(position.asset0_amount),
      asset1_amount: decimal_string(position.asset1_amount),
      target_short_eth: decimal_string(current_target),
      target_source: report.dig(:target, :target_source),
      exposure_refreshed_at: report.dig(:target, :exposure_refreshed_at),
      lp_refreshed: report.dig(:target, :target_fresh) == true,
      target_changed_during_cycle: target_delta&.positive?,
      target_delta_eth: decimal_string(target_delta)
    }
  end

  def refresh_snapshot(stage)
    snapshot = if snapshot_refresher
      snapshot_refresher.call(position: position, stage: stage)
    else
      DashboardSnapshotRefresh.new(position: position, env: env, force: true).refresh
    end
    position.reload
    [ snapshot || position.position_dashboard_snapshot&.reload, [] ]
  rescue => e
    self.target_refresh_failures += 1
    [ position.position_dashboard_snapshot, [ "#{stage} LP target refresh failed: #{e.class}: #{e.message}" ] ]
  end

  def refresh_dashboard_snapshot_for_diagnostics(stage)
    snapshot, blockers = refresh_snapshot(stage)
    report = burn_in_snapshot_report(snapshot)
    warnings = report.fetch(:warnings) + blockers.map { |blocker| "dashboard snapshot refresh warning: #{blocker}" }
    record_snapshot_report(report.merge(warnings: warnings))
  end

  def direct_preflight(stage)
    if preflight_factory
      preflight_factory.call(position: position, stage: stage)
    else
      MigrationRandomBurnInPreflight.new(
        position: position,
        env: env,
        proof_registry: proof_registry,
        readiness_factory: readiness_factory,
        burn_in_tolerance_multiplier: burn_in_tolerance_multiplier,
        burn_in_extra_tolerance_eth: burn_in_extra_tolerance_eth,
        burn_in_max_allowed_drift_eth: burn_in_max_allowed_drift_eth,
        burn_in_max_allowed_drift_ratio: burn_in_max_allowed_drift_ratio
      ).report
    end
  end

  def record_direct_preflight(report)
    self.last_direct_preflight_report = report
    self.last_readiness_report = report[:readiness] || {}
  end

  def pre_cycle_blockers(report)
    blockers = Array(report.fetch(:blockers))
    blockers = blockers.reject { |blocker| rebalance_trigger_blocker?(blocker) } if rebalance_before_next_migration
    [ blockers.uniq, pre_cycle_status(blockers) ]
  end

  def pre_cycle_rebalance_allowed?(report)
    blockers = Array(report.fetch(:blockers))
    blockers.empty? || blockers.all? { |blocker| rebalance_trigger_blocker?(blocker) }
  end

  def rebalance_trigger_blocker?(blocker)
    blocker.to_s.match?(ActiveVenueOneShotRebalance::REBALANCE_TRIGGER_BLOCKER_PATTERN)
  end

  def trusted_snapshot?(snapshot)
    burn_in_snapshot_report(snapshot).fetch(:accepted)
  end

  def venue_short(report, venue)
    decimal(report.dig(:venues, venue, :short_eth))
  end

  def open_orders_zero?(snapshot)
    !snapshot.open_orders_count_extended.nil? && snapshot.open_orders_count_extended.to_i.zero?
  end

  def pre_cycle_status(blockers)
    return "success" if blockers.empty?
    return "blocked_stale_or_unavailable_lp_target" if blockers.any? { |blocker| blocker.match?(/LP target|refresh failed|stale/i) }
    return "blocked_before_cycle_out_of_burn_in_tolerance" if blockers.any? { |blocker| blocker.include?("out_of_burn_in_tolerance") }
    return "blocked_open_orders_nonzero" if blockers.any? { |blocker| blocker.include?("open orders") }

    "blocked_unexpected_venue_exposure"
  end

  def burn_in_status_for_cycle(status)
    return "manual_action_required" if status.to_s == "manual_action_required"
    status.to_s == "blocked_before_submit" ? "blocked" : "stopped"
  end

  # Re-asserts the active venue's auto after a defensive executor pause once
  # recovery has proven the direct market safe. The defensive paths
  # (pause_autonomous_migration!) disable EVERY venue auto; leaving the active
  # venue without its auto blocks the hold one-shot rebalance, so the runner
  # stops cleanly on the next target drift and the position sits outside
  # tolerance unattended (observed 2026-07-11). Fail-closed: callers must have
  # proven direct_market_safe? on a fresh direct preflight (one active venue
  # matching the production venue, open orders zero, no blockers, inside
  # tolerance); additionally skips unless live, unless the report's production
  # venue matches the hedge execution venue, and no-ops when already enabled.
  def restore_active_venue_auto_after_safe_recovery!(report)
    return { restored: false, reason: "not_live" } unless live?

    venue = HedgeVenues.normalize(report[:production_venue])
    key = OperationalSettings.auto_key_for(venue)
    return { restored: false, reason: "unknown_venue" } unless key
    return { restored: false, key: key, reason: "hedge_venue_mismatch" } unless HedgeVenues.normalize(position.hedge&.execution_venue) == venue
    return { restored: false, key: key, reason: "already_enabled" } if OperationalSettings.enabled?(key, env: env)

    result = ActiveVenueAutoPolicy.new(position: position).enable_current!(reason: "restore venue auto after defensive recovery reconciled safe")
    { restored: result.ok, key: key, errors: result.errors.presence }.compact
  rescue StandardError => e
    { restored: false, key: key, error: "#{e.class}: #{e.message}" }
  end

  def recover_hold_rebalance_check(check)
    return check unless zero_submit_active_rebalance_block?(check)

    direct = direct_preflight("active_rebalance_hold_monitor_recovery")
    record_direct_preflight(direct)
    active_venues = active_short_venues(direct)
    safe = direct_market_safe?(direct, active_venues: active_venues)
    auto_restore = safe ? restore_active_venue_auto_after_safe_recovery!(direct) : nil
    recovered = check.merge(
      active_venue_auto_restore: auto_restore,
      reason: safe ? "recovered_after_direct_market_safe_preflight" : check[:reason],
      active_rebalance_recovered: safe,
      active_rebalance_recovery_reason: safe ? active_rebalance_recovery_reason(check) : nil,
      final_direct_inside_tolerance: direct[:inside_tolerance] == true,
      final_direct_open_orders_zero: direct_open_orders_zero?(direct),
      final_direct_active_venues: active_venues,
      terminal_reason: safe ? nil : direct_market_terminal_reason(direct, active_venues: active_venues),
      recovery_direct_preflight_blockers: Array(direct[:blockers]),
      blockers: safe ? [] : Array(check[:blockers])
    )
    recovered = recovered.merge(authoritative_direct_readback_fields(check, direct)) if safe
    recovered.compact
  end

  # The hold-monitor pre-check can fire on a stale short readback while the one-shot rebalance
  # re-reads the venue and finds it already inside tolerance (no_op / blocked_before_submit).
  # When recovery confirms the direct market is safe, the authoritative fresh readback values
  # must replace the stale pre-check values so the event is internally consistent, while the
  # pre-check values are preserved under pre_rebalance_* for diagnostics.
  def authoritative_direct_readback_fields(check, direct)
    venue = HedgeVenues.normalize(direct[:production_venue])
    final_short = venue_short(direct, venue)
    final_target = decimal_or_nil(direct.dig(:target, :target_short_eth))
    final_drift = final_target ? final_target - final_short : nil
    {
      pre_rebalance_current_short_eth: check[:current_short_eth],
      pre_rebalance_target_short_eth: check[:target_short_eth],
      pre_rebalance_drift_eth: check[:drift_eth],
      pre_rebalance_inside_tolerance: check[:inside_tolerance],
      final_direct_current_short_eth: decimal_string(final_short),
      final_direct_target_short_eth: decimal_string(final_target),
      final_direct_drift_eth: decimal_string(final_drift),
      current_short_eth: decimal_string(final_short),
      target_short_eth: decimal_string(final_target) || check[:target_short_eth],
      drift_eth: decimal_string(final_drift) || check[:drift_eth],
      inside_tolerance: true
    }
  end

  def zero_submit_active_rebalance_block?(check)
    check[:reason].to_s == "blocked" &&
      check[:orders_submitted].to_i.zero? &&
      check[:orders_placed].to_i.zero? &&
      check[:signatures_created].to_i.zero? &&
      transient_active_rebalance_blockers?(Array(check[:blockers]))
  end

  def transient_active_rebalance_blockers?(blockers)
    blockers.any? &&
      blockers.all? do |blocker|
        false_missing_exposure_blocker?(blocker) ||
          open_orders_uncertainty_blocker?(blocker) ||
          noop_unsubmitted_status_blocker?(blocker)
      end
  end

  def active_rebalance_recovery_reason(check)
    blockers = Array(check[:blockers])
    return "recovered_after_open_orders_uncertainty_readback" if blockers.any? { |blocker| open_orders_uncertainty_blocker?(blocker) }
    return "recovered_after_noop_direct_market_safe_readback" if blockers.any? { |blocker| noop_unsubmitted_status_blocker?(blocker) }

    "recovered_after_false_missing_exposure_readback"
  end

  def false_missing_exposure_blocker?(blocker)
    blocker.to_s.match?(/no venue has the production hedge|current production venue has no real short|active venue exposure is not isolated/i)
  end

  def open_orders_uncertainty_blocker?(blocker)
    blocker.to_s.match?(/open orders could not be confirmed zero|active venue open orders are not zero|open orders cannot be confirmed zero/i)
  end

  # A zero-submit one-shot rebalance that re-read the venue and took no action (no_op /
  # blocked_before_submit). This is only transient when the fresh direct readback later proves
  # the market is safe; otherwise direct_market_safe? keeps it terminal (fail closed).
  def noop_unsubmitted_status_blocker?(blocker)
    blocker.to_s.match?(/one-shot rebalance status is (blocked_before_submit|no_op)/i)
  end

  def direct_market_safe?(report, active_venues:)
    active_venues.one? &&
      active_venues.first == HedgeVenues.normalize(report[:production_venue]) &&
      direct_open_orders_zero?(report) &&
      Array(report[:blockers]).empty? &&
      report[:inside_tolerance] == true
  end

  def active_short_venues(report)
    Array(report[:active_short_venues]).presence ||
      VENUES.select { |venue| venue_short(report, venue).positive? }
  end

  def direct_market_terminal_reason(report, active_venues:)
    return "open_orders_nonzero_or_unknown" unless direct_open_orders_zero?(report)
    return "multiple_active_venues" if active_venues.size > 1
    return "no_active_venue" if active_venues.empty?
    return "active_venue_differs_from_production_venue" unless active_venues.first == HedgeVenues.normalize(report[:production_venue])
    return "final_direct_outside_tolerance" unless report[:inside_tolerance] == true
    return "direct_preflight_blockers_present" if Array(report[:blockers]).any?

    "direct_market_unsafe"
  end

  def manual_action_summary_fields
    execution = last_manual_action_execution
    route = last_manual_action_route
    return {} unless execution

    {
      blocker_status: "target_open_source_still_open",
      source_venue: execution[:source_venue] || route&.fetch(:from_venue, nil),
      target_venue: execution[:target_venue] || route&.fetch(:to_venue, nil),
      recommended_action: execution[:recommended_action] || "close source venue reduce-only",
      recovery_command: execution[:recovery_command]
    }
  end

  def enable_route_live_gates(route)
    return unless [ route.fetch(:from_venue), route.fetch(:to_venue) ].include?("nado")

    enable_nado_live_gates(reason: "random burn-in route #{route.fetch(:route)}")
  end

  def enable_nado_live_gates(reason:)
    set_setting("AERODROME_NADO_HEDGE_LIVE_ENABLED", true, reason)
    set_setting("AERODROME_NADO_LIVE_MIGRATION_ENABLED", true, reason)
  end

  def preflight_status(blockers)
    return "success" if blockers.empty?
    return "blocked_before_cycle_out_of_burn_in_tolerance" if blockers.any? { |blocker| blocker.include?("out_of_burn_in_tolerance") }
    return "blocked_stale_or_unavailable_lp_target" if blockers.any? { |blocker| blocker.match?(/LP target|refresh failed|stale/i) }
    return "blocked_open_orders_nonzero" if blockers.any? { |blocker| blocker.include?("open orders") }

    "blocked_before_start"
  end

  def post_cycle_status(blockers)
    return "success" if blockers.empty?
    return "stopped_target_changed_too_much" if blockers.any? { |blocker| blocker.include?("target changed") }
    return "stopped_post_cycle_out_of_burn_in_tolerance" if blockers.any? { |blocker| blocker.include?("out_of_burn_in_tolerance") }
    return "stopped_open_orders_nonzero" if blockers.any? { |blocker| blocker.include?("open orders") }
    return "stopped_source_not_flat" if blockers.any? { |blocker| blocker.include?("source venue") }
    return "stopped_target_not_confirmed" if blockers.any? { |blocker| blocker.include?("target venue") }

    "stopped"
  end

  def target_source(snapshot)
    return nil unless snapshot
    return "dashboard_snapshot_error" if snapshot.source_errors_hash.key?("mellow_exposure")

    position.mellow_autopilot? ? "dashboard_snapshot_fresh_mellow_exposure" : "dashboard_snapshot_position_asset0_amount"
  end

  def burn_in_snapshot_report(snapshot)
    blockers = []
    warnings = []
    unless snapshot
      return { refresh_status: nil, accepted: false, warnings: warnings, blockers: [ "dashboard snapshot must be present" ] }
    end

    blockers << "LP target is stale or unavailable" unless snapshot.target_short_eth.present? && decimal(snapshot.target_short_eth).positive?
    blockers << "production venue is unavailable in dashboard snapshot" if snapshot.production_venue.blank?
    VENUES.each do |venue|
      blockers << "critical #{venue.capitalize} readback failed" if critical_venue_failed?(snapshot, venue)
      blockers << "#{venue} short amount is unknown" if snapshot.public_send("#{venue}_short_eth").nil?
    end
    blockers << "combined hedge cannot be computed" if snapshot.combined_short_eth.nil?
    blockers << "inside tolerance readback is unavailable" if snapshot.inside_tolerance.nil?
    blockers << "open orders cannot be confirmed zero" if snapshot.open_orders_count_extended.nil?
    blockers << "signer must be healthy" unless snapshot.signer_status.to_s.in?(%w[ok healthy pass ready])
    critical_source_errors(snapshot).each { |message| blockers << message }
    if extended_optional_warning?(snapshot)
      warnings << "extended optional account state timed out; critical position readback ok"
    end

    {
      refresh_status: snapshot.refresh_status,
      accepted: blockers.empty?,
      warnings: warnings,
      blockers: blockers.uniq
    }
  end

  def record_snapshot_report(report)
    self.snapshot_refresh_status = report.fetch(:refresh_status)
    self.snapshot_accepted_for_burn_in = report.fetch(:accepted)
    self.snapshot_warnings = report.fetch(:warnings)
    self.snapshot_blockers = report.fetch(:blockers)
  end

  def critical_venue_failed?(snapshot, venue)
    source_status = snapshot.public_send("#{venue}_source_status").to_s
    return true unless source_status == "ok"
    return snapshot.extended_critical_read_status.to_s != "ok" if venue == "extended"

    false
  end

  def critical_source_errors(snapshot)
    snapshot.source_errors_hash.filter_map do |key, value|
      next if key.to_s == "extended_optional"

      "#{key} source error: #{value}"
    end
  end

  def extended_optional_warning?(snapshot)
    return false unless snapshot.extended_critical_read_status.to_s == "ok"
    return false unless snapshot.extended_optional_read_status.to_s.in?(%w[error timed_out timeout])

    snapshot.source_errors_hash.fetch("extended_optional", "").to_s.match?(/Timeout/i)
  end

  def outside_tolerance_blocker(snapshot)
    drift = decimal(snapshot&.drift_eth)
    side = drift.positive? ? "increase_short" : "decrease_short"
    "current hedge outside tolerance: target_short_eth=#{decimal_string(snapshot&.target_short_eth)} " \
      "current_short_eth=#{decimal_string(snapshot&.combined_short_eth)} drift_eth=#{decimal_string(snapshot&.drift_eth)} " \
      "tolerance_abs_eth=#{decimal_string(snapshot&.tolerance_abs_eth)} recommended_rebalance_side=#{side} " \
      "recommended_rebalance_size_eth=#{decimal_string(drift.abs)}"
  end

  def readiness_diagnostics
    {
      preflight_source: last_direct_preflight_report[:preflight_source] || "migration_random_execution_preflight",
      stale_pending_continuation_ignored: stale_pending_continuation_ignored?,
      pending_nado_target_continuation_blocking: pending_nado_target_continuation_blocking?,
      pending_continuation_classification: pending_continuation_classification,
      pending_nado_target_continuation: last_readiness_report[:pending_nado_target_continuation],
      direct_preflight_blockers: Array(last_direct_preflight_report[:blockers]),
      direct_preflight_warnings: Array(last_direct_preflight_report[:warnings]),
      direct_venue_shorts: direct_venue_shorts(last_direct_preflight_report),
      direct_open_orders: direct_open_orders(last_direct_preflight_report),
      fresh_target: serializable_target(last_direct_preflight_report[:target]),
      tolerance_policy: tolerance_policy_payload(last_direct_preflight_report),
      snapshot_refresh_status: snapshot_refresh_status,
      snapshot_accepted_for_burn_in: snapshot_accepted_for_burn_in,
      snapshot_warnings: snapshot_warnings,
      snapshot_blockers: snapshot_blockers
    }
  end

  def direct_venue_shorts(report)
    VENUES.to_h { |venue| [ venue, decimal_string(report.dig(:venues, venue, :short_eth)) ] }
  end

  def stale_pending_continuation_ignored?
    last_direct_preflight_report[:stale_pending_continuation_ignored] == true ||
      last_readiness_report[:stale_pending_continuation_ignored] == true
  end

  def pending_nado_target_continuation_blocking?
    last_direct_preflight_report[:pending_nado_target_continuation_blocking] == true ||
      last_readiness_report[:pending_nado_target_continuation_blocking] == true
  end

  def pending_continuation_classification
    last_direct_preflight_report[:pending_continuation_classification] ||
      last_readiness_report[:pending_continuation_classification]
  end

  def direct_open_orders(report)
    VENUES.to_h do |venue|
      details = report.dig(:venues, venue) || {}
      [ venue, {
        status: details[:open_orders_status],
        count: details[:open_orders_count],
        message: details[:open_orders_message]
      }.compact ]
    end
  end

  def serializable_target(target)
    return {} unless target

    target.merge(target_short_eth: decimal_string(target[:target_short_eth]))
  end

  def tolerance_policy_payload(report)
    {
      strict_inside_tolerance: report[:strict_inside_tolerance],
      burn_in_inside_tolerance: report[:burn_in_inside_tolerance],
      strict_tolerance_eth: decimal_string(report[:strict_tolerance_eth]),
      effective_burn_in_tolerance_eth: decimal_string(report[:effective_burn_in_tolerance_eth]),
      burn_in_tolerance_multiplier: decimal_string(report[:burn_in_tolerance_multiplier] || burn_in_tolerance_multiplier),
      burn_in_extra_tolerance_eth: decimal_string(report[:burn_in_extra_tolerance_eth] || burn_in_extra_tolerance_eth),
      burn_in_max_allowed_drift_eth: decimal_string(report[:burn_in_max_allowed_drift_eth] || burn_in_max_allowed_drift_eth),
      burn_in_max_allowed_drift_ratio: decimal_string(report[:burn_in_max_allowed_drift_ratio] || burn_in_max_allowed_drift_ratio),
      drift_eth: decimal_string(report[:drift_eth]),
      drift_ratio: decimal_string(report[:drift_ratio]),
      recommended_rebalance_side: report[:recommended_rebalance_side],
      recommended_rebalance_size_eth: decimal_string(report[:recommended_rebalance_size_eth])
    }
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def decimal_string(value)
    value.nil? ? nil : decimal(value).to_s("F")
  end

  def write_event(event)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(event)) }
    stdout.puts("#{event.fetch(:event)} #{event.fetch(:status, 'ok')} #{event[:route]}".strip)
    update_latest!
    event_callback&.call(event)
  end

  def update_latest!
    FileUtils.cp(receipt_path, log_dir.join("latest_position_#{position.id}.jsonl"))
  end
end
