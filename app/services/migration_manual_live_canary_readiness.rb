class MigrationManualLiveCanaryReadiness
  CONFIRMATION = MigrationManualCanaryPlanner::CONFIRMATION

  def initialize(position:, from:, to:, env: ENV, route_matrix: nil, capability_registry: nil, target_preflight: nil, fresh_target: nil, sequence: "target_first")
    @position = position
    @from = from
    @to = to
    @env = env
    @target_preflight = target_preflight
    @fresh_target = fresh_target
    @sequence = sequence
    @route_matrix = route_matrix
    @capability_registry = capability_registry
  end

  def report
    MigrationManualCanaryPlanner.new(
      position: @position,
      from: @from,
      to: @to,
      env: @env,
      target_preflight: @target_preflight,
      fresh_target: @fresh_target,
      sequence: @sequence
    ).report
  end
end
