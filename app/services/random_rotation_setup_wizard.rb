class RandomRotationSetupWizard
  ENABLE_CONFIRMATION = "I_UNDERSTAND_THIS_ENABLES_RANDOM_ROTATION".freeze
  DISABLE_CONFIRMATION = "I_UNDERSTAND_THIS_DISABLES_RANDOM_ROTATION".freeze
  STATES = {
    no_dry_run: "NO_DRY_RUN",
    dry_run_proven: "DRY_RUN_PROVEN",
    source_reposition_required: "SOURCE_REPOSITION_REQUIRED",
    source_reposition_blocked: "SOURCE_REPOSITION_BLOCKED",
    target_only: "LIVE_CANARY_CONFIRMED_TARGET_ONLY",
    source_closed_not_finalized: "SOURCE_CLOSED_TARGET_CONFIRMED_NOT_FINALIZED",
    route_complete_by_readback: "ROUTE_ALREADY_COMPLETE_BY_READBACK",
    full_route: "LIVE_CANARY_CONFIRMED_FULL_ROUTE",
    ready_for_random: "READY_FOR_RANDOM",
    random_enabled: "RANDOM_ENABLED"
  }.freeze

  def initialize(position:, readiness: nil, proof_registry: nil, route_matrix: nil, env: ENV)
    @position = position
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @readiness = readiness
    @route_matrix = route_matrix
    @env = env
  end

  def report
    proof_report = proof_registry.report(position: position)
    routes = proof_report.fetch(:routes)
    reconciliation = reconcile_routes(routes)
    if reconciliation&.finalize_safe
      return base_report(
        readiness_report: readiness,
        proof_report: proof_report,
        routes: routes,
        next_route: route_hash(reconciliation.receipt),
        status: STATES[:source_closed_not_finalized],
        reconciliation: reconciliation
      )
    end
    if reconciliation&.route_complete_by_readback && reconciliation.production_venue_finalized
      proof_report = proof_registry.report(position: position)
      @readiness = nil
      routes = proof_report.fetch(:routes)
    end

    readiness_report = readiness
    pending = readiness_report[:pending_nado_target_continuation]
    execution = execution_plan_for(readiness_report: readiness_report, proof_report: proof_report, routes: routes, pending: pending)
    next_route = execution[:next_executable_route]
    status = status_for(readiness_report: readiness_report, proof_report: proof_report, pending: pending, next_route: next_route, execution: execution)

    base_report(readiness_report: readiness_report, proof_report: proof_report, routes: routes, next_route: next_route, status: status, execution: execution)
  end

  def base_report(readiness_report:, proof_report:, routes:, next_route:, status:, status_label_override: nil, reconciliation: nil, execution: nil)
    execution ||= default_execution_plan(next_route)
    plan = route_plan(next_route)
    pending = readiness_report[:pending_nado_target_continuation]
    {
      action: "random_rotation_setup",
      position_id: position.id,
      status: status,
      status_label: status_label_override || status_label(status, next_route),
      current_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      current_venue_label: HedgeVenues.label(position.hedge&.execution_venue),
      hedge_health: hedge_health,
      venue_shorts: venue_shorts,
      auto_states: auto_states,
      auto_policy: auto_policy,
      migration_gates: migration_gates,
      completed_route_proofs: proof_report.fetch(:completed_route_proofs),
      missing_route_proofs: proof_report.fetch(:missing_route_proofs),
      stale_route_proofs: proof_report.fetch(:stale_route_proofs),
      route_proof_statuses: routes,
      all_routes_ready: proof_report.fetch(:missing_route_proofs).empty?,
      setup_progress: setup_progress(next_route),
      random_enablement: random_enablement(readiness_report, proof_report, pending),
      next_missing_proof_route: execution[:next_missing_proof_route],
      next_executable_route: execution[:next_executable_route],
      source_reposition_required: execution[:source_reposition_required] == true,
      source_reposition_route: execution[:source_reposition_route],
      source_reposition_reason: execution[:source_reposition_reason],
      executable_route_role: execution[:executable_route_role],
      next_route: next_route,
      next_action: next_action(status, execution),
      next_action_label: next_action_label(status, execution),
      next_action_live: next_action_live?(status),
      required_confirmation_phrase: required_confirmation_phrase(status, pending),
      plan: plan,
      blockers: Array(readiness_report[:blockers]),
      enable_blockers: enable_blockers(readiness_report, proof_report, pending),
      reconciliation: reconciliation_payload(reconciliation),
      stale_pending_continuation_ignored: readiness_report[:stale_pending_continuation_ignored] == true,
      counters: {
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      }
    }
  end

  def self.unavailable(position:, message:)
    degraded(position: position, message: message, status: "unavailable", status_label: "Unavailable")
  end

  def self.degraded(position:, message:, proof_registry: nil, env: ENV, status: nil, status_label: nil)
    registry = proof_registry || MigrationRouteProofRegistry.new
    proof_report = registry.report(position: position)
    readiness_report = degraded_readiness(position: position, proof_report: proof_report, message: message)
    routes = proof_report.fetch(:routes)
    next_route = readiness_report[:next_recommended_canary]
    fallback_status = status || fallback_status_for(position: position, proof_report: proof_report, next_route: next_route)

    new(position: position, readiness: readiness_report, proof_registry: registry, env: env).base_report(
      readiness_report: readiness_report,
      proof_report: proof_report,
      routes: routes,
      next_route: next_route,
      status: fallback_status,
      status_label_override: status_label
    )
  rescue => e
    canonical_routes = canonical_route_statuses
    {
      action: "random_rotation_setup",
      position_id: position.id,
      status: status || "degraded",
      status_label: status_label || "Setup loaded with limited diagnostics",
      current_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      current_venue_label: HedgeVenues.label(position.hedge&.execution_venue),
      hedge_health: hedge_health_for(position),
      venue_shorts: venue_shorts_for(position),
      auto_states: {},
      migration_gates: {},
      completed_route_proofs: [],
      missing_route_proofs: canonical_routes,
      stale_route_proofs: [],
      route_proof_statuses: canonical_routes,
      all_routes_ready: false,
      setup_progress: {},
      random_enablement: { ready_routes: 0, total_routes: canonical_routes.size, blockers: [ message ] },
      next_route: canonical_routes.find { |route| route[:from_venue] == HedgeVenues.normalize(position.hedge&.execution_venue) } || canonical_routes.first,
      next_action: "refresh",
      next_action_label: "Refresh Random Readiness",
      next_action_live: false,
      required_confirmation_phrase: nil,
      plan: {},
      blockers: [ message, "#{e.class}: #{e.message}" ],
      enable_blockers: [ message ],
      counters: {
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      }
    }
  end

  def self.canonical_route_statuses
    MigrationRouteProofRegistry::ROUTES.map do |from, to|
      {
        route: "#{from}->#{to}",
        from_venue: from,
        to_venue: to,
        status: MigrationRouteProofRegistry::STATUSES[:not_started],
        blockers: [ "#{from}->#{to} route proof has not started." ],
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0
      }
    end
  end

  def self.degraded_readiness(position:, proof_report:, message:)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    missing = proof_report.fetch(:missing_route_proofs)
    {
      action: "migration_random_readiness",
      position_id: position.id,
      current_production_venue: current,
      next_recommended_canary: missing.find { |route| route[:from_venue] == current } || missing.first,
      completed_route_proofs: proof_report.fetch(:completed_route_proofs),
      missing_route_proofs: missing,
      stale_route_proofs: proof_report.fetch(:stale_route_proofs),
      pending_nado_target_continuation: nil,
      blockers: [ message ],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def self.fallback_status_for(position:, proof_report:, next_route:)
    return "blocked_hedge_health" if position.position_dashboard_snapshot&.inside_tolerance == false
    return STATES[:ready_for_random] if proof_report.fetch(:missing_route_proofs).empty?
    return STATES[:dry_run_proven] if next_route && next_route[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run]

    "degraded"
  end

  def self.hedge_health_for(position)
    snapshot = position.position_dashboard_snapshot
    return { status: "Unknown", message: "No dashboard snapshot yet." } unless snapshot

    {
      status: snapshot.inside_tolerance ? "Healthy" : "Out of tolerance",
      inside_tolerance: snapshot.inside_tolerance,
      target_short_eth: snapshot.target_short_eth,
      combined_short_eth: snapshot.combined_short_eth,
      drift_eth: snapshot.drift_eth,
      tolerance_abs_eth: snapshot.tolerance_abs_eth,
      refreshed_at: snapshot.refreshed_at
    }
  end

  def self.venue_shorts_for(position)
    snapshot = position.position_dashboard_snapshot
    return {} unless snapshot

    %w[extended ethereal nado].to_h { |venue| [ venue, snapshot.public_send("#{venue}_short_eth") ] }
  end

  private

  attr_reader :position, :proof_registry, :env

  def readiness
    @readiness ||= MigrationRandomReadiness.new(position: position, proof_registry: proof_registry).report
  end

  def next_route_for(readiness_report:, routes:, pending:)
    return pending.symbolize_keys.slice(:from_venue, :to_venue, :route, :status) if pending

    recommended = readiness_report[:next_recommended_canary]
    return route_hash(recommended) if recommended.present?

    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    route_hash(preferred_missing_route(routes, current)) ||
      route_hash(routes.find { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] })
  end

  def execution_plan_for(readiness_report:, proof_report:, routes:, pending:)
    return default_execution_plan(next_route_for(readiness_report: readiness_report, routes: routes, pending: pending)) if pending
    return { next_missing_proof_route: nil, next_executable_route: nil, source_reposition_required: false, source_reposition_route: nil, executable_route_role: "enable_random" } if proof_report.fetch(:missing_route_proofs).empty?

    missing = route_hash(preferred_dry_run_route(routes)) || route_hash(readiness_report[:next_recommended_canary]) || route_hash(preferred_missing_route(routes, current_venue)) ||
      route_hash(routes.find { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] })
    return default_execution_plan(nil) unless missing
    return default_execution_plan(missing).merge(next_missing_proof_route: missing, executable_route_role: "proof") if executable_source_route?(missing)

    reposition = source_reposition_route_for(routes: routes, required_source: missing[:from_venue])
    {
      next_missing_proof_route: missing,
      next_executable_route: reposition,
      source_reposition_required: true,
      source_reposition_route: reposition,
      source_reposition_reason: source_reposition_reason(missing, reposition),
      executable_route_role: reposition ? "source_reposition" : "blocked_source_reposition"
    }
  end

  def default_execution_plan(route)
    {
      next_missing_proof_route: route,
      next_executable_route: route,
      source_reposition_required: false,
      source_reposition_route: nil,
      source_reposition_reason: nil,
      executable_route_role: route ? "proof" : nil
    }
  end

  def route_hash(route)
    return nil unless route

    {
      route: route[:route] || "#{route[:from_venue]}->#{route[:to_venue]}",
      from_venue: route[:from_venue],
      to_venue: route[:to_venue],
      status: route[:status]
    }
  end

  def status_for(readiness_report:, proof_report:, pending:, next_route:, execution:)
    return STATES[:random_enabled] if OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", env: env)
    return STATES[:target_only] if pending
    return "blocked_hedge_health" if position.position_dashboard_snapshot&.inside_tolerance == false
    return STATES[:ready_for_random] if proof_report.fetch(:missing_route_proofs).empty?
    return STATES[:source_reposition_required] if execution[:executable_route_role] == "source_reposition"
    return STATES[:source_reposition_blocked] if execution[:executable_route_role] == "blocked_source_reposition"
    return STATES[:dry_run_proven] if next_route && next_route[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run]
    return STATES[:full_route] if next_route && next_route[:status] == MigrationRouteProofRegistry::STATUSES[:live]
    return "in_progress" if readiness_report.fetch(:completed_route_proofs).any? || proof_report.fetch(:routes).any? { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:not_started] }

    STATES[:no_dry_run]
  end

  def status_label(status, next_route = nil)
    return "Dry-run complete / supervised Nado canary required" if status == STATES[:dry_run_proven] && nado_route?(next_route)

    {
      STATES[:random_enabled] => "Random enabled",
      STATES[:ready_for_random] => "Ready to enable random rotation",
      STATES[:dry_run_proven] => "Dry-run complete / supervised canary required",
      STATES[:source_reposition_required] => "Move to required source venue",
      STATES[:source_reposition_blocked] => "Setup blocked / move to source venue unavailable",
      STATES[:target_only] => "Live canary target confirmed / source close required",
      STATES[:source_closed_not_finalized] => "Migration completed by readback / finalize required",
      STATES[:route_complete_by_readback] => "Route already complete by readback",
      STATES[:full_route] => "Live canary route confirmed",
      STATES[:no_dry_run] => "No dry-run proof yet",
      "blocked_hedge_health" => "Setup blocked / current hedge out of tolerance",
      "degraded" => "Setup loaded with limited diagnostics",
      "in_progress" => "In progress",
      "unavailable" => "Unavailable"
    }.fetch(status, status.to_s.tr("_", " ").capitalize)
  end

  def next_action(status, execution = {})
    {
      STATES[:random_enabled] => "disable_random",
      STATES[:ready_for_random] => "enable_random",
      STATES[:source_reposition_required] => "move_to_required_source_venue",
      STATES[:source_reposition_blocked] => "source_reposition_unavailable",
      STATES[:target_only] => "continue_source_close",
      STATES[:source_closed_not_finalized] => "finalize_migration",
      STATES[:route_complete_by_readback] => "prepare_next_route",
      "blocked_hedge_health" => "rebalance_current_hedge",
      STATES[:dry_run_proven] => "run_live_canary"
    }.fetch(status, "prepare_next_route")
  end

  def next_action_label(status, execution = {})
    return "Move to required source venue" if execution[:executable_route_role] == "source_reposition"

    {
      STATES[:random_enabled] => "Disable Random Rotation",
      STATES[:ready_for_random] => "Enable Random Rotation",
      STATES[:source_reposition_required] => "Move to required source venue",
      STATES[:source_reposition_blocked] => "Move to source venue unavailable",
      STATES[:target_only] => "Close source venue and continue migration",
      STATES[:source_closed_not_finalized] => "Finalize migration",
      STATES[:route_complete_by_readback] => "Prepare Next Route",
      STATES[:full_route] => "Finalize migration / prepare next route",
      "blocked_hedge_health" => "Rebalance current hedge first",
      STATES[:dry_run_proven] => "Run Supervised Live Canary"
    }.fetch(status, "Prepare Next Route")
  end

  def next_action_live?(status)
    status.in?([ STATES[:dry_run_proven], STATES[:target_only], STATES[:source_closed_not_finalized], STATES[:source_reposition_required] ])
  end

  def nado_route?(route)
    route && route.values_at(:from_venue, :to_venue).include?("nado")
  end

  def required_confirmation_phrase(status, pending)
    case status
    when STATES[:dry_run_proven]
      MigrationManualLiveCanaryRunner::CONFIRMATION
    when STATES[:source_reposition_required]
      MigrationManualLiveCanaryRunner::CONFIRMATION
    when STATES[:target_only]
      pending && pending[:to_venue] == "nado" ? MigrationTargetNadoContinuation::CONFIRMATION : MigrationTargetFirstSourceRecovery::CONFIRMATION
    when STATES[:source_closed_not_finalized]
      MigrationManualLiveCanaryRunner::CONFIRMATION
    when STATES[:ready_for_random]
      ENABLE_CONFIRMATION
    when STATES[:random_enabled]
      DISABLE_CONFIRMATION
    end
  end

  def setup_progress(next_route)
    return {} unless next_route

    {
      route: next_route[:route],
      from_venue: next_route[:from_venue],
      to_venue: next_route[:to_venue],
      status: next_route[:status],
      status_label: setup_route_status_label(next_route[:status])
    }
  end

  def setup_route_status_label(status)
    {
      MigrationRouteProofRegistry::STATUSES[:dry_run] => "dry-run proven, live canary required",
      MigrationRouteProofRegistry::STATUSES[:live] => "target canary confirmed, source close may be required",
      MigrationRouteProofRegistry::STATUSES[:ready] => "ready for random rotation",
      MigrationRouteProofRegistry::STATUSES[:not_started] => "dry-run proof required"
    }.fetch(status, status.to_s.tr("_", " ").downcase)
  end

  def reconcile_routes(routes)
    routes.each do |route|
      next if route[:status] == MigrationRouteProofRegistry::STATUSES[:ready]
      next unless route[:status].in?([ MigrationRouteProofRegistry::STATUSES[:dry_run], MigrationRouteProofRegistry::STATUSES[:live], MigrationRouteProofRegistry::STATUSES[:failed] ])
      next if defer_readback_reconciliation?(route, routes)

      reconciler = MigrationRouteCompletionReconciler.new(position: position, from: route[:from_venue], to: route[:to_venue], receipt_dir: proof_registry.canary_receipt_dir)
      result = reconciler.report
      return result if result.finalize_safe
      return reconciler.write_ready_receipt! if result.route_complete_by_readback && result.production_venue_finalized
    end
    nil
  end

  def defer_readback_reconciliation?(route, routes)
    return false if route[:from_venue] == current_venue

    routes.any? do |candidate|
      candidate[:from_venue] == current_venue &&
        candidate[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run] &&
        venue_short(candidate[:from_venue]).positive?
    end
  end

  def reconciliation_payload(result)
    return nil unless result

    result.receipt.slice(
      :final_status,
      :from_venue,
      :to_venue,
      :source_flat_after,
      :target_holds_expected_short,
      :final_inside_tolerance,
      :open_orders_after,
      :production_venue_finalized,
      :orders_submitted,
      :orders_placed,
      :signatures_created,
      :cancels_submitted
    )
  end

  def preferred_missing_route(routes, current)
    candidates = routes.select { |route| route[:from_venue] == current && route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] }
    return candidates.find { |route| route[:to_venue] == "ethereal" } if current == "nado"

    candidates.first
  end

  def preferred_dry_run_route(routes)
    dry_routes = routes.select { |route| route[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run] }
    dry_routes.find { |route| route[:from_venue] == current_venue && venue_short(route[:from_venue]).positive? } ||
      dry_routes.first
  end

  def executable_source_route?(route)
    route[:from_venue] == current_venue && venue_short(route[:from_venue]).positive?
  end

  def source_reposition_route_for(routes:, required_source:)
    route = routes.find do |candidate|
      candidate[:from_venue] == current_venue &&
        candidate[:to_venue] == required_source &&
        candidate[:status] == MigrationRouteProofRegistry::STATUSES[:ready]
    end
    route_hash(route)
  end

  def source_reposition_reason(missing, reposition)
    missing_label = "#{HedgeVenues.label(missing[:from_venue])} -> #{HedgeVenues.label(missing[:to_venue])}"
    blockers = []
    blockers << "#{missing_label} cannot run because current production venue is #{HedgeVenues.label(current_venue)}" unless missing[:from_venue] == current_venue
    blockers << "#{HedgeVenues.label(missing[:from_venue])} has no source short" unless venue_short(missing[:from_venue]).positive?
    if reposition
      blockers << "Move production hedge #{HedgeVenues.label(reposition[:from_venue])} -> #{HedgeVenues.label(reposition[:to_venue])} first using an already READY_FOR_RANDOM route."
    else
      blockers << "No READY_FOR_RANDOM route is available from #{HedgeVenues.label(current_venue)} to #{HedgeVenues.label(missing[:from_venue])}."
    end
    blockers.join("; ")
  end

  def current_venue
    HedgeVenues.normalize(position.hedge&.execution_venue)
  end

  def venue_short(venue)
    snapshot = position.position_dashboard_snapshot
    return BigDecimal("0") unless snapshot

    BigDecimal(snapshot.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def random_enablement(readiness_report, proof_report, pending)
    total = proof_report.fetch(:routes).size
    ready = proof_report.fetch(:completed_route_proofs).size
    {
      ready_routes: ready,
      total_routes: total,
      status: ready == total ? "ready" : "not_ready",
      blockers: enable_blockers(readiness_report, proof_report, pending)
    }
  end

  def route_plan(next_route)
    return {} unless next_route

    plan = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: next_route[:from_venue],
      to_venue: next_route[:to_venue],
      mode: "full",
      full_migration_allowed: true,
      migration_sequence: "target_first"
    )
    receipt = plan.receipt
    {
      from_venue: next_route[:from_venue],
      to_venue: next_route[:to_venue],
      sequence: "target_first",
      target_leg: receipt[:planned_target_leg] || receipt[:planned_to_leg],
      source_leg: receipt[:planned_source_leg] || receipt[:planned_from_leg],
      temporary_combined_after_first_leg: receipt[:temporary_combined_after_first_leg] || receipt[:temporary_exposure],
      temporary_risk_type: receipt[:temporary_risk_type],
      expected_final_combined: receipt[:expected_final_combined] || receipt[:expected_combined_short_after],
      expected_final_venue: next_route[:to_venue],
      open_orders_check: "required zero on source and target before live canary",
      blockers: plan.blockers,
      warnings: plan.warnings
    }
  rescue => e
    {
      from_venue: next_route[:from_venue],
      to_venue: next_route[:to_venue],
      sequence: "target_first",
      blockers: [ "#{e.class}: #{e.message}" ],
      warnings: []
    }
  end

  def hedge_health
    snapshot = position.position_dashboard_snapshot
    return { status: "Unknown", message: "No dashboard snapshot yet." } unless snapshot

    {
      status: snapshot.inside_tolerance ? "Healthy" : "Out of tolerance",
      inside_tolerance: snapshot.inside_tolerance,
      target_short_eth: snapshot.target_short_eth,
      combined_short_eth: snapshot.combined_short_eth,
      drift_eth: snapshot.drift_eth,
      tolerance_abs_eth: snapshot.tolerance_abs_eth,
      refreshed_at: snapshot.refreshed_at
    }
  end

  def venue_shorts
    snapshot = position.position_dashboard_snapshot
    return {} unless snapshot

    %w[extended ethereal nado].to_h do |venue|
      [ venue, snapshot.public_send("#{venue}_short_eth") ]
    end
  end

  def auto_states
    OperationalSettings::AUTO_KEYS_BY_VENUE.to_h do |venue, key|
      setting = OperationalSettings.get(key, env: env)
      [ venue, { key: key, enabled: setting.enabled, source: setting.source, raw_value: setting.raw_value } ]
    end
  end

  def auto_policy
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    active = ActiveVenueAutoPolicy.active_auto_venue(env: env)
    {
      description: "When random rotation is enabled, only the active production venue keeps auto-rebalance enabled. During migrations, auto-rebalance is paused or blocked. After each successful migration, auto-rebalance moves to the new venue.",
      current_production_venue: current,
      current_production_venue_name: HedgeVenues.label(current),
      current_active_auto_venue: active,
      current_active_auto_name: active ? HedgeVenues.label(active) : nil,
      current_active_auto_enabled: active.present?,
      auto_that_will_be_enabled_with_random: current,
      auto_that_will_be_enabled_with_random_name: HedgeVenues.label(current),
      other_venue_autos: OperationalSettings::AUTO_KEYS_BY_VENUE.keys.reject { |venue| venue == current }
    }
  end

  def migration_gates
    OperationalSettings::MIGRATION_KEYS.to_h do |key|
      setting = OperationalSettings.get(key, env: env)
      [ key, { enabled: setting.enabled, source: setting.source, raw_value: setting.raw_value } ]
    end
  end

  def enable_blockers(readiness_report, proof_report, pending)
    blockers = []
    blockers << "all route proofs must be READY_FOR_RANDOM" if proof_report.fetch(:missing_route_proofs).any?
    blockers << "pending target-first continuation must be completed" if pending
    operator_gate_patterns = /\AMIGRATION_(LIVE_ENABLED|RANDOM_ROTATION_LIVE_ENABLED) must be true\z/
    blockers.concat(Array(readiness_report[:blockers]).reject { |blocker| blocker.match?(operator_gate_patterns) })
    blockers.uniq
  end
end
