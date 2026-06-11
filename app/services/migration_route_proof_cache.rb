class MigrationRouteProofCache
  DEFAULT_TAIL_LINES = 200

  SOURCE_DIRS = [
    HedgeVenueMigrationRouteMatrix::PROOF_RECEIPT_DIR,
    MigrationManualLiveCanaryRunner::RECEIPT_DIR,
    MigrationTargetFirstSourceRecovery::RECEIPT_DIR,
    MigrationTargetNadoContinuation::RECEIPT_DIR,
    Rails.root.join("storage/hedge_migration_random_rehearsals"),
    Rails.root.join("storage/hedge_migration_route_latency_proofs")
  ].freeze

  def initialize(position:, source_dirs: SOURCE_DIRS, tail_lines: DEFAULT_TAIL_LINES)
    @position = position
    @source_dirs = source_dirs.map { |dir| Pathname(dir) }
    @tail_lines = tail_lines
  end

  def proof_report
    routes = route_statuses
    {
      action: "migration_route_proofs_cached",
      position_id: position.id,
      source: "bounded_jsonl_tail",
      routes: routes,
      completed_route_proofs: routes.select { |route| route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] },
      missing_route_proofs: routes.reject { |route| route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] },
      stale_route_proofs: routes.select { |route| route[:status] == MigrationRouteProofRegistry::STATUSES[:stale] },
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def route_matrix
    {
      position_id: position.id,
      source: "cached_route_proof_tail",
      routes: route_statuses.map { |route| matrix_route(route) },
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def random_setup
    report = proof_report
    routes = report.fetch(:routes)
    ready = report.fetch(:completed_route_proofs)
    missing = report.fetch(:missing_route_proofs)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    execution = cached_execution(routes: routes, missing: missing, current: current)
    execution = out_of_tolerance_execution(execution) if position.position_dashboard_snapshot&.inside_tolerance == false
    next_route = execution[:next_route]
    message = missing.empty? ? "Cached route proofs show every route ready." : "all route proofs must be READY_FOR_RANDOM"
    diagnostics = missing.empty? ? [] : [ "Random readiness refresh needed" ]

    {
      action: "random_rotation_setup",
      position_id: position.id,
      status: execution[:status],
      status_label: execution[:status_label],
      current_venue: current,
      current_venue_label: HedgeVenues.label(current),
      hedge_health: RandomRotationSetupWizard.hedge_health_for(position),
      venue_shorts: RandomRotationSetupWizard.venue_shorts_for(position),
      auto_states: {},
      auto_policy: {},
      migration_gates: {},
      completed_route_proofs: ready,
      missing_route_proofs: missing,
      stale_route_proofs: report.fetch(:stale_route_proofs),
      route_proof_statuses: routes,
      all_routes_ready: missing.empty?,
      setup_progress: next_route || {},
      random_enablement: {
        ready_routes: ready.size,
        total_routes: routes.size,
        blockers: missing.empty? ? [] : [ message, *diagnostics ]
      },
      next_missing_proof_route: execution[:missing_route] || next_route,
      next_executable_route: next_route,
      source_reposition_required: execution[:source_reposition_required],
      source_reposition_route: execution[:source_reposition_route],
      source_reposition_reason: execution[:source_reposition_reason],
      executable_route_role: execution[:role],
      next_route: next_route,
      next_action: execution[:next_action],
      next_action_label: execution[:next_action_label],
      next_action_live: execution[:next_action_live],
      required_confirmation_phrase: execution[:required_confirmation_phrase],
      plan: {},
      blockers: Array(execution[:blockers]).presence || (missing.empty? ? [] : [ message, *diagnostics ]),
      enable_blockers: Array(execution[:enable_blockers]).presence || (missing.empty? ? [] : [ message ]),
      limited_diagnostics: true,
      fallback_used: true,
      fallback_reason: message,
      counters: {
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      }
    }
  rescue => e
    unavailable_random_setup("#{e.class}: #{e.message}")
  end

  private

  attr_reader :position, :source_dirs, :tail_lines

  def route_statuses
    @route_statuses ||= MigrationRouteProofRegistry::ROUTES.map do |from, to|
      event = latest_event_for(from: from, to: to)
      cached_route(from: from, to: to, event: event)
    end
  end

  def latest_event_for(from:, to:)
    events
      .select { |event| event["position_id"].to_s == position.id.to_s && event["from_venue"] == from && event["to_venue"] == to }
      .max_by { |event| event_time(event) || Time.zone.at(0) }
  end

  def events
    @events ||= source_dirs.flat_map do |dir|
      Dir.glob(dir.join("*.jsonl")).flat_map { |path| tail_jsonl(path, tail_lines) }
    rescue SystemCallError
      []
    end
  end

  def cached_route(from:, to:, event:)
    status = event ? normalized_status(route_status_from(event)) : MigrationRouteProofRegistry::STATUSES[:not_started]
    {
      route: "#{from}->#{to}",
      from_venue: from,
      to_venue: to,
      status: status,
      route_status: status,
      proof_timestamp: event&.fetch("timestamp", nil),
      final_venue: event&.fetch("final_production_venue", nil) || event&.fetch("final_venue", nil),
      final_readback_summary: {
        final_inside_tolerance: event&.fetch("final_inside_tolerance", nil),
        production_venue_finalized: event&.fetch("production_venue_finalized", nil),
        source_flat_after: event&.fetch("source_flat_after", nil),
        target_holds_expected_short: event&.fetch("target_holds_expected_short", nil)
      },
      route_enabled: true,
      route_production_safe: production_safe?(event),
      orders_submitted: event&.fetch("orders_submitted", 0).to_i,
      orders_placed: event&.fetch("orders_placed", 0).to_i,
      signatures_created: event&.fetch("signatures_created", 0).to_i,
      blockers: cached_blockers(status, from, to, event)
    }
  end

  def route_status_from(event)
    return event["route_status"] if event["route_status"].present?
    return MigrationRouteProofRegistry::STATUSES[:ready] if ready_event?(event)
    return MigrationRouteProofRegistry::STATUSES[:failed] if event["manual_action_required"] == true || event["final_status"].to_s.include?("BLOCKED")
    return MigrationRouteProofRegistry::STATUSES[:dry_run] if event["dry_run"] == true || event["action"].to_s.include?("rehearsal")

    event["final_status"].presence || MigrationRouteProofRegistry::STATUSES[:not_started]
  end

  def normalized_status(status)
    case status
    when "READY_FOR_DRY_RUN"
      MigrationRouteProofRegistry::STATUSES[:dry_run]
    when MigrationLiveCanaryChecker::CONFIRMED_STATUS
      MigrationRouteProofRegistry::STATUSES[:ready]
    else
      status
    end
  end

  def ready_event?(event)
    event["route_status"] == MigrationRouteProofRegistry::STATUSES[:ready] ||
      event["final_status"] == MigrationLiveCanaryChecker::CONFIRMED_STATUS ||
      event["route_production_safe"] == true ||
      event["production_safe_route"] == true
  end

  def production_safe?(event)
    return false unless event

    ready_event?(event)
  end

  def cached_blockers(status, from, to, event)
    blockers = Array(event&.fetch("blockers", nil))
    return blockers if blockers.present?
    return [] if status == MigrationRouteProofRegistry::STATUSES[:ready]
    return [ "dry-run proven, live canary required" ] if status == MigrationRouteProofRegistry::STATUSES[:dry_run]

    [ "#{from}->#{to} route proof cache is #{status}." ]
  end

  def matrix_route(route)
    ready = route[:status] == MigrationRouteProofRegistry::STATUSES[:ready]
    {
      from_venue: route[:from_venue],
      to_venue: route[:to_venue],
      supported: true,
      preview_available: ready,
      live_available: false,
      readiness_status: route[:status],
      route_status: ready ? "READY_FOR_DRY_RUN" : route[:status],
      blockers: route[:blockers],
      warnings: [ "Cached route proof summary; run refresh for full diagnostics." ],
      missing_capabilities: [],
      required_gates: [],
      supported_modes: [ "full" ],
      supported_sequences: [ "target_first" ],
      dry_run_ready: ready,
      live_path_implemented: false,
      live_canary_confirmed: ready,
      live_autopilot_eligible: ready,
      target_first_supported: true,
      source_first_supported: false,
      current_source_short_available: nil,
      source_current_short_available: nil,
      target_current_short_available: nil,
      target_open_preview_available: ready,
      source_close_preview_available: ready,
      open_orders_status: "cached",
      open_orders_status_source: "cached",
      open_orders_status_target: "cached",
      market_metadata_status_source: "cached",
      market_metadata_status_target: "cached",
      fresh_mellow_target_status: "cached",
      signer_status: "cached",
      signer_status_source: "cached",
      signer_status_target: "cached",
      last_preview_receipt_path: nil,
      last_proof_time: route[:proof_timestamp],
      nado_readiness: [ route[:from_venue], route[:to_venue] ].include?("nado") ? nado_readiness : nil,
      recovery_available: true,
      rollback_available: true,
      orders_submitted: route[:orders_submitted],
      signatures_created: route[:signatures_created]
    }
  end

  def cached_execution(routes:, missing:, current:)
    ready_route_from_current = routes.find { |route| route[:from_venue] == current && route[:status] == MigrationRouteProofRegistry::STATUSES[:ready] }
    dry_route_from_current = routes.find { |route| route[:from_venue] == current && route[:status] == MigrationRouteProofRegistry::STATUSES[:dry_run] }
    missing_from_other_source = missing.find { |route| route[:from_venue] != current }
    next_missing_from_current = preferred_missing_from_current(missing, current)

    if missing.empty?
      return cached_execution_payload(
        status: RandomRotationSetupWizard::STATES[:ready_for_random],
        status_label: "Ready for random",
        next_route: routes.find { |route| route[:from_venue] == current } || routes.first,
        next_action: "enable_random",
        next_action_label: "Enable Random Rotation",
        role: "cached_ready"
      )
    end

    if dry_route_from_current
      return cached_execution_payload(
        status: RandomRotationSetupWizard::STATES[:dry_run_proven],
        status_label: "Dry-run complete / supervised canary required",
        next_route: dry_route_from_current,
        missing_route: dry_route_from_current,
        next_action: "run_live_canary",
        next_action_label: "Run Supervised Live Canary",
        next_action_live: true,
        required_confirmation_phrase: MigrationManualLiveCanaryRunner::CONFIRMATION,
        role: "cached_canary"
      )
    end

    if ready_route_from_current && missing_from_other_source
      return cached_execution_payload(
        status: RandomRotationSetupWizard::STATES[:source_reposition_required],
        status_label: "Setup loaded with limited diagnostics",
        next_route: ready_route_from_current,
        missing_route: missing_from_other_source,
        next_action: "move_to_required_source_venue",
        next_action_label: "Move to required source venue",
        next_action_live: true,
        required_confirmation_phrase: MigrationManualLiveCanaryRunner::CONFIRMATION,
        source_reposition_required: true,
        source_reposition_route: ready_route_from_current,
        source_reposition_reason: "#{missing_from_other_source[:route]} cannot run until its source venue is active.",
        role: "cached_source_reposition"
      )
    end

    cached_execution_payload(
      status: "cached",
      status_label: "Setup loaded with limited diagnostics",
      next_route: next_missing_from_current || missing.first || routes.first,
      missing_route: next_missing_from_current || missing.first,
      next_action: "prepare_next_route",
      next_action_label: "Prepare Next Route",
      role: "cached_prepare"
    )
  end

  def cached_execution_payload(status:, status_label:, next_route:, next_action:, next_action_label:, role:, missing_route: nil, next_action_live: false, required_confirmation_phrase: nil, source_reposition_required: false, source_reposition_route: nil, source_reposition_reason: nil)
    {
      status: status,
      status_label: status_label,
      next_route: next_route,
      missing_route: missing_route,
      next_action: next_action,
      next_action_label: next_action_label,
      next_action_live: next_action_live,
      required_confirmation_phrase: required_confirmation_phrase,
      source_reposition_required: source_reposition_required,
      source_reposition_route: source_reposition_route,
      source_reposition_reason: source_reposition_reason,
      role: role
    }
  end

  def preferred_missing_from_current(missing, current)
    return missing.find { |route| route[:from_venue] == "nado" && route[:to_venue] == "ethereal" } if current == "nado"

    missing.find { |route| route[:from_venue] == current }
  end

  def out_of_tolerance_execution(execution)
    execution.merge(
      status: "out_of_tolerance",
      status_label: "Setup blocked / current hedge out of tolerance",
      next_action: "rebalance_current_hedge",
      next_action_label: "Rebalance current hedge first",
      next_action_live: false,
      required_confirmation_phrase: nil,
      blockers: [ "Rebalance current hedge first" ],
      enable_blockers: [ "Rebalance current hedge first" ]
    )
  end

  def nado_readiness
    snapshot = position.position_dashboard_snapshot
    short = decimal_or_nil(snapshot&.nado_short_eth)
    open_orders = short&.zero? ? 0 : nil
    {
      nado_flat: short ? short.zero? : nil,
      nado_current_short_eth: short&.to_s("F"),
      nado_open_orders_count: open_orders,
      nado_open_short_preview_available: open_orders.to_i.zero?,
      nado_reduce_only_close_preview_available: true,
      nado_reduce_only_close_preview_proof_mode: "synthetic"
    }
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def unavailable_random_setup(reason)
    routes = MigrationRouteProofRegistry::ROUTES.map do |from, to|
      cached_route(from: from, to: to, event: nil).merge(blockers: [ "Route proof cache unavailable. Run refresh/check task." ])
    end
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    {
      action: "random_rotation_setup",
      position_id: position.id,
      status: "unavailable",
      status_label: "Route proof cache unavailable",
      current_venue: current,
      current_venue_label: HedgeVenues.label(current),
      hedge_health: RandomRotationSetupWizard.hedge_health_for(position),
      venue_shorts: RandomRotationSetupWizard.venue_shorts_for(position),
      auto_states: {},
      auto_policy: {},
      migration_gates: {},
      completed_route_proofs: [],
      missing_route_proofs: routes,
      stale_route_proofs: [],
      route_proof_statuses: routes,
      all_routes_ready: false,
      setup_progress: {},
      random_enablement: { ready_routes: 0, total_routes: routes.size, blockers: [ reason ] },
      next_missing_proof_route: routes.first,
      next_executable_route: routes.first,
      source_reposition_required: false,
      next_route: routes.first,
      next_action: "refresh",
      next_action_label: "Refresh route proofs",
      next_action_live: false,
      required_confirmation_phrase: nil,
      plan: {},
      blockers: [ "Route proof cache unavailable. Run refresh/check task.", reason ],
      enable_blockers: [ "Route proof cache unavailable. Run refresh/check task." ],
      limited_diagnostics: true,
      fallback_used: true,
      fallback_reason: reason,
      counters: { orders_submitted: 0, orders_placed: 0, signatures_created: 0, cancels_submitted: 0 }
    }
  end

  def tail_jsonl(path, lines)
    BoundedJsonlTail.read(path, lines: lines)
  end

  def event_time(event)
    Time.zone.parse(event["timestamp"].to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
