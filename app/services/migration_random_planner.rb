class MigrationRandomPlanner
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  ROUTES = MigrationLiveRouteCapability::ROUTES

  def initialize(env: ENV, route_matrix: nil, proof_registry: nil, now: -> { Time.current }, random_seed: nil, selector: nil, route_policy: nil)
    @env = env
    @route_matrix = route_matrix
    @proof_registry = proof_registry
    @now = now
    @random_seed = random_seed || env["MIGRATION_RANDOM_SEED"]
    @selector = selector
    @route_policy = route_policy || MigrationRouteOperationalPolicy.new(env: env)
  end

  def plan(position:, require_live_proofs: false)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    routes = matrix_routes(position)
    proof_report = proof_registry.report(position: position)
    candidates = ROUTES.select { |from, to| from == current }.map do |from, to|
      route = route_for(routes, from, to)
      proof = proof_report.fetch(:routes).find { |row| row[:from_venue] == from && row[:to_venue] == to }
      candidate_for(position: position, from: from, to: to, route: route, proof: proof, require_live_proofs: require_live_proofs)
    end
    eligible = candidates.select { |candidate| candidate[:eligible] }
    selected = select_route(eligible)
    blockers = []
    blockers << "no eligible random migration route from #{current}" if selected.nil?
    warnings = [ "Random migration planner is no-live unless an executor is explicitly called with live gates and confirmation." ]
    receipt = {
      action: "migration_random_plan",
      position_id: position.id,
      random_engine_implemented: true,
      current_production_venue: current,
      current_live_eligible_routes: eligible,
      eligible_routes: eligible,
      excluded_routes: candidates.reject { |candidate| candidate[:eligible] },
      selected_route: selected,
      selected_by: selector ? "deterministic" : "random",
      random_seed: random_seed.presence,
      route_proofs: proof_report.fetch(:routes),
      blockers: blockers,
      warnings: warnings,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
    Result.new(selected ? "route_selected" : "no_eligible_route", blockers, warnings, receipt)
  end

  private

  attr_reader :env, :route_matrix, :now, :random_seed, :selector, :route_policy

  def candidate_for(position:, from:, to:, route:, proof:, require_live_proofs:)
    reasons = []
    policy = route_policy.route_status(from: from, to: to)
    reasons << policy.fetch(:blocker) unless policy.fetch(:enabled)
    reasons << "route missing from route matrix" unless route
    reasons << "route preview unavailable" unless route && route[:preview_available]
    reasons << "route is not READY_FOR_DRY_RUN" unless route && route[:route_status].to_s.in?(%w[READY_FOR_DRY_RUN READY_FOR_VIRTUAL_DRY_RUN])
    reasons << "source venue #{from} is flat" unless venue_short(position, from).positive?
    reasons << "target/source open orders must be zero" unless open_orders_clear?(route)
    reasons << "route proof #{proof&.fetch(:status, 'NOT_STARTED')} is not READY_FOR_RANDOM" if require_live_proofs && proof&.fetch(:status) != MigrationRouteProofRegistry::STATUSES[:ready]
    reasons.concat(Array(route&.fetch(:blockers, []))
      .reject { |blocker| live_gate_blocker?(blocker) }
      .reject { |blocker| blocker.to_s.match?(/source venue .* has no current short/i) && venue_short(position, from).positive? })
    {
      route: "#{from}->#{to}",
      from_venue: from,
      to_venue: to,
      eligible: reasons.empty?,
      reasons: reasons.uniq,
      route_status: route&.fetch(:route_status, nil),
      preview_available: route&.fetch(:preview_available, false) || false,
      proof_status: proof&.fetch(:status, "NOT_STARTED"),
      route_enabled: policy.fetch(:enabled),
      route_disabled_reason: policy[:disabled_reason],
      route_policy_key: policy[:key],
      route_strategy: policy[:strategy],
      route_strategy_key: policy[:strategy_key],
      migration_sequence: policy[:migration_sequence],
      target_open_preview_available: route&.fetch(:target_open_preview_available, false) || false,
      source_close_preview_available: route&.fetch(:source_close_preview_available, false) || false,
      open_orders_status: route&.fetch(:open_orders_status, "unknown"),
      blockers: Array(route&.fetch(:blockers, []))
    }
  end

  def matrix_routes(position)
    matrix = route_matrix || HedgeVenueMigrationRouteMatrix.new(position: position).report
    Array(matrix[:routes] || matrix["routes"]).map(&:deep_symbolize_keys)
  end

  def route_for(routes, from, to)
    routes.find { |route| route[:from_venue] == from && route[:to_venue] == to }
  end

  def proof_registry
    @proof_registry ||= MigrationRouteProofRegistry.new(now: now)
  end

  def select_route(eligible)
    return nil if eligible.empty?
    return eligible.find { |route| route[:route] == selector.call(eligible) } || eligible.first if selector

    eligible[random_generator.rand(eligible.size)]
  end

  def random_generator
    return Random.new unless random_seed.present?

    Random.new(Digest::SHA256.hexdigest(random_seed.to_s).to_i(16) % (2**31))
  end

  def venue_short(position, venue)
    snapshot = position.position_dashboard_snapshot
    BigDecimal(snapshot&.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, NoMethodError
    BigDecimal("0")
  end

  def open_orders_clear?(route)
    return false unless route
    return false if route[:open_orders_status].to_s.in?(%w[blocked nado_blocked unknown])

    true
  end

  def live_gate_blocker?(blocker)
    blocker.to_s.match?(/LIVE_ENABLED|LIVE_MIGRATION|live gate|live submit|live execution|confirmation/i)
  end
end
