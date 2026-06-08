class MigrationLiveAutopilotReadiness
  def initialize(position:, env: ENV, proof_registry: nil, preflight_factory: nil, **)
    @position = position
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @preflight_factory = preflight_factory
  end

  def report
    direct = direct_preflight
    routes = Array(direct.dig(:proof_report, :routes)).map { |route| route_payload(route) }
    eligible = routes.select { |route| route.fetch(:live_autopilot_eligible) }
    blocked = routes.reject { |route| route.fetch(:live_autopilot_eligible) }
    {
      action: "live_autopilot_readiness",
      position_id: position.id,
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      route_proof_source: "READY_FOR_RANDOM",
      preflight_source: direct[:preflight_source],
      live_autopilot_enabled: bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED"),
      live_migration_enabled: bool_env("MIGRATION_LIVE_ENABLED"),
      daily_enabled: bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED"),
      dry_run_status: direct,
      live_capabilities: routes,
      live_autopilot_eligible_routes: eligible,
      live_autopilot_blocked_routes: blocked,
      nado_live_blockers: routes.select { |route| [ route[:from_venue], route[:to_venue] ].include?("nado") }.flat_map { |route| route[:live_blockers] }.uniq,
      env_gates: env_gates,
      would_execute_live: false,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :env, :proof_registry, :preflight_factory

  def direct_preflight
    return preflight_factory.call(position: position, stage: "live_autopilot_readiness") if preflight_factory

    MigrationRandomExecutionPreflight.new(
      position: position,
      env: env,
      proof_registry: proof_registry,
      live: false
    ).report
  end

  def route_payload(route)
    policy = MigrationRouteOperationalPolicy.new(env: env)
    ready = route[:status] == MigrationRouteProofRegistry::STATUSES[:ready]
    policy_enabled = policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    live_blockers = live_gate_blockers(route)
    blockers = Array(route[:blockers])
    blockers << "route proof is not READY_FOR_RANDOM" unless ready
    blockers << "route policy disabled for #{route[:route]}" unless policy_enabled
    {
      from_venue: route[:from_venue],
      to_venue: route[:to_venue],
      route: route[:route],
      route_proof_status: route[:status],
      dry_run_ready: ready,
      ready_for_random: ready,
      live_path_implemented: true,
      live_canary_confirmed: route[:status] == MigrationRouteProofRegistry::STATUSES[:ready],
      live_autopilot_eligible: ready && policy_enabled && live_blockers.empty?,
      blockers: blockers.uniq,
      live_blockers: live_blockers,
      required_gates: required_gates(route),
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def live_gate_blockers(route)
    blockers = []
    blockers << "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED must be true" unless bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED")
    blockers << "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    if [ route[:from_venue], route[:to_venue] ].include?("nado")
      blockers << "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit" unless bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
      blockers << "AERODROME_NADO_LIVE_MIGRATION_ENABLED must be true for Nado live migration" unless bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    end
    blockers
  end

  def required_gates(route)
    gates = [
      "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED=true",
      "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED=true",
      "MIGRATION_LIVE_ENABLED=true",
      "route proof READY_FOR_RANDOM",
      "direct open orders zero",
      "active venue inside tolerance before migration"
    ]
    gates += [ "AERODROME_NADO_HEDGE_LIVE_ENABLED=true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED=true" ] if [ route[:from_venue], route[:to_venue] ].include?("nado")
    gates
  end

  def env_gates
    {
      migration_random_rotation_daily_enabled: bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED"),
      migration_random_rotation_live_enabled: bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED"),
      migration_live_enabled: bool_env("MIGRATION_LIVE_ENABLED")
    }
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
