class MigrationLiveRouteCapability
  ROUTES = [
    [ "extended", "ethereal" ],
    [ "ethereal", "extended" ],
    [ "extended", "nado" ],
    [ "nado", "extended" ],
    [ "ethereal", "nado" ],
    [ "nado", "ethereal" ]
  ].freeze

  def initialize(position:, route_matrix: nil, canary_checker: nil, env: ENV)
    @position = position
    @route_matrix = route_matrix
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

  attr_reader :position, :route_matrix, :env

  def route_capability(from, to)
    proof = proof_route(from, to)
    live_path = live_path_implemented?(from, to)
    ready = proof_ready?(proof)
    blockers = []
    blockers << "Route proof is not READY_FOR_RANDOM." unless ready
    blockers << "Live path is unavailable for #{from}->#{to}." unless live_path
    {
      from_venue: from,
      to_venue: to,
      route: "#{from}->#{to}",
      dry_run_ready: ready,
      ready_for_random: ready,
      live_path_implemented: live_path,
      live_canary_confirmed: ready,
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
      latest_canary_receipt_path: nil,
      latest_canary_status: ready ? "READY_FOR_RANDOM" : nil,
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
      bool_env("MIGRATION_RANDOM_ROTATION_DAILY_ENABLED") &&
      bool_env("MIGRATION_LIVE_ENABLED") &&
      route_allowed?(from, to) &&
      (![ from, to ].include?("nado") || (bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED") && bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")))
  end

  def route_allowed?(from, to)
    allowed = env.fetch("MIGRATION_LIVE_ALLOWED_ROUTES", ROUTES.map { |source, target| "#{source}->#{target}" }.join(",")).split(",").map(&:strip)
    allowed.include?("#{from}->#{to}")
  end

  def required_gates(from, to)
    [
      "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED=true",
      "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED=true",
      "MIGRATION_LIVE_ENABLED=true",
      "source and target auto disabled",
      "source and target open orders zero",
      "route proof READY_FOR_RANDOM"
    ] + ([ from, to ].include?("nado") ? [ "AERODROME_NADO_HEDGE_LIVE_ENABLED=true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED=true" ] : [])
  end

  def proof_ready?(proof)
    status = proof&.fetch(:status, nil) || proof&.fetch(:route_status, nil)
    status.to_s.in?(%w[READY_FOR_RANDOM READY_FOR_DRY_RUN])
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
