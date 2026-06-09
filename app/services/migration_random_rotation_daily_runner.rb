class MigrationRandomRotationDailyRunner
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_random_rotation_daily")
  DEFAULT_DEBOUNCE_SECONDS = 1.hour

  Result = Data.define(:status, :positions, :blockers, :warnings, :orders_submitted, :signatures_created)

  def initialize(
    env: ENV,
    now: -> { Time.current },
    receipt_dir: RECEIPT_DIR,
    route_receipt_dir: HedgeVenueMigrationRouteMatrix::PROOF_RECEIPT_DIR,
    random_receipt_dir: HedgeVenueAutoMigrationPlanner::RECEIPT_DIR,
    state_dir: MigrationRandomRotationVirtualState::STATE_DIR,
    route_matrix_class: HedgeVenueMigrationRouteMatrix,
    planner_class: HedgeVenueAutoMigrationPlanner,
    snapshot_refresh_class: DashboardSnapshotRefresh,
    virtual_state_class: MigrationRandomRotationVirtualState,
    proof_registry: nil,
    preflight_factory: nil,
    executor_factory: nil,
    active_rebalance_factory: nil,
    active_rebalance_capability_matrix_factory: nil,
    rebalance_after_migration: true,
    rebalance_during_hold: true,
    rebalance_hold_interval_seconds: 300,
    rebalance_before_next_migration: true,
    rebalance_only_if_outside_tolerance: true,
    rebalance_max_attempts_per_cycle: 2,
    rebalance_readback_recheck_attempts: 4,
    rebalance_readback_recheck_interval_seconds: 5,
    sleeper: ->(seconds) { sleep(seconds) }
  )
    @env = env
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @route_receipt_dir = Pathname(route_receipt_dir)
    @random_receipt_dir = Pathname(random_receipt_dir)
    @state_dir = Pathname(state_dir)
    @route_matrix_class = route_matrix_class
    @planner_class = planner_class
    @snapshot_refresh_class = snapshot_refresh_class
    @virtual_state_class = virtual_state_class
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @preflight_factory = preflight_factory
    @executor_factory = executor_factory
    @active_rebalance_factory = active_rebalance_factory
    @active_rebalance_capability_matrix_factory = active_rebalance_capability_matrix_factory
    @rebalance_after_migration = ActiveModel::Type::Boolean.new.cast(rebalance_after_migration)
    @rebalance_during_hold = ActiveModel::Type::Boolean.new.cast(rebalance_during_hold)
    @rebalance_hold_interval_seconds = rebalance_hold_interval_seconds.to_i
    @rebalance_before_next_migration = ActiveModel::Type::Boolean.new.cast(rebalance_before_next_migration)
    @rebalance_only_if_outside_tolerance = ActiveModel::Type::Boolean.new.cast(rebalance_only_if_outside_tolerance)
    @rebalance_max_attempts_per_cycle = rebalance_max_attempts_per_cycle.to_i
    @rebalance_readback_recheck_attempts = rebalance_readback_recheck_attempts.to_i
    @rebalance_readback_recheck_interval_seconds = rebalance_readback_recheck_interval_seconds.to_i
    @sleeper = sleeper
  end

  def call(position_id: nil, force: false, seed: nil, enabled_override: false)
    daily_enabled = enabled_override || bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED")
    positions = target_positions(position_id)
    return missing_position_result(position_id) if position_id.present? && positions.empty?

    results = positions.map { |position| run_position(position, force: force, seed: seed, daily_enabled: daily_enabled, enabled_override: enabled_override) }
    Result.new(
      status: results.any? { |row| row[:status] == "error" } ? "partial" : "ok",
      positions: results,
      blockers: results.flat_map { |row| Array(row[:blockers]) }.uniq,
      warnings: results.flat_map { |row| Array(row[:warnings]) }.uniq,
      orders_submitted: results.sum { |row| row[:orders_submitted].to_i },
      signatures_created: results.sum { |row| row[:signatures_created].to_i }
    )
  end

  private

  attr_reader :env,
    :now,
    :receipt_dir,
    :route_receipt_dir,
    :random_receipt_dir,
    :state_dir,
    :route_matrix_class,
    :planner_class,
    :snapshot_refresh_class,
    :virtual_state_class,
    :proof_registry,
    :preflight_factory,
    :executor_factory,
    :active_rebalance_factory,
    :active_rebalance_capability_matrix_factory,
    :rebalance_after_migration,
    :rebalance_during_hold,
    :rebalance_hold_interval_seconds,
    :rebalance_before_next_migration,
    :rebalance_only_if_outside_tolerance,
    :rebalance_max_attempts_per_cycle,
    :rebalance_readback_recheck_attempts,
    :rebalance_readback_recheck_interval_seconds,
    :sleeper

  def run_position(position, force:, seed:, daily_enabled:, enabled_override:)
    lock_key = "migration_random_rotation_daily:position:#{position.id}"
    ran = false
    result = nil
    JobConcurrencyGuard.with_lock(lock_key) do
      ran = true
      if !force && recent_receipt?(position.id)
        result = skipped_receipt(position, reason: "debounce", daily_enabled: daily_enabled, enabled_override: enabled_override)
        write_daily_receipt(result)
        next
      end

      result = execute_workflow(position, seed: seed, daily_enabled: daily_enabled, enabled_override: enabled_override)
    end

    return skipped_receipt(position, reason: "lock", daily_enabled: daily_enabled, enabled_override: enabled_override) unless ran

    result
  rescue => e
    error = error_receipt(position, error: "#{e.class}: #{e.message}", daily_enabled: daily_enabled, enabled_override: enabled_override)
    write_daily_receipt(error)
    error
  end

  def execute_workflow(position, seed:, daily_enabled:, enabled_override:)
    return execute_live_workflow(position, seed: seed, daily_enabled: daily_enabled, enabled_override: enabled_override) if live_random_enabled?(daily_enabled)

    execute_read_only_workflow(position, seed: seed, daily_enabled: daily_enabled, enabled_override: enabled_override)
  end

  def execute_read_only_workflow(position, seed:, daily_enabled:, enabled_override:)
    direct = direct_preflight(position, live: false)
    watchdog = run_active_rebalance(position, reason: "daily_dry_run_watchdog", live: false)
    routes = eligible_routes_from_preflight(direct)
    selected_route = select_route(routes, seed: seed)
    warnings = Array(direct[:warnings])
    warnings << "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED is false; dry-run plan only." unless daily_enabled

    receipt = {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      production_venue: position.hedge&.execution_venue,
      current_production_venue: direct[:production_venue],
      current_venue: direct[:production_venue],
      active_venue_rebalance_watchdog: watchdog,
      route_proof_source: "READY_FOR_RANDOM",
      route_proof_status: direct.dig(:proof_report, :missing_route_proofs).blank? ? "READY_FOR_RANDOM" : "blocked",
      selected_route: selected_route,
      selected_target_venue: selected_route&.fetch(:to_venue, nil),
      eligible_random_routes: routes.map { |route| route.fetch(:route) },
      dry_run_eligible_routes: routes,
      live_blockers: live_gate_blockers(daily_enabled: daily_enabled),
      status: dry_run_status(direct: direct, watchdog: watchdog, routes: routes),
      blockers: (Array(direct[:blockers]) + Array(watchdog[:blockers])).uniq,
      warnings: warnings,
      auto_enabled: bool_env("MIGRATION_AUTO_ENABLED"),
      daily_enabled: daily_enabled,
      enabled_override: enabled_override,
      dry_run_only: true,
      virtual_mode: false,
      production_venue_mutated: false,
      hedge_execution_venue_after: position.hedge&.reload&.execution_venue,
      would_migrate: false,
      would_execute_live: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
    daily_receipt_path = write_daily_receipt(receipt)
    receipt.merge(receipt_path: daily_receipt_path&.to_s)
  end

  def execute_live_workflow(position, seed:, daily_enabled:, enabled_override:)
    direct = direct_preflight(position, live: true)
    capability_blockers = active_rebalance_capability_blockers(position)
    if capability_blockers.any?
      receipt = live_receipt(
        position: position,
        direct: direct,
        route: nil,
        result: nil,
        status: "blocked_before_submit",
        blockers: (Array(direct[:blockers]) + capability_blockers).uniq,
        enabled_override: enabled_override,
        daily_enabled: daily_enabled
      )
      write_daily_receipt(receipt)
      return receipt
    end

    pre_next_rebalance = rebalance_before_next_migration ? run_active_rebalance(position, reason: "pre_next_cycle", live: true) : nil
    direct = direct_preflight(position, live: true) if pre_next_rebalance
    route = direct.fetch(:blockers).empty? ? live_route_from_preflight(direct, seed: seed) : nil
    blockers = (Array(direct[:blockers]) + Array(pre_next_rebalance&.fetch(:blockers, []))).uniq
    blockers << "no READY_FOR_RANDOM route from current production venue" unless route || blockers.any?
    if blockers.any?
      receipt = live_receipt(
        position: position,
        direct: direct,
        route: route,
        result: nil,
        status: "blocked_before_submit",
        blockers: blockers,
        enabled_override: enabled_override,
        daily_enabled: daily_enabled,
        pre_next_rebalance: pre_next_rebalance
      )
      write_daily_receipt(receipt)
      return receipt
    end

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
          execution_preflight: direct
        )
    end
    receipt = live_receipt(
      position: position.reload,
      direct: direct,
      route: route,
      result: result,
      status: result.status,
      blockers: result.blockers,
      enabled_override: enabled_override,
      daily_enabled: daily_enabled,
      pre_next_rebalance: pre_next_rebalance,
      post_migration_rebalance: post_migration_rebalance(position, result)
    )
    write_daily_receipt(receipt)
    receipt
  end

  def live_receipt(position:, direct:, route:, result:, status:, blockers:, enabled_override:, daily_enabled:, pre_next_rebalance: nil, post_migration_rebalance: nil, hold_rebalance_checks: [])
    migration_receipt = result&.receipt || {}
    rebalance_blockers = Array(pre_next_rebalance&.fetch(:blockers, [])) +
      Array(post_migration_rebalance&.fetch(:blockers, [])) +
      hold_rebalance_checks.flat_map { |check| Array(check[:blockers]) }
    final_status = rebalance_blockers.any? ? "blocked_after_migration_rebalance" : status
    {
      action: "daily_random_rotation_live",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      production_venue: position.hedge&.execution_venue,
      current_venue: direct[:production_venue],
      selected_route: route,
      selected_target_venue: route&.fetch(:to_venue, nil),
      status: final_status,
      blockers: (Array(blockers) + rebalance_blockers).uniq,
      warnings: Array(direct[:warnings]) + Array(result&.warnings),
      auto_enabled: bool_env("MIGRATION_AUTO_ENABLED"),
      daily_enabled: daily_enabled,
      enabled_override: enabled_override,
      dry_run_only: false,
      virtual_mode: false,
      live_available: true,
      would_migrate: status.to_s.in?(%w[success MIGRATION_FINALIZED]) && rebalance_blockers.empty?,
      post_migration_rebalance: post_migration_rebalance || unchecked_rebalance_payload("post_migration"),
      hold_rebalance_checks: hold_rebalance_checks,
      pre_next_cycle_rebalance: pre_next_rebalance || unchecked_rebalance_payload("pre_next_cycle"),
      preflight_source: direct[:preflight_source],
      direct_preflight_blockers: Array(direct[:blockers]),
      direct_preflight_warnings: Array(direct[:warnings]),
      direct_venue_shorts: %w[extended ethereal nado].to_h { |venue| [ venue, direct.dig(:venues, venue, :short_eth)&.to_s("F") ] },
      direct_open_orders: %w[extended ethereal nado].to_h { |venue| [ venue, direct.dig(:venues, venue, :open_orders_status) ] },
      fresh_target: {
        target_short_eth: direct.dig(:target, :target_short_eth)&.to_s("F"),
        target_source: direct.dig(:target, :target_source),
        exposure_refreshed_at: direct.dig(:target, :exposure_refreshed_at)
      },
      migration_receipt_path: migration_receipt[:receipt_path],
      migration_timing: migration_timing_payload(migration_receipt),
      orders_submitted: migration_receipt.fetch(:orders_submitted, 0).to_i + rebalance_order_count(pre_next_rebalance, :orders_submitted) + rebalance_order_count(post_migration_rebalance, :orders_submitted),
      orders_placed: migration_receipt.fetch(:orders_placed, 0).to_i + rebalance_order_count(pre_next_rebalance, :orders_placed) + rebalance_order_count(post_migration_rebalance, :orders_placed),
      signatures_created: migration_receipt.fetch(:signatures_created, 0).to_i + rebalance_order_count(pre_next_rebalance, :signatures_created) + rebalance_order_count(post_migration_rebalance, :signatures_created)
    }
  end

  def disabled_result(position_id:)
    Result.new(
      status: "disabled",
      positions: [],
      blockers: [],
      warnings: [ "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED is false; daily random rotation dry-run skipped." ],
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def virtual_decision_selected?(decision_receipt)
    selected = decision_receipt[:selected_route] || decision_receipt["selected_route"]
    decision_receipt[:status] == "RANDOM_ROUTE_SELECTED" &&
      selected.present? &&
      selected.fetch(:virtual_decision_eligible, selected["virtual_decision_eligible"]) == true
  end

  def dry_run_status(direct:, watchdog:, routes:)
    return "blocked" if Array(direct[:blockers]).any? || Array(watchdog[:blockers]).any?

    routes.any? ? "RANDOM_ROUTE_SELECTED" : "NO_READY_FOR_RANDOM_ROUTE"
  end

  def missing_position_result(position_id)
    Result.new(
      status: "blocked",
      positions: [],
      blockers: [ "Position #{position_id} not found." ],
      warnings: [],
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  def skipped_receipt(position, reason:, enabled_override:)
    {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      current_venue: position.hedge&.execution_venue,
      status: "skipped",
      blockers: [],
      warnings: [ "Daily random rotation dry-run skipped: #{reason}." ],
      daily_enabled: true,
      enabled_override: enabled_override,
      dry_run_only: true,
      would_migrate: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def error_receipt(position, error:, enabled_override:)
    {
      action: "daily_random_rotation_dry_run",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      current_venue: position.hedge&.execution_venue,
      status: "error",
      blockers: [ error ],
      warnings: [],
      daily_enabled: true,
      enabled_override: enabled_override,
      dry_run_only: true,
      would_migrate: false,
      live_available: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def write_daily_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
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

  def direct_preflight(position, live:)
    if preflight_factory
      return preflight_factory.call(position: position, stage: "daily_random")
    end

    MigrationRandomExecutionPreflight.new(
      position: position,
      env: env,
      proof_registry: proof_registry,
      live: live
    ).report
  end

  def live_route_from_preflight(direct, seed:)
    current = HedgeVenues.normalize(direct[:production_venue])
    policy = MigrationRouteOperationalPolicy.new(env: env)
    routes = Array(direct.dig(:proof_report, :routes)).select do |route|
      route[:from_venue] == current &&
        route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] &&
        policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
    return nil if routes.empty?

    random = seed.present? ? Random.new(Digest::SHA256.hexdigest(seed.to_s).to_i(16) % (2**31)) : Random.new
    routes[random.rand(routes.size)]
  end

  def executor
    return executor_factory.call if executor_factory

    HedgeVenueMigrationExecutor.new(env: env)
  end

  def post_migration_rebalance(position, migration_result)
    return nil unless rebalance_after_migration
    return nil unless migration_result&.status.to_s.in?(%w[success MIGRATION_FINALIZED])

    run_active_rebalance(position, reason: "post_migration", live: true)
  end

  def run_active_rebalance(position, reason:, live:)
    active_rebalancer(position, live: live).run(reason: reason)
  end

  def active_rebalancer(position, live:)
    return active_rebalance_factory.call(position: position) if active_rebalance_factory

    ActiveVenueOneShotRebalance.new(
      position: position,
      live: live,
      env: env,
      preflight_factory: ->(position:, stage:) { direct_preflight(position, live: live) },
      max_attempts: rebalance_max_attempts_per_cycle,
      only_if_outside_tolerance: rebalance_only_if_outside_tolerance,
      recheck_attempts: rebalance_readback_recheck_attempts,
      recheck_interval_seconds: rebalance_readback_recheck_interval_seconds,
      sleeper: sleeper,
      now: now
    )
  end

  def active_rebalance_capability_blockers(position)
    matrix = if active_rebalance_capability_matrix_factory
      active_rebalance_capability_matrix_factory.call(position: position)
    else
      ActiveVenueRebalanceCapabilityMatrix.new(position: position, env: env)
    end
    Array(matrix.report[:blockers])
  end

  def rebalance_order_count(payload, key)
    payload ? payload[key].to_i : 0
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

  def enable_route_live_gates(route)
    return unless [ route.fetch(:from_venue), route.fetch(:to_venue) ].include?("nado")

    OperationalSettings.set!(key: "AERODROME_NADO_HEDGE_LIVE_ENABLED", enabled: true, reason: "daily random rotation route #{route.fetch(:route)}")
    OperationalSettings.set!(key: "AERODROME_NADO_LIVE_MIGRATION_ENABLED", enabled: true, reason: "daily random rotation route #{route.fetch(:route)}")
  end

  def eligible_routes_from_preflight(direct)
    current = HedgeVenues.normalize(direct[:production_venue])
    policy = MigrationRouteOperationalPolicy.new(env: env)
    Array(direct.dig(:proof_report, :routes)).select do |route|
      route[:from_venue] == current &&
        route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] &&
        policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
  end

  def select_route(routes, seed:)
    return nil if routes.empty?

    random = seed.present? ? Random.new(Digest::SHA256.hexdigest(seed.to_s).to_i(16) % (2**31)) : Random.new
    routes[random.rand(routes.size)]
  end

  def live_gate_blockers(daily_enabled:)
    blockers = []
    blockers << "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED must be true for live daily random rotation" unless daily_enabled
    blockers << "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers
  end

  def live_random_enabled?(daily_enabled)
    daily_enabled &&
    bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED") &&
      bool_env("MIGRATION_AUTO_ENABLED") &&
      bool_env("MIGRATION_LIVE_ENABLED")
  end

  def recent_receipt?(position_id)
    latest = latest_daily_receipt(position_id)
    return false unless latest

    timestamp = Time.zone.parse(latest.fetch("timestamp"))
    timestamp > now.call - debounce_seconds.seconds
  rescue ArgumentError, KeyError
    false
  end

  def latest_daily_receipt(position_id)
    Dir.glob(receipt_dir.join("*.jsonl")).sort.reverse_each do |path|
      File.readlines(path).reverse_each do |line|
        receipt = JSON.parse(line)
        return receipt if receipt["position_id"].to_s == position_id.to_s && receipt["action"] == "daily_random_rotation_dry_run"
      rescue JSON::ParserError
        next
      end
    end
    nil
  rescue SystemCallError
    nil
  end

  def target_positions(position_id)
    scope = Position.includes(:dex, :hedge, :position_dashboard_snapshot)
      .joins(:dex, :hedge)
      .where(active: true, dexes: { name: "aerodrome_slipstream" }, hedges: { active: true })
    position_id.present? ? scope.where(id: position_id).to_a : scope.to_a
  end

  def debounce_seconds
    Integer(env.fetch("MIGRATION_RANDOM_ROTATION_DAILY_DEBOUNCE_SECONDS", DEFAULT_DEBOUNCE_SECONDS.to_i.to_s))
  rescue ArgumentError
    DEFAULT_DEBOUNCE_SECONDS.to_i
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
