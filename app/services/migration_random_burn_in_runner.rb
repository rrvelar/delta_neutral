class MigrationRandomBurnInRunner
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_30_MIN_LIVE_RANDOM_BURN_IN".freeze
  LOG_DIR = Rails.root.join("storage/random_rotation_burn_in")
  VENUES = %w[extended ethereal nado].freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt_path, :summary)

  def initialize(position:, duration_minutes:, interval_seconds:, max_cycles:, live: false, disable_after: true,
                 confirmation: nil, env: ENV, proof_registry: nil, executor_factory: nil, now: -> { Time.current },
                 sleeper: ->(seconds) { sleep(seconds) }, selector: nil, log_dir: LOG_DIR, stdout: $stdout,
                 readiness_factory: nil, snapshot_refresher: nil, rebalance_before_cycle: false,
                 max_target_change_per_cycle_eth: "0.15", preflight_factory: nil,
                 burn_in_tolerance_multiplier: "1.0", burn_in_extra_tolerance_eth: "0",
                 burn_in_max_allowed_drift_eth: "0.15", burn_in_max_allowed_drift_ratio: "0.08")
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
    start_blockers = preflight_blockers
    if start_blockers.any?
      write_event(readiness_diagnostics.merge(event: "burn_in_start", status: "blocked_before_start", blocker_status: preflight_status(start_blockers), blockers: start_blockers))
      finish(status: "blocked", blockers: start_blockers)
      return result("blocked", start_blockers)
    end

    normalize_gates_before_start if live?
    write_event(event: "burn_in_started", status: live? ? "live" : "dry_run", position_id: position.id, duration_minutes: duration_minutes, interval_seconds: interval_seconds, max_cycles: max_cycles, log_path: receipt_path.to_s)

    deadline = started_at + duration_minutes.minutes
    status = "success"
    blockers = []
    while cycles_attempted < max_cycles && now.call < deadline
      cycle_result = run_cycle(cycles_attempted + 1)
      blockers = Array(cycle_result[:blockers])
      status = cycle_result[:status] == "success" ? "success" : burn_in_status_for_cycle(cycle_result[:status])
      self.last_blocker_status = cycle_result[:status] unless cycle_result[:status] == "success"
      break unless cycle_result[:status] == "success"
      break if cycles_attempted >= max_cycles || now.call >= deadline

      sleeper.call(interval_seconds) if interval_seconds.positive?
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
    :burn_in_max_allowed_drift_eth, :burn_in_max_allowed_drift_ratio
  attr_accessor :orders_submitted, :orders_placed, :signatures_created, :cycles_attempted, :cycles_succeeded,
    :initial_target_short_eth, :final_target_short_eth, :max_target_delta_eth, :target_refresh_failures,
    :last_readiness_report, :snapshot_refresh_status, :snapshot_accepted_for_burn_in, :snapshot_warnings,
    :snapshot_blockers, :last_direct_preflight_report, :last_blocker_status,
    :last_manual_action_execution, :last_manual_action_route

  def live?
    @live
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

    set_setting("MIGRATION_AUTO_ENABLED", false, "random burn-in disable_after")
    set_setting("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", false, "random burn-in disable_after")
    ActiveVenueAutoPolicy.new(position: position).disable_all!(reason: "random burn-in disable_after")
    set_setting("AERODROME_NADO_HEDGE_LIVE_ENABLED", false, "random burn-in disable_after")
    set_setting("AERODROME_NADO_LIVE_MIGRATION_ENABLED", false, "random burn-in disable_after")
  end

  def set_setting(key, enabled, reason)
    OperationalSettings.set!(key: key, enabled: enabled, reason: reason)
  end

  def run_cycle(cycle)
    self.cycles_attempted += 1
    pre_report = direct_preflight("pre_cycle")
    record_direct_preflight(pre_report)
    refresh_dashboard_snapshot_for_diagnostics("pre_cycle")
    pre_target = target_payload(pre_report)
    pre_hedge = hedge_payload(pre_report)
    pre_blockers, pre_status = pre_cycle_blockers(pre_report)
    if pre_blockers.any?
      event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: nil, execution: zero_execution(status: "blocked"), post_target: nil, post_hedge: nil, status: pre_status, blockers: pre_blockers)
      write_event(event)
      return { status: pre_status, blockers: pre_blockers }
    end

    route = select_route
    unless route
      event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: nil, execution: zero_execution(status: "blocked"), post_target: nil, post_hedge: nil, status: "blocked", blockers: [ "no READY_FOR_RANDOM route from current production venue" ])
      write_event(event)
      return { status: "blocked", blockers: event.fetch(:blockers) }
    end

    if live?
      result = nil
      MigrationExecutionLock.with_lock(position) do
        enable_route_live_gates(route)
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
    else
      result = nil
      execution = zero_execution(status: "dry_run")
    end

    post_report = direct_preflight("post_cycle")
    record_direct_preflight(post_report)
    refresh_dashboard_snapshot_for_diagnostics("post_cycle")
    post_target = target_payload(post_report, previous_target: decimal_or_nil(pre_target[:target_short_eth]))
    post_hedge = hedge_payload(post_report)
    blockers, status = cycle_blockers(route: route, execution: execution, post_report: post_report, post_target: post_target)
    self.orders_submitted += execution.fetch(:orders_submitted)
    self.orders_placed += execution.fetch(:orders_placed)
    self.signatures_created += execution.fetch(:signatures_created)
    record_manual_action(route: route, execution: execution) if target_open_source_still_open?(execution)
    self.cycles_succeeded += 1 if status == "success"
    event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: route, execution: execution, post_target: post_target, post_hedge: post_hedge, status: status, blockers: blockers)
    write_event(event)
    { status: status, blockers: blockers }
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

    routes[Random.new.rand(routes.size)]
  end

  def executor
    return executor_factory.call if executor_factory

    HedgeVenueMigrationExecutor.new(env: env)
  end

  def cycle_blockers(route:, execution:, post_report:, post_target:)
    blockers = Array(post_report.fetch(:blockers))
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
      blockers << "migration result status is #{execution[:status]}" unless execution[:status].to_s.in?(%w[success MIGRATION_FINALIZED])
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
      recommended_action: receipt[:recommended_action],
      source_venue: receipt[:source_venue],
      target_venue: receipt[:target_venue],
      random_and_auto_paused: receipt[:random_and_auto_paused]
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

  def cycle_event(cycle:, pre_target:, pre_hedge:, route:, execution:, post_target:, post_hedge:, status:, blockers:)
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
      status: status,
      blockers: blockers
    }
  end

  def finish(status:, blockers:)
    summary = final_summary(status: status, blockers: blockers)
    write_event(summary)
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
      blocker_status: last_blocker_status || preflight_status(blockers),
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
    [ blockers.uniq, pre_cycle_status(blockers) ]
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
  end

  def update_latest!
    FileUtils.cp(receipt_path, log_dir.join("latest_position_#{position.id}.jsonl"))
  end
end
