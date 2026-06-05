class MigrationRandomBurnInRunner
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_30_MIN_LIVE_RANDOM_BURN_IN".freeze
  LOG_DIR = Rails.root.join("storage/random_rotation_burn_in")
  VENUES = %w[extended ethereal nado].freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt_path, :summary)

  def initialize(position:, duration_minutes:, interval_seconds:, max_cycles:, live: false, disable_after: true,
                 confirmation: nil, env: ENV, proof_registry: nil, executor_factory: nil, now: -> { Time.current },
                 sleeper: ->(seconds) { sleep(seconds) }, selector: nil, log_dir: LOG_DIR, stdout: $stdout,
                 readiness_factory: nil, snapshot_refresher: nil, rebalance_before_cycle: false,
                 max_target_change_per_cycle_eth: "0.15")
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
    @rebalance_before_cycle = ActiveModel::Type::Boolean.new.cast(rebalance_before_cycle)
    @max_target_change_per_cycle_eth = decimal(max_target_change_per_cycle_eth)
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
      status = cycle_result[:status] == "success" ? "success" : "stopped"
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
    :readiness_factory, :snapshot_refresher, :rebalance_before_cycle, :max_target_change_per_cycle_eth
  attr_accessor :orders_submitted, :orders_placed, :signatures_created, :cycles_attempted, :cycles_succeeded,
    :initial_target_short_eth, :final_target_short_eth, :max_target_delta_eth, :target_refresh_failures,
    :last_readiness_report

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
    proof_report = proof_registry.report(position: position)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    blockers = []
    blockers << "submitted confirmation must equal #{CONFIRMATION}" if live? && confirmation != CONFIRMATION
    blockers << "all route proofs must be READY_FOR_RANDOM" unless proof_report.fetch(:missing_route_proofs).empty?
    blockers << "stale route proofs must be resolved" if proof_report.fetch(:stale_route_proofs).present?
    blockers << "current production venue must be extended, ethereal, or nado" unless VENUES.include?(current)
    readiness = readiness_report
    self.last_readiness_report = readiness
    blockers << "pending target=Nado migration continuation must be completed before burn-in" if readiness[:pending_nado_target_continuation_blocking]
    blockers << "migration lock is already active for this position" if MigrationExecutionLock.locked?(position)

    snapshot, refresh_blockers = refresh_snapshot("preflight")
    blockers.concat(refresh_blockers)
    blockers << "dashboard snapshot must be present" unless snapshot
    if snapshot
      blockers << outside_tolerance_blocker(snapshot) unless snapshot.inside_tolerance == true
      blockers << "dashboard snapshot refresh_status must be ok" unless snapshot.refresh_status == "ok"
      blockers << "dashboard snapshot must not be stale" if snapshot.respond_to?(:stale_now?) && snapshot.stale_now?
      blockers << "exactly one venue must have a real short" unless active_short_venues(snapshot).one?
      blockers << "current production venue must hold the only real short" unless active_short_venues(snapshot) == [ current ]
      blockers << "open orders must be zero before burn-in" unless open_orders_zero?(snapshot)
      blockers << "signer must be healthy" unless snapshot.signer_status.to_s.in?(%w[ok healthy pass ready])
    end
    blockers.uniq
  end

  def normalize_gates_before_start
    set_setting("MIGRATION_LIVE_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_AUTO_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", true, "random burn-in start")
    set_setting("MIGRATION_MANUAL_LIVE_CANARY_ENABLED", false, "random burn-in start")
    set_setting("MIGRATION_FULL_ALLOWED", false, "random burn-in start")
    set_setting("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED", false, "random burn-in start")
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
    pre_snapshot, pre_refresh_blockers = refresh_snapshot("pre_cycle")
    pre_target = target_payload(pre_snapshot, lp_refreshed: pre_refresh_blockers.empty?)
    pre_hedge = hedge_payload(pre_snapshot)
    pre_blockers, pre_status = pre_cycle_blockers(pre_snapshot, pre_refresh_blockers)
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
        result = executor.run(
          position: position,
          from_venue: route.fetch(:from_venue),
          to_venue: route.fetch(:to_venue),
          mode: "full",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          migration_sequence: "target_first"
        )
      end
      execution = execution_payload(result)
    else
      result = nil
      execution = zero_execution(status: "dry_run")
    end

    post_snapshot, post_refresh_blockers = refresh_snapshot("post_cycle")
    post_target = target_payload(post_snapshot, lp_refreshed: post_refresh_blockers.empty?, previous_target: decimal_or_nil(pre_target[:target_short_eth]))
    post_hedge = hedge_payload(post_snapshot)
    blockers, status = cycle_blockers(route: route, execution: execution, post_snapshot: post_snapshot, post_target: post_target, post_refresh_blockers: post_refresh_blockers)
    self.orders_submitted += execution.fetch(:orders_submitted)
    self.orders_placed += execution.fetch(:orders_placed)
    self.signatures_created += execution.fetch(:signatures_created)
    self.cycles_succeeded += 1 if status == "success"
    event = cycle_event(cycle: cycle, pre_target: pre_target, pre_hedge: pre_hedge, route: route, execution: execution, post_target: post_target, post_hedge: post_hedge, status: status, blockers: blockers)
    write_event(event)
    { status: status, blockers: blockers }
  end

  def select_route
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    routes = proof_registry.report(position: position).fetch(:routes).select do |route|
      route[:from_venue] == current && route[:status] == MigrationRouteProofRegistry::STATUSES[:ready]
    end
    return nil if routes.empty?
    return routes.find { |route| route[:route] == selector.call(routes) } || routes.first if selector

    routes[Random.new.rand(routes.size)]
  end

  def executor
    return executor_factory.call if executor_factory

    HedgeVenueMigrationExecutor.new(env: env)
  end

  def cycle_blockers(route:, execution:, post_snapshot:, post_target:, post_refresh_blockers:)
    blockers = []
    blockers.concat(post_refresh_blockers)
    return [ blockers, "stopped_stale_or_unavailable_lp_target" ] if blockers.any?

    target_delta = decimal_or_nil(post_target[:target_delta_eth]) || BigDecimal("0")
    self.max_target_delta_eth = [ max_target_delta_eth, target_delta ].max
    blockers << "target changed #{target_delta.to_s('F')} ETH during cycle; max allowed is #{max_target_change_per_cycle_eth.to_s('F')} ETH" if target_delta > max_target_change_per_cycle_eth
    blockers << "combined hedge is outside tolerance after migration" unless post_snapshot&.inside_tolerance == true
    blockers << "open orders are non-zero after migration" unless post_snapshot && open_orders_zero?(post_snapshot)
    if live?
      blockers << "migration result status is #{execution[:status]}" unless execution[:status].to_s.in?(%w[success MIGRATION_FINALIZED])
      blockers << "source venue #{route.fetch(:from_venue)} is not flat after migration" unless venue_short(post_snapshot, route.fetch(:from_venue)).zero?
      blockers << "target venue #{route.fetch(:to_venue)} does not hold expected short after migration" unless venue_short(post_snapshot, route.fetch(:to_venue)).positive?
      third = (VENUES - [ route.fetch(:from_venue), route.fetch(:to_venue) ]).first
      blockers << "third venue #{third} is not flat after migration" unless venue_short(post_snapshot, third).zero?
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
      blockers: Array(result.blockers)
    }
  end

  def zero_execution(status:)
    { status: status, orders_submitted: 0, orders_placed: 0, signatures_created: 0, receipt_path: nil, blockers: [] }
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
      final_combined_inside_tolerance: snapshot&.inside_tolerance == true,
      blocker_status: preflight_status(blockers),
      stale_pending_continuation_ignored: last_readiness_report[:stale_pending_continuation_ignored] == true,
      pending_nado_target_continuation_blocking: last_readiness_report[:pending_nado_target_continuation_blocking] == true,
      initial_target_short_eth: decimal_string(initial_target_short_eth),
      final_target_short_eth: decimal_string(final_target_short_eth || snapshot&.target_short_eth),
      max_target_delta_eth: decimal_string(max_target_delta_eth),
      target_refresh_failures: target_refresh_failures,
      disable_after: disable_after,
      migration_live_enabled_final: OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED"),
      migration_auto_enabled_final: OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED"),
      migration_random_rotation_live_enabled_final: OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    }
  end

  def result(status, blockers)
    Result.new(status, blockers, [], receipt_path.to_s, final_summary(status: status, blockers: blockers))
  end

  def hedge_payload(snapshot)
    {
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      extended_short_eth: decimal_string(snapshot&.extended_short_eth),
      ethereal_short_eth: decimal_string(snapshot&.ethereal_short_eth),
      nado_short_eth: decimal_string(snapshot&.nado_short_eth),
      target_short_eth: decimal_string(snapshot&.target_short_eth),
      combined_short_eth: decimal_string(snapshot&.combined_short_eth),
      inside_tolerance: snapshot&.inside_tolerance == true,
      open_orders_count: snapshot&.open_orders_count_extended.to_i,
      drift_eth: decimal_string(snapshot&.drift_eth),
      recommended_rebalance_eth: decimal_string(snapshot&.drift_eth)
    }
  end

  def target_payload(snapshot, lp_refreshed:, previous_target: nil)
    current_target = decimal_or_nil(snapshot&.target_short_eth)
    self.initial_target_short_eth ||= current_target
    self.final_target_short_eth = current_target if current_target
    target_delta = current_target && previous_target ? (current_target - previous_target).abs : nil
    self.max_target_delta_eth = [ max_target_delta_eth, target_delta ].compact.max if target_delta
    {
      asset0_amount: decimal_string(position.asset0_amount),
      asset1_amount: decimal_string(position.asset1_amount),
      target_short_eth: decimal_string(snapshot&.target_short_eth),
      target_source: target_source(snapshot),
      exposure_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      lp_refreshed: lp_refreshed,
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

  def pre_cycle_blockers(snapshot, refresh_blockers)
    blockers = Array(refresh_blockers)
    return [ blockers, "blocked_stale_or_unavailable_lp_target" ] if blockers.any?

    blockers << "LP target is stale or unavailable" unless trusted_snapshot?(snapshot)
    blockers << outside_tolerance_blocker(snapshot) if snapshot&.inside_tolerance != true && !rebalance_before_cycle
    active = snapshot ? active_short_venues(snapshot) : []
    blockers << "more than one venue has exposure" if active.size > 1
    blockers << "no venue has the production hedge" if active.empty?
    blockers << "open orders are non-zero before cycle" if snapshot && !open_orders_zero?(snapshot)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    blockers << "app production venue and actual venue exposure disagree" if active.one? && active.first != current
    blockers << "current production venue has no real short" if current.present? && snapshot && !venue_short(snapshot, current).positive?
    [ blockers.uniq, pre_cycle_status(blockers) ]
  end

  def trusted_snapshot?(snapshot)
    return false unless snapshot
    return false unless snapshot.refresh_status == "ok"
    return false unless snapshot.target_short_eth.present? && decimal(snapshot.target_short_eth).positive?
    return false if snapshot.respond_to?(:stale_now?) && snapshot.stale_now?

    true
  end

  def active_short_venues(snapshot)
    VENUES.select { |venue| decimal(snapshot.public_send("#{venue}_short_eth")).positive? }
  end

  def venue_short(snapshot, venue)
    decimal(snapshot&.public_send("#{venue}_short_eth"))
  end

  def open_orders_zero?(snapshot)
    snapshot.open_orders_count_extended.to_i.zero?
  end

  def pre_cycle_status(blockers)
    return "success" if blockers.empty?
    return "blocked_stale_or_unavailable_lp_target" if blockers.any? { |blocker| blocker.match?(/LP target|refresh failed|stale/i) }
    return "blocked_before_cycle_out_of_tolerance" if blockers.any? { |blocker| blocker.include?("outside tolerance") }
    return "blocked_open_orders_nonzero" if blockers.any? { |blocker| blocker.include?("open orders") }

    "blocked_unexpected_venue_exposure"
  end

  def preflight_status(blockers)
    return "success" if blockers.empty?
    return "blocked_before_cycle_out_of_tolerance" if blockers.any? { |blocker| blocker.include?("current hedge outside tolerance") }
    return "blocked_stale_or_unavailable_lp_target" if blockers.any? { |blocker| blocker.match?(/LP target|refresh failed|stale/i) }
    return "blocked_open_orders_nonzero" if blockers.any? { |blocker| blocker.include?("open orders") }

    "blocked_before_start"
  end

  def post_cycle_status(blockers)
    return "success" if blockers.empty?
    return "stopped_target_changed_too_much" if blockers.any? { |blocker| blocker.include?("target changed") }
    return "stopped_post_migration_out_of_tolerance" if blockers.any? { |blocker| blocker.include?("outside tolerance") }
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
      stale_pending_continuation_ignored: last_readiness_report[:stale_pending_continuation_ignored] == true,
      pending_nado_target_continuation_blocking: last_readiness_report[:pending_nado_target_continuation_blocking] == true,
      pending_nado_target_continuation: last_readiness_report[:pending_nado_target_continuation]
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
