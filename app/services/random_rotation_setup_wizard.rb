class RandomRotationSetupWizard
  ENABLE_CONFIRMATION = "I_UNDERSTAND_THIS_ENABLES_RANDOM_ROTATION".freeze
  DISABLE_CONFIRMATION = "I_UNDERSTAND_THIS_DISABLES_RANDOM_ROTATION".freeze

  def initialize(position:, readiness: nil, proof_registry: nil, route_matrix: nil, env: ENV)
    @position = position
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @readiness = readiness
    @route_matrix = route_matrix
    @env = env
  end

  def report
    readiness_report = readiness
    proof_report = proof_registry.report(position: position)
    routes = proof_report.fetch(:routes)
    pending = readiness_report[:pending_nado_target_continuation]
    next_route = next_route_for(readiness_report: readiness_report, routes: routes, pending: pending)
    status = status_for(readiness_report: readiness_report, proof_report: proof_report, pending: pending, next_route: next_route)

    base_report(readiness_report: readiness_report, proof_report: proof_report, routes: routes, next_route: next_route, status: status)
  end

  def base_report(readiness_report:, proof_report:, routes:, next_route:, status:, status_label_override: nil)
    plan = route_plan(next_route)
    pending = readiness_report[:pending_nado_target_continuation]
    {
      action: "random_rotation_setup",
      position_id: position.id,
      status: status,
      status_label: status_label_override || status_label(status),
      current_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      current_venue_label: HedgeVenues.label(position.hedge&.execution_venue),
      hedge_health: hedge_health,
      venue_shorts: venue_shorts,
      auto_states: auto_states,
      migration_gates: migration_gates,
      completed_route_proofs: proof_report.fetch(:completed_route_proofs),
      missing_route_proofs: proof_report.fetch(:missing_route_proofs),
      stale_route_proofs: proof_report.fetch(:stale_route_proofs),
      route_proof_statuses: routes,
      all_routes_ready: proof_report.fetch(:missing_route_proofs).empty?,
      next_route: next_route,
      next_action: next_action(status),
      next_action_label: next_action_label(status),
      next_action_live: next_action_live?(status),
      required_confirmation_phrase: required_confirmation_phrase(status, pending),
      plan: plan,
      blockers: Array(readiness_report[:blockers]),
      enable_blockers: enable_blockers(readiness_report, proof_report, pending),
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
    fallback_status = status || (position.position_dashboard_snapshot&.inside_tolerance == false ? "blocked_hedge_health" : "degraded")

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
    route_hash(routes.find { |route| route[:from_venue] == current && route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] }) ||
      route_hash(routes.find { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] })
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

  def status_for(readiness_report:, proof_report:, pending:, next_route:)
    return "enabled" if OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", env: env)
    return "continuation_required" if pending
    return "blocked_hedge_health" if position.position_dashboard_snapshot&.inside_tolerance == false
    return "ready_to_enable" if proof_report.fetch(:missing_route_proofs).empty?
    return "ready_for_supervised_canary" if next_route && next_route[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run]
    return "in_progress" if readiness_report.fetch(:completed_route_proofs).any? || proof_report.fetch(:routes).any? { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:not_started] }

    "not_ready"
  end

  def status_label(status)
    {
      "enabled" => "Enabled",
      "ready_to_enable" => "Ready to enable",
      "continuation_required" => "Continuation required",
      "blocked_hedge_health" => "Setup blocked / current hedge out of tolerance",
      "degraded" => "Setup loaded with limited diagnostics",
      "ready_for_supervised_canary" => "Ready for supervised canary",
      "in_progress" => "In progress",
      "not_ready" => "Not ready",
      "unavailable" => "Unavailable"
    }.fetch(status, status.to_s.tr("_", " ").capitalize)
  end

  def next_action(status)
    {
      "enabled" => "disable_random",
      "ready_to_enable" => "enable_random",
      "continuation_required" => "continue_source_close",
      "blocked_hedge_health" => "rebalance_current_hedge",
      "ready_for_supervised_canary" => "run_live_canary"
    }.fetch(status, "prepare_next_route")
  end

  def next_action_label(status)
    {
      "enabled" => "Disable Random Rotation",
      "ready_to_enable" => "Enable Random Rotation",
      "continuation_required" => "Close source venue and continue migration",
      "blocked_hedge_health" => "Rebalance current hedge first",
      "ready_for_supervised_canary" => "Run Supervised Live Canary"
    }.fetch(status, "Prepare Next Route")
  end

  def next_action_live?(status)
    status.in?(%w[ready_for_supervised_canary continuation_required])
  end

  def required_confirmation_phrase(status, pending)
    case status
    when "ready_for_supervised_canary"
      MigrationManualLiveCanaryRunner::CONFIRMATION
    when "continuation_required"
      pending && pending[:to_venue] == "nado" ? MigrationTargetNadoContinuation::CONFIRMATION : MigrationTargetFirstSourceRecovery::CONFIRMATION
    when "ready_to_enable"
      ENABLE_CONFIRMATION
    when "enabled"
      DISABLE_CONFIRMATION
    end
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
