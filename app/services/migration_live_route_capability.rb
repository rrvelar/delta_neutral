class MigrationLiveRouteCapability
  ROUTES = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze

  def initialize(position:, route_matrix: nil, canary_checker: MigrationLiveCanaryChecker.new, env: ENV)
    @position = position
    @route_matrix = route_matrix
    @canary_checker = canary_checker
    @env = env
  end

  def report
    {
      position_id: position.id,
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      routes: ROUTES.map { |from, to| route_capability(from, to) },
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :route_matrix, :canary_checker, :env

  def route_capability(from, to)
    proof = proof_route(from, to)
    canary = canary_checker.status_for(from: from, to: to)
    live_path = live_path_implemented?(from, to)
    blockers = []
    blockers << "Route proof is not READY_FOR_DRY_RUN." unless proof&.fetch(:route_status, nil) == "READY_FOR_DRY_RUN"
    blockers << "Live path is unavailable for #{from}->#{to}." unless live_path
    blockers.concat(canary.fetch(:blockers)) unless canary.fetch(:live_canary_confirmed)
    {
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      dry_run_ready: proof&.fetch(:route_status, nil) == "READY_FOR_DRY_RUN",
      live_path_implemented: live_path,
      live_canary_confirmed: canary.fetch(:live_canary_confirmed),
      live_autopilot_eligible: blockers.empty? && live_autopilot_gates_open?(from, to),
      blockers: blockers.uniq,
      missing_capabilities: missing_capabilities(from, to, live_path),
      target_first_supported: true,
      source_first_supported: false,
      current_source_short_available: proof&.fetch(:current_source_short_available, false) || false,
      target_open_preview_available: proof&.fetch(:target_open_preview_available, false) || false,
      source_close_preview_available: proof&.fetch(:source_close_preview_available, false) || false,
      open_orders_status: proof&.fetch(:open_orders_status, "unknown") || "unknown",
      fresh_mellow_target_status: proof&.fetch(:fresh_mellow_target_status, "unknown") || "unknown",
      signer_status: proof&.fetch(:signer_status, "preflight_required") || "preflight_required",
      required_gates: required_gates(from, to),
      latest_canary_receipt_path: canary.fetch(:latest_canary_receipt_path),
      latest_canary_status: canary.fetch(:latest_canary_status),
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def proof_route(from, to)
    routes = Array((route_matrix || default_route_matrix)[:routes] || (route_matrix || default_route_matrix)["routes"])
    routes.find { |route| route[:from_venue] == from && route[:to_venue] == to } ||
      routes.find { |route| route["from_venue"] == from && route["to_venue"] == to }&.deep_symbolize_keys
  end

  def default_route_matrix
    @default_route_matrix ||= HedgeVenueMigrationRouteMatrix.new(position: position).report
  end

  def live_path_implemented?(from, to)
    ROUTES.include?([ from, to ])
  end

  def missing_capabilities(from, to, live_path)
    missing = []
    missing << "live migration executor path for #{from}->#{to}" unless live_path
    missing
  end

  def live_autopilot_gates_open?(from, to)
    bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED") &&
      bool_env("MIGRATION_LIVE_ENABLED") &&
      route_allowed?(from, to) &&
      (![ from, to ].include?("nado") || !bool_env_default("MIGRATION_LIVE_EXCLUDE_NADO", true))
  end

  def route_allowed?(from, to)
    allowed = env.fetch("MIGRATION_LIVE_ALLOWED_ROUTES", "extended->ethereal,ethereal->extended").split(",").map(&:strip)
    allowed.include?("#{from}->#{to}")
  end

  def required_gates(from, to)
    [
      "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED=true",
      "MIGRATION_LIVE_ENABLED=true",
      "MIGRATION_LIVE_REQUIRE_CANARY_SUCCESS=true",
      "source and target auto disabled",
      "source and target open orders zero",
      "fresh complete PositionDashboardSnapshot",
      "LIVE_CANARY_CONFIRMED receipt for #{from}->#{to}"
    ] + ([ from, to ].include?("nado") ? [ "MIGRATION_LIVE_EXCLUDE_NADO=false", "MIGRATION_NADO_LIVE_MIGRATION_ENABLED=true" ] : [])
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def bool_env_default(key, default)
    return default unless env.key?(key)

    bool_env(key)
  end
end
