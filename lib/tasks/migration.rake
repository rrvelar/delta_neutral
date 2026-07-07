namespace :migration do
  desc "Write read-only hedge venue migration route proof receipts for a position"
  task prove_routes: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "migration_route_proof_summary",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    task_started_at = Time.current
    refresh_result = refresh_snapshot_for_route_proof(position)
    position.reload
    snapshot = position.position_dashboard_snapshot
    fallback_result = ensure_snapshot_migration_fields(position, snapshot)
    snapshot = position.position_dashboard_snapshot.reload if fallback_result[:updated]
    proof_started_at = Time.current
    snapshot_age_at_start = snapshot_age_seconds(snapshot, at: proof_started_at)
    snapshot_status_at_start = snapshot_status(snapshot, at: proof_started_at)
    if refresh_result[:error].present?
      puts JSON.pretty_generate(
        status: "blocked",
        action: "migration_route_proof_summary",
        position_id: position.id,
        blockers: [ "Snapshot refresh before route proof failed: #{refresh_result[:error]}" ],
        snapshot_refreshed_before_proof: refresh_result.fetch(:refreshed),
        proof_started_at: proof_started_at.utc.iso8601,
        snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
        snapshot_age_seconds_at_start: snapshot_age_at_start,
        snapshot_status_at_start: snapshot_status_at_start,
        route_plans_used_fresh_snapshot: false,
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    summary = HedgeVenueMigrationRouteMatrix.new(position: position, snapshot: snapshot, now: -> { proof_started_at }).prove_routes!
    proof_finished_at = Time.current
    summary.merge!(
      snapshot_refreshed_before_proof: refresh_result.fetch(:refreshed),
      proof_started_at: proof_started_at.utc.iso8601,
      proof_finished_at: proof_finished_at.utc.iso8601,
      proof_duration_seconds: (proof_finished_at - task_started_at).round(3),
      snapshot_refreshed_at: snapshot&.refreshed_at&.utc&.iso8601,
      snapshot_missing_fields: snapshot&.missing_migration_fields,
      snapshot_age_seconds_at_start: snapshot_age_at_start,
      snapshot_status_at_start: snapshot_status_at_start,
      snapshot_age_seconds_at_end: snapshot_age_seconds(snapshot, at: proof_finished_at),
      snapshot_status_at_end: snapshot_status(snapshot, at: proof_finished_at),
      route_plans_used_fresh_snapshot: snapshot_status_at_start == "fresh",
      route_plans_used_complete_snapshot: snapshot&.migration_complete_for_proof?,
      snapshot_refresh_reason: refresh_result[:reason],
      snapshot_fallback_warning: fallback_result[:warning]
    ).compact!
    puts JSON.pretty_generate(summary)
  end

  desc "Print read-only canonical migration route matrix for a position"
  task route_matrix: :environment do
    position = migration_position_from_env(action: "migration_route_matrix")
    next unless position

    puts JSON.pretty_generate(HedgeVenueMigrationRouteMatrix.new(position: position).report.merge(action: "migration_route_matrix"))
  end

  desc "Print route proof registry status for all six migration routes"
  task route_proofs: :environment do
    position = migration_position_from_env(action: "migration_route_proofs")
    next unless position

    puts JSON.pretty_generate(MigrationRouteProofRegistry.new.report(position: position))
  end

  desc "Show actionable random migration readiness and next operator commands"
  task random_readiness: :environment do
    position = migration_position_from_env(action: "migration_random_readiness")
    next unless position

    puts JSON.pretty_generate(MigrationRandomReadiness.new(position: position).report)
  end

  desc "Rehearse one random eligible target-first migration route without live actions"
  task random_rehearse: :environment do
    position = migration_position_from_env(action: "migration_random_rehearse")
    next unless position

    dry_run = ENV["dry_run"].present? || ENV["DRY_RUN"].present? ? ActiveModel::Type::Boolean.new.cast(ENV["dry_run"].presence || ENV["DRY_RUN"]) : true
    result = MigrationRandomRehearsal.new.run(position: position, dry_run: dry_run)
    puts JSON.pretty_generate(result.receipt.merge(action: "migration_random_rehearse"))
  end

  desc "Show canary ladder status and next route to prove"
  task canary_ladder: :environment do
    position = migration_position_from_env(action: "migration_canary_ladder")
    next unless position

    readiness = MigrationRandomReadiness.new(position: position).report
    puts JSON.pretty_generate(readiness.merge(action: "migration_canary_ladder"))
  end

  desc "Show the next supervised canary route and exact commands"
  task next_canary: :environment do
    position = migration_position_from_env(action: "migration_next_canary")
    next unless position

    readiness = MigrationRandomReadiness.new(position: position).report
    puts JSON.pretty_generate(
      action: "migration_next_canary",
      position_id: position.id,
      next_recommended_canary: readiness[:next_recommended_canary],
      operator_commands: readiness[:operator_commands],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )
  end

  desc "Rehearse the next supervised canary route without live actions"
  task rehearse_next_canary: :environment do
    position = migration_position_from_env(action: "migration_rehearse_next_canary")
    next unless position

    next_canary = MigrationRandomReadiness.new(position: position).report[:next_recommended_canary]
    unless next_canary
      puts JSON.pretty_generate(action: "migration_rehearse_next_canary", position_id: position.id, blockers: [ "No next canary route found." ], orders_submitted: 0, signatures_created: 0)
      next
    end

    plan = MigrationManualCanaryPlanner.new(position: position, from: next_canary[:from_venue], to: next_canary[:to_venue], sequence: "target_first").report
    receipt = plan.merge(action: "migration_rehearse_next_canary", dry_run: true, live: false, orders_submitted: 0, orders_placed: 0, signatures_created: 0)
    path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_route_rehearsals")).write(receipt)
    puts JSON.pretty_generate(receipt.merge(receipt_path: path&.to_s))
  end

  desc "Write a read-only random venue rotation decision receipt for a position"
  task random_rotation_decision: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "random_rotation_decision",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    matrix = HedgeVenueMigrationRouteMatrix.new(position: position).report
    use_virtual_state = ActiveModel::Type::Boolean.new.cast(ENV["use_virtual_state"].presence || ENV["USE_VIRTUAL_STATE"])
    state = use_virtual_state ? MigrationRandomRotationVirtualState.new(position: position).current : nil
    planner = HedgeVenueAutoMigrationPlanner.new(
      route_matrix: matrix,
      current_venue_override: state&.fetch(:virtual_current_venue, nil),
      virtual_mode: use_virtual_state
    )
    result = planner.plan(position: position)
    path = planner.write_receipt(result.receipt)
    puts JSON.pretty_generate(result.receipt.merge(receipt_path: path&.to_s, virtual_state: state).compact)
  end

  desc "Run the read-only daily random rotation dry-run workflow"
  task daily_random_rotation_dry_run: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    force = ActiveModel::Type::Boolean.new.cast(ENV["force"].presence || ENV["FORCE"])
    enabled_override = ActiveModel::Type::Boolean.new.cast(ENV["enabled_override"].presence || ENV["ENABLED_OVERRIDE"])
    seed = ENV["seed"].presence || ENV["MIGRATION_RANDOM_SEED"].presence
    result = MigrationRandomRotationDailyRunner.new.call(
      position_id: position_id,
      force: force,
      seed: seed,
      enabled_override: enabled_override
    )

    puts JSON.pretty_generate(
      action: "daily_random_rotation_dry_run_summary",
      status: result.status,
      position_id: position_id,
      positions: result.positions,
      blockers: result.blockers,
      warnings: result.warnings,
      orders_submitted: result.orders_submitted,
      signatures_created: result.signatures_created
    )
  end

  desc "Show latest daily random rotation receipt"
  task daily_random_rotation_status: :environment do
    position = migration_position_from_env(action: "daily_random_rotation_status")
    next unless position

    path = Dir.glob(MigrationRandomRotationDailyRunner::RECEIPT_DIR.join("*.jsonl")).sort.reverse_each.find do |candidate|
      File.readlines(candidate).any? { |line| (JSON.parse(line)["position_id"].to_s == position.id.to_s rescue false) }
    rescue SystemCallError
      false
    end
    unless path
      puts JSON.pretty_generate(action: "daily_random_rotation_status", position_id: position.id, status: "missing")
      next
    end
    latest = File.readlines(path).reverse_each.filter_map do |line|
      payload = JSON.parse(line) rescue nil
      payload if payload&.fetch("position_id", nil).to_s == position.id.to_s
    end.first
    puts JSON.pretty_generate(action: "daily_random_rotation_status", position_id: position.id, status: "ok", receipt_path: path.to_s, latest_event: latest)
  end

  desc "Run supervised bounded random rotation burn-in with JSONL logging"
  task random_burn_in: :environment do
    position = migration_position_from_env(action: "migration_random_burn_in")
    next unless position

    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    disable_after = ENV["disable_after"].present? || ENV["DISABLE_AFTER"].present? ? ActiveModel::Type::Boolean.new.cast(ENV["disable_after"].presence || ENV["DISABLE_AFTER"]) : true
    result = MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: (ENV["duration_minutes"].presence || ENV["DURATION_MINUTES"].presence || 30),
      interval_seconds: (ENV["interval_seconds"].presence || ENV["INTERVAL_SECONDS"].presence || 120),
      max_cycles: (ENV["max_cycles"].presence || ENV["MAX_CYCLES"].presence || 12),
      live: live,
      disable_after: disable_after,
      confirmation: ENV["confirmation"].presence || ENV["CONFIRMATION"].presence,
      rebalance_before_cycle: ActiveModel::Type::Boolean.new.cast(ENV["rebalance_before_cycle"].presence || ENV["REBALANCE_BEFORE_CYCLE"]),
      max_target_change_per_cycle_eth: (ENV["max_target_change_per_cycle_eth"].presence || ENV["MAX_TARGET_CHANGE_PER_CYCLE_ETH"].presence || "0.15"),
      burn_in_tolerance_multiplier: (ENV["burn_in_tolerance_multiplier"].presence || ENV["BURN_IN_TOLERANCE_MULTIPLIER"].presence || "1.0"),
      burn_in_extra_tolerance_eth: (ENV["burn_in_extra_tolerance_eth"].presence || ENV["BURN_IN_EXTRA_TOLERANCE_ETH"].presence || "0"),
      burn_in_max_allowed_drift_eth: (ENV["burn_in_max_allowed_drift_eth"].presence || ENV["BURN_IN_MAX_ALLOWED_DRIFT_ETH"].presence || "0.15"),
      burn_in_max_allowed_drift_ratio: (ENV["burn_in_max_allowed_drift_ratio"].presence || ENV["BURN_IN_MAX_ALLOWED_DRIFT_RATIO"].presence || "0.08"),
      rebalance_after_migration: ENV.fetch("rebalance_after_migration", ENV.fetch("REBALANCE_AFTER_MIGRATION", "true")),
      rebalance_during_hold: ENV.fetch("rebalance_during_hold", ENV.fetch("REBALANCE_DURING_HOLD", "false")),
      rebalance_hold_interval_seconds: ENV.fetch("rebalance_hold_interval_seconds", ENV.fetch("REBALANCE_HOLD_INTERVAL_SECONDS", "300")),
      rebalance_before_next_migration: ENV.fetch("rebalance_before_next_migration", ENV.fetch("REBALANCE_BEFORE_NEXT_MIGRATION", "true")),
      rebalance_only_if_outside_tolerance: ENV.fetch("rebalance_only_if_outside_tolerance", ENV.fetch("REBALANCE_ONLY_IF_OUTSIDE_TOLERANCE", "true")),
      rebalance_max_attempts_per_cycle: ENV.fetch("rebalance_max_attempts_per_cycle", ENV.fetch("REBALANCE_MAX_ATTEMPTS_PER_CYCLE", "2")),
      rebalance_readback_recheck_attempts: ENV.fetch("rebalance_readback_recheck_attempts", ENV.fetch("REBALANCE_READBACK_RECHECK_ATTEMPTS", "4")),
      rebalance_readback_recheck_interval_seconds: ENV.fetch("rebalance_readback_recheck_interval_seconds", ENV.fetch("REBALANCE_READBACK_RECHECK_INTERVAL_SECONDS", "5"))
    ).run
    puts JSON.pretty_generate(result.summary.merge(action: "migration_random_burn_in", receipt_path: result.receipt_path))
    abort("migration_random_burn_in #{result.status}") unless result.status == "success"
  end

  desc "Show latest supervised random burn-in log path and final event"
  task random_burn_in_status: :environment do
    position = migration_position_from_env(action: "migration_random_burn_in_status")
    next unless position

    path = MigrationRandomBurnInRunner::LOG_DIR.join("latest_position_#{position.id}.jsonl")
    unless File.exist?(path)
      puts JSON.pretty_generate(action: "migration_random_burn_in_status", position_id: position.id, status: "missing", log_path: path.to_s)
      next
    end
    last = File.readlines(path).reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.first
    puts JSON.pretty_generate(action: "migration_random_burn_in_status", position_id: position.id, status: "ok", log_path: path.to_s, latest_event: last)
  end

  desc "Print the latest supervised random burn-in JSONL log"
  task random_burn_in_tail: :environment do
    position = migration_position_from_env(action: "migration_random_burn_in_tail")
    next unless position

    path = MigrationRandomBurnInRunner::LOG_DIR.join("latest_position_#{position.id}.jsonl")
    lines = (ENV["lines"].presence || ENV["LINES"].presence || 100).to_i
    unless File.exist?(path)
      puts JSON.pretty_generate(action: "migration_random_burn_in_tail", position_id: position.id, status: "missing", log_path: path.to_s)
      next
    end
    puts File.readlines(path).last(lines).join
  end

  desc "Run 24/7 production random rotation using the proven random burn-in path"
  task random_production_runner: :environment do
    position = migration_position_from_env(action: "migration_random_production_runner")
    next unless position

    result = MigrationRandomProductionRunner.new(
      position: position,
      live: ENV.fetch("live", ENV.fetch("LIVE", "true")),
      confirmation: ENV["confirmation"].presence || ENV["CONFIRMATION"].presence,
      duration_minutes: ENV.fetch("duration_minutes", ENV.fetch("DURATION_MINUTES", "0")),
      interval_seconds: ENV.fetch("interval_seconds", ENV.fetch("INTERVAL_SECONDS", MigrationRandomProductionRunner::DEFAULT_INTERVAL_SECONDS.to_s)),
      rebalance_hold_interval_seconds: ENV.fetch("rebalance_hold_interval_seconds", ENV.fetch("REBALANCE_HOLD_INTERVAL_SECONDS", MigrationRandomProductionRunner::DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS.to_s)),
      rebalance_after_migration: ENV.fetch("rebalance_after_migration", ENV.fetch("REBALANCE_AFTER_MIGRATION", "true")),
      rebalance_during_hold: ENV.fetch("rebalance_during_hold", ENV.fetch("REBALANCE_DURING_HOLD", "true")),
      rebalance_before_next_migration: ENV.fetch("rebalance_before_next_migration", ENV.fetch("REBALANCE_BEFORE_NEXT_MIGRATION", "true")),
      rebalance_only_if_outside_tolerance: ENV.fetch("rebalance_only_if_outside_tolerance", ENV.fetch("REBALANCE_ONLY_IF_OUTSIDE_TOLERANCE", "true")),
      rebalance_readback_recheck_attempts: ENV.fetch("rebalance_readback_recheck_attempts", ENV.fetch("REBALANCE_READBACK_RECHECK_ATTEMPTS", "4")),
      rebalance_readback_recheck_interval_seconds: ENV.fetch("rebalance_readback_recheck_interval_seconds", ENV.fetch("REBALANCE_READBACK_RECHECK_INTERVAL_SECONDS", "5"))
    ).run
    puts JSON.pretty_generate(result.summary.merge(action: "migration_random_production_runner", receipt_path: result.receipt_path))
    abort("migration_random_production_runner #{result.status}") unless result.status.in?(%w[success stopped])
  end

  desc "Show production random rotation runner status for a position"
  task random_production_status: :environment do
    position = migration_position_from_env(action: "migration_random_production_status")
    next unless position

    puts JSON.pretty_generate(MigrationRandomProductionRunner.new(position: position, live: false).status.merge(action: "migration_random_production_status"))
  end

  desc "Print the latest production random rotation JSONL log"
  task random_production_tail: :environment do
    position = migration_position_from_env(action: "migration_random_production_tail")
    next unless position

    path = MigrationRandomProductionRunner::LOG_DIR.join("latest_position_#{position.id}.jsonl")
    lines = (ENV["lines"].presence || ENV["LINES"].presence || 300).to_i
    unless File.exist?(path)
      puts JSON.pretty_generate(action: "migration_random_production_tail", position_id: position.id, status: "missing", log_path: path.to_s)
      next
    end
    puts File.readlines(path).last(lines).join
  end

  desc "Request safe stop for production random rotation runner"
  task random_production_stop: :environment do
    position = migration_position_from_env(action: "migration_random_production_stop")
    next unless position

    payload = MigrationRandomProductionRunner.new(position: position, live: false).stop!
    puts JSON.pretty_generate(payload.merge(action: "migration_random_production_stop"))
  end

  desc "Run active-venue one-shot rebalance watchdog; dry-run by default"
  task active_venue_rebalance_watchdog: :environment do
    position = migration_position_from_env(action: "active_venue_rebalance_watchdog")
    next unless position

    result = MigrationActiveVenueRebalanceWatchdog.new(
      position: position,
      live: ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"]),
      interval_seconds: ENV["interval_seconds"].presence || ENV["INTERVAL_SECONDS"].presence || 300,
      duration_minutes: ENV["duration_minutes"].presence || ENV["DURATION_MINUTES"].presence,
      once: ENV.fetch("once", ENV.fetch("ONCE", "true")),
      disable_after: ENV.fetch("disable_after", ENV.fetch("DISABLE_AFTER", "false")),
      rebalance_only_if_outside_tolerance: ENV.fetch("rebalance_only_if_outside_tolerance", ENV.fetch("REBALANCE_ONLY_IF_OUTSIDE_TOLERANCE", "true")),
      rebalance_readback_recheck_attempts: ENV.fetch("rebalance_readback_recheck_attempts", ENV.fetch("REBALANCE_READBACK_RECHECK_ATTEMPTS", "4")),
      rebalance_readback_recheck_interval_seconds: ENV.fetch("rebalance_readback_recheck_interval_seconds", ENV.fetch("REBALANCE_READBACK_RECHECK_INTERVAL_SECONDS", "5"))
    ).run
    puts JSON.pretty_generate(result.summary.merge(action: "active_venue_rebalance_watchdog", receipt_path: result.receipt_path))
    abort("active_venue_rebalance_watchdog #{result.status}") unless result.status == "success"
  end

  desc "Show latest active-venue rebalance watchdog event"
  task active_venue_rebalance_watchdog_status: :environment do
    position = migration_position_from_env(action: "active_venue_rebalance_watchdog_status")
    next unless position

    path = MigrationActiveVenueRebalanceWatchdog::LOG_DIR.join("latest_position_#{position.id}.jsonl")
    unless File.exist?(path)
      puts JSON.pretty_generate(action: "active_venue_rebalance_watchdog_status", position_id: position.id, status: "missing", log_path: path.to_s)
      next
    end
    last = File.readlines(path).reverse_each.filter_map { |line| JSON.parse(line) rescue nil }.first
    puts JSON.pretty_generate(action: "active_venue_rebalance_watchdog_status", position_id: position.id, status: "ok", log_path: path.to_s, latest_event: last)
  end

  desc "Show read-only active-venue rebalance capability matrix"
  task active_venue_rebalance_capabilities: :environment do
    position = migration_position_from_env(action: "active_venue_rebalance_capabilities")
    next unless position

    required_max_drift_eth = ENV["required_max_drift_eth"].presence || ENV["REQUIRED_MAX_DRIFT_ETH"].presence
    report = ActiveVenueRebalanceCapabilityMatrix.new(
      position: position,
      required_max_drift_eth: required_max_drift_eth
    ).report
    puts JSON.pretty_generate(report)
    abort("active_venue_rebalance_capabilities blocked") unless report[:blockers].empty?
  end

  desc "Show read-only random rotation virtual state for a position"
  task random_rotation_state: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "random_rotation_state",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    state = MigrationRandomRotationVirtualState.new(position: position).current
    puts JSON.pretty_generate(state.merge(action: "random_rotation_state", status: "ok"))
  end

  desc "Reset read-only random rotation virtual state to the production venue"
  task reset_random_rotation_state: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        status: "blocked",
        action: "reset_random_rotation_state",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    state = MigrationRandomRotationVirtualState.new(position: position).reset!
    puts JSON.pretty_generate(state.merge(action: "reset_random_rotation_state", status: "ok"))
  end

  desc "Show read-only live autopilot readiness for a position"
  task live_autopilot_readiness: :environment do
    position = migration_position_from_env(action: "live_autopilot_readiness")
    next unless position

    puts JSON.pretty_generate(MigrationLiveAutopilotReadiness.new(position: position).report)
  end

  desc "Show read-only supervised manual live canary readiness for one route"
  task manual_live_canary_readiness: :environment do
    position = migration_position_from_env(action: "manual_live_canary_readiness")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    sequence = ENV["sequence"].presence || ENV["SEQUENCE"].presence || "target_first"
    puts JSON.pretty_generate(MigrationManualLiveCanaryReadiness.new(position: position, from: from, to: to, sequence: sequence).report)
  end

  desc "Run gated supervised manual live canary if all live gates are open"
  task run_manual_live_canary: :environment do
    position = migration_position_from_env(action: "run_manual_live_canary")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    sequence = ENV["sequence"].presence || ENV["SEQUENCE"].presence || "target_first"
    result = MigrationManualLiveCanaryRunner.new.run(position: position, from: from, to: to, confirmation: confirmation, sequence: sequence)
    puts JSON.pretty_generate(result.receipt)
  end

  desc "Read-only: show which gates a supervised manual canary needs and their current state"
  task manual_canary_gate_status: :environment do
    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    puts JSON.pretty_generate(MigrationManualCanaryGates.new(from: from, to: to).status)
  end

  desc "Arm the DB-backed gates for ONE supervised manual canary (requires confirmation). Always disarm afterwards."
  task arm_manual_canary_gates: :environment do
    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationManualCanaryGates.new(from: from, to: to).arm!(confirmation: confirmation)
    puts JSON.pretty_generate(result)
  end

  desc "Disarm ALL manual-canary DB gates back to false (fail-closed cleanup; run after every canary or failure)"
  task disarm_manual_canary_gates: :environment do
    puts JSON.pretty_generate(MigrationManualCanaryGates.disarm!)
  end

  desc "Prove route latency safety for a migration route"
  task prove_route_latency: :environment do
    position = migration_position_from_env(action: "prove_route_latency")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    strategy = ENV["strategy"].presence || ENV["STRATEGY"].presence || MigrationRouteOperationalPolicy.new.route_strategy(from: from, to: to)
    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    expected_confirmation = "I_UNDERSTAND_THIS_RUNS_LIVE_ROUTE_LATENCY_PROOF"
    if live && confirmation != expected_confirmation
      payload = {
        action: "prove_route_latency",
        status: "blocked_before_submit",
        blockers: [ "confirmation must equal #{expected_confirmation}" ],
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      }
      puts JSON.pretty_generate(payload)
      next
    end

    if live
      preflight = MigrationExecutionPreflight.new(
        position: position,
        from: from,
        to: to,
        strategy: strategy,
        live: true,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        expected_confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        require_migration_live_gate: true,
        require_venue_live_gates: true
      ).report
      result = HedgeVenueMigrationExecutor.new.run(
        position: position,
        from_venue: from,
        to_venue: to,
        mode: "full",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        migration_sequence: strategy,
        execution_preflight: preflight
      )
      receipt = result.receipt.merge(
        action: "prove_route_latency",
        strategy: strategy,
        route_latency_proof: true,
        production_safe: result.status.to_s.in?(%w[success MIGRATION_FINALIZED]) && result.receipt[:route_production_safe] != false
      )
      if receipt[:production_safe]
        OperationalSettings.set!(key: OperationalSettings.route_key_for(from, to), enabled: true, reason: "route latency proof passed")
        OperationalSettings.set!(key: OperationalSettings.route_strategy_key_for(from, to), enabled: strategy, reason: "route latency proof strategy")
      end
      path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_route_latency_proofs")).write(receipt)
      puts JSON.pretty_generate(receipt.merge(receipt_path: path&.to_s))
    else
      result = HedgeVenueMigrationExecutor.new.run(
        position: position,
        from_venue: from,
        to_venue: to,
        mode: "full",
        dry_run: true,
        full_migration_allowed: true,
        migration_sequence: strategy
      )
      receipt = result.receipt.merge(
        action: "prove_route_latency",
        strategy: strategy,
        route_latency_proof: false,
        production_safe: false,
        double_exposure_seconds: strategy == "source_first" ? "0" : nil,
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      )
      path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_route_latency_proofs")).write(receipt)
      puts JSON.pretty_generate(receipt.merge(receipt_path: path&.to_s))
    end
  end

  desc "Rehearse a migration route without signing or submitting"
  task rehearse_route: :environment do
    position = migration_position_from_env(action: "migration_rehearse_route")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    sequence = ENV["sequence"].presence || ENV["SEQUENCE"].presence || MigrationRouteOperationalPolicy.new.route_strategy(from: from, to: to)
    preflight = MigrationExecutionPreflight.new(
      position: position,
      from: from,
      to: to,
      strategy: sequence,
      live: false
    ).report
    plan = MigrationManualCanaryPlanner.new(position: position, from: from, to: to, sequence: sequence, execution_preflight: preflight).report
    receipt = plan.merge(
      action: "migration_rehearse_route",
      dry_run: true,
      live: false,
      rehearsal_status: plan[:blockers].empty? ? "ready_no_live" : "blocked_no_live",
      readback_verification: {
        target_leg: "confirm #{plan[:to_venue]} short equals planned_target_leg.expected_after_short_eth within venue rounding tolerance",
        source_leg: "confirm #{plan[:from_venue]} short equals planned_source_leg.expected_after_short_eth within venue rounding tolerance",
        final: "confirm source flat, target holds fresh target, other venue flat, combined inside tolerance"
      },
      recovery_plan: {
        target_first_second_leg_failed: "close source with reduce-only buy or rollback target with reduce-only buy after fresh readback and exact recovery confirmation",
        first_leg_failed: "do not submit second leg; refresh readback before any retry"
      },
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )
    path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: Rails.root.join("storage/hedge_migration_route_rehearsals")).write(receipt)
    puts JSON.pretty_generate(receipt.merge(receipt_path: path&.to_s))
  end

  desc "Recover target-first partial overhedge by closing only the Extended source leg"
  task recover_target_first_source_close: :environment do
    position = migration_position_from_env(action: "recover_target_first_source_close")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    dry_run = ENV["dry_run"].present? || ENV["DRY_RUN"].present? ? ActiveModel::Type::Boolean.new.cast(ENV["dry_run"].presence || ENV["DRY_RUN"]) : !live
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationTargetFirstSourceRecovery.new(
      position: position,
      from: from,
      to: to,
      dry_run: dry_run,
      live: live,
      confirmation: confirmation
    ).run
    puts JSON.pretty_generate(result.receipt)
  end

  desc "Continue a target-first migration after accepted Nado target readback confirms"
  task continue_target_first_after_nado_confirmed: :environment do
    position = migration_position_from_env(action: "continue_target_first_after_nado_confirmed")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence
    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    dry_run = ENV["dry_run"].present? || ENV["DRY_RUN"].present? ? ActiveModel::Type::Boolean.new.cast(ENV["dry_run"].presence || ENV["DRY_RUN"]) : !live
    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationTargetNadoContinuation.new(
      position: position,
      from: from,
      to: to,
      dry_run: dry_run,
      live: live,
      confirmation: confirmation
    ).run
    puts JSON.pretty_generate(result.receipt)
  end

  desc "Reconcile an accepted source-first Nado target digest by readback only"
  task reconcile_nado_source_first: :environment do
    position = migration_position_from_env(action: "reconcile_nado_source_first")
    next unless position

    from = ENV["from"].presence || ENV["FROM"].presence
    to = ENV["to"].presence || ENV["TO"].presence || "nado"
    digest = ENV["digest"].presence || ENV["DIGEST"].presence
    snapshot = position.position_dashboard_snapshot
    readback = NadoMigrationReadback.confirm_target_short(
      position: position,
      from: from,
      to: to,
      expected_target_short: snapshot&.target_short_eth,
      tolerance_eth: snapshot&.tolerance_abs_eth,
      env: ENV
    )
    reconciler = MigrationRouteCompletionReconciler.new(position: position, from: from, to: to, receipt_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR)
    current = reconciler.report
    result = if readback.fetch(:confirmed) && current.route_complete_by_readback && current.production_venue_finalized
      reconciler.write_ready_receipt!(status: "SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK")
    else
      current
    end
    receipt = result.receipt.merge(
      action: "reconcile_nado_source_first",
      nado_target_digest: digest,
      nado_target_exchange_order_id: digest,
      canonical_nado_readback: readback.except(:verification),
      canonical_nado_verification: readback[:verification],
      submitted: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )
    puts JSON.pretty_generate(receipt)
  end

  desc "List migration route policy settings"
  task route_policy_list: :environment do
    position = migration_position_from_env(action: "route_policy_list")
    next unless position

    report = MigrationRouteOperationalPolicy.new.report.merge(
      action: "route_policy_list",
      position_id: position.id
    )
    puts JSON.pretty_generate(report)
  end

  desc "Restore default migration route policy settings"
  task route_policy_restore_defaults: :environment do
    position = migration_position_from_env(action: "route_policy_restore_defaults")
    next unless position

    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationRouteOperationalPolicy.new.restore_defaults!(confirmation: confirmation)
    puts JSON.pretty_generate(
      result.payload.merge(
        action: "route_policy_restore_defaults",
        position_id: position.id,
        ok: result.ok,
        errors: result.errors
      )
    )
    abort("route_policy_restore_defaults blocked") unless result.ok
  end

  desc "Set a single migration route policy"
  task route_policy_set: :environment do
    position = migration_position_from_env(action: "route_policy_set")
    next unless position

    confirmation = ENV["confirmation"].presence || ENV["CONFIRMATION"].presence
    result = MigrationRouteOperationalPolicy.new.set_route!(
      from: ENV["from"].presence || ENV["FROM"].presence,
      to: ENV["to"].presence || ENV["TO"].presence,
      enabled: ENV["enabled"].presence || ENV["ENABLED"].presence,
      strategy: ENV["strategy"].presence || ENV["STRATEGY"].presence,
      confirmation: confirmation
    )
    puts JSON.pretty_generate(
      result.payload.merge(
        action: "route_policy_set",
        position_id: position.id,
        ok: result.ok,
        errors: result.errors
      )
    )
    abort("route_policy_set blocked") unless result.ok
  end

  def refresh_snapshot_for_route_proof(position)
    return { refreshed: false, reason: "disabled" } unless refresh_snapshot_for_route_proof?

    snapshot = position.position_dashboard_snapshot
    return { refreshed: false, reason: "fresh_complete" } if snapshot && !snapshot.stale_now? && snapshot.migration_complete_for_proof?

    reason = snapshot_refresh_reason(snapshot)
    DashboardSnapshotRefresh.new(position: position, force: true).refresh
    { refreshed: true, reason: reason }
  rescue => e
    { refreshed: false, reason: "refresh_error", error: "#{e.class}: #{e.message}" }
  end

  def migration_position_from_env(action:)
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:hedge, :position_dashboard_snapshot).find_by(id: position_id)
    return position if position

    puts JSON.pretty_generate(
      status: "blocked",
      action: action,
      position_id: position_id,
      blockers: [ "Position #{position_id || '(missing)'} not found." ],
      orders_submitted: 0,
      signatures_created: 0
    )
    nil
  end

  def snapshot_refresh_reason(snapshot)
    return "missing" unless snapshot
    return "stale" if snapshot.stale_now?
    return "incomplete: #{snapshot.missing_migration_fields.join(', ')}" unless snapshot.migration_complete_for_proof?

    "fresh_complete"
  end

  def ensure_snapshot_migration_fields(position, snapshot)
    return { updated: false } unless snapshot
    return { updated: false } if snapshot.migration_complete_for_proof?

    target = computed_target_short(position)
    combined = computed_combined_short(snapshot)
    tolerance = target && position.hedge ? target * position.hedge.tolerance : nil
    drift = target && combined ? target - combined : nil
    attrs = {
      target_short_eth: snapshot.target_short_eth || target,
      tolerance_abs_eth: snapshot.tolerance_abs_eth || tolerance,
      combined_short_eth: snapshot.combined_short_eth || combined,
      drift_eth: snapshot.drift_eth || drift,
      inside_tolerance: snapshot.inside_tolerance.nil? && drift && tolerance ? drift.abs <= tolerance : snapshot.inside_tolerance
    }.compact
    return { updated: false } if attrs.empty?

    snapshot.update!(attrs)
    if snapshot.migration_complete_for_proof?
      { updated: true, warning: "target_short_eth computed from Position/Hedge because snapshot field was missing" }
    else
      { updated: true, warning: "snapshot migration fields remain incomplete: #{snapshot.missing_migration_fields.join(', ')}" }
    end
  end

  def computed_target_short(position)
    target = HedgeFreshTarget.new(position: position).resolve(refresh_if_stale: true)
    target[:target_short_eth] if target[:status] == "ok"
  end

  def computed_combined_short(snapshot)
    values = [ snapshot.extended_short_eth, snapshot.ethereal_short_eth, snapshot.nado_short_eth ]
    return nil unless values.all?

    values.sum(BigDecimal("0"))
  end

  def refresh_snapshot_for_route_proof?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("refresh_snapshot", "true"))
  end

  def snapshot_age_seconds(snapshot, at: Time.current)
    return nil unless snapshot&.refreshed_at

    (at - snapshot.refreshed_at).round
  end

  def snapshot_status(snapshot, at: Time.current)
    return "missing" unless snapshot
    return "stale" if snapshot.stale_at?(at)
    return "incomplete" unless snapshot.migration_complete_for_proof?

    snapshot.refresh_status == "ok" ? "fresh" : snapshot.refresh_status
  end
end
