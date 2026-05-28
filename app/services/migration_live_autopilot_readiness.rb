class MigrationLiveAutopilotReadiness
  def initialize(position:, env: ENV, route_matrix: nil, capability_registry: nil)
    @position = position
    @env = env
    @route_matrix = route_matrix || HedgeVenueMigrationRouteMatrix.new(position: position).report
    @capability_registry = capability_registry || MigrationLiveRouteCapability.new(position: position, route_matrix: @route_matrix, env: env)
  end

  def report
    capability = capability_registry.report
    routes = capability.fetch(:routes)
    eligible = routes.select { |route| route.fetch(:live_autopilot_eligible) }
    blocked = routes.reject { |route| route.fetch(:live_autopilot_eligible) }
    {
      action: "live_autopilot_readiness",
      position_id: position.id,
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      live_autopilot_enabled: bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED"),
      live_migration_enabled: bool_env("MIGRATION_LIVE_ENABLED"),
      dry_run_status: route_matrix,
      live_capabilities: routes,
      live_autopilot_eligible_routes: eligible,
      live_autopilot_blocked_routes: blocked,
      nado_live_blockers: routes.select { |route| [ route[:from_venue], route[:to_venue] ].include?("nado") }.flat_map { |route| route[:blockers] }.uniq,
      env_gates: env_gates,
      would_execute_live: false,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :env, :route_matrix, :capability_registry

  def env_gates
    {
      migration_random_rotation_live_enabled: bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED"),
      migration_live_enabled: bool_env("MIGRATION_LIVE_ENABLED"),
      migration_live_require_canary_success: bool_env_default("MIGRATION_LIVE_REQUIRE_CANARY_SUCCESS", true),
      migration_live_exclude_nado: bool_env_default("MIGRATION_LIVE_EXCLUDE_NADO", true),
      migration_live_allowed_routes: env.fetch("MIGRATION_LIVE_ALLOWED_ROUTES", "extended->ethereal,ethereal->extended")
    }
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def bool_env_default(key, default)
    return default unless env.key?(key)

    bool_env(key)
  end
end
