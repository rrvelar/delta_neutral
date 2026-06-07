class MigrationRandomReadiness
  def initialize(position:, env: ENV, planner: nil, proof_registry: nil, dashboard_health: nil, canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR, now: -> { Time.current }, execution_preflight_factory: nil)
    @position = position
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new(now: now)
    @planner = planner || MigrationRandomPlanner.new(env: env, proof_registry: @proof_registry, now: now)
    @dashboard_health = dashboard_health
    @canary_dir = Pathname(canary_dir)
    @execution_preflight_factory = execution_preflight_factory
  end

  def report
    proof_report = proof_registry.report(position: position)
    plan = planner.plan(position: position, require_live_proofs: false).receipt
    live_plan = planner.plan(position: position, require_live_proofs: true).receipt
    next_canary = next_recommended_canary(proof_report)
    execution_preflight = random_execution_preflight_report(proof_report)
    pending_report = execution_preflight.slice(
      :pending_nado_target_continuation,
      :pending_nado_target_continuation_blocking,
      :stale_pending_continuation_ignored,
      :pending_continuation_classification
    )
    pending_continuation = pending_report[:pending_nado_target_continuation]
    pending_continuation_blocking = pending_report[:pending_nado_target_continuation_blocking] == true
    blockers = live_blockers(proof_report: proof_report, live_plan: live_plan, pending_continuation: pending_continuation)
    blockers.delete("pending target=Nado migration continuation must be completed before random migration") unless pending_continuation_blocking
    {
      action: "migration_random_readiness",
      position_id: position.id,
      random_engine_implemented: true,
      current_production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      current_live_eligible_routes: live_plan.fetch(:eligible_routes),
      current_rehearsal_eligible_routes: plan.fetch(:eligible_routes),
      next_recommended_canary: next_canary,
      completed_route_proofs: proof_report.fetch(:completed_route_proofs),
      missing_route_proofs: proof_report.fetch(:missing_route_proofs),
      stale_route_proofs: proof_report.fetch(:stale_route_proofs),
      current_safe_to_rehearse: plan.fetch(:selected_route).present?,
      current_safe_to_live_if_operator_gates_open: blockers.empty?,
      exact_missing_implementation_items: [],
      blockers: blockers,
      operator_commands: operator_commands(next_canary),
      route_proof_statuses: proof_report.fetch(:routes),
      random_live_gates: random_live_gates,
      pending_nado_target_continuation: pending_continuation,
      pending_nado_target_continuation_blocking: pending_continuation_blocking,
      stale_pending_continuation_ignored: pending_report[:stale_pending_continuation_ignored] == true,
      pending_continuation_classification: pending_report[:pending_continuation_classification],
      preflight_source: execution_preflight[:preflight_source],
      direct_venue_shorts: execution_preflight[:direct_venue_shorts],
      direct_open_orders: execution_preflight[:direct_open_orders],
      nado_auto_summary: nado_auto_summary,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :planner, :proof_registry

  def random_execution_preflight_report(proof_report)
    if @execution_preflight_factory
      return @execution_preflight_factory.call(position: position, proof_registry: proof_registry)
    end

    direct = snapshot_direct_report(proof_report)
    pending = MigrationPendingNadoContinuationClassifier.new(
      position: position,
      proof_registry: proof_registry,
      proof_report: proof_report,
      direct_report: direct,
      canary_dir: @canary_dir
    ).report
    direct.merge(
      pending,
      preflight_source: "migration_random_execution_preflight",
      direct_venue_shorts: %w[extended ethereal nado].to_h { |venue| [ venue, direct.dig(:venues, venue, :short_eth)&.to_s("F") ] },
      direct_open_orders: %w[extended ethereal nado].to_h { |venue| [ venue, direct.dig(:venues, venue, :open_orders_status) ] }
    )
  end

  def snapshot_direct_report(proof_report)
    snapshot = position.position_dashboard_snapshot
    venues = %w[extended ethereal nado].to_h do |venue|
      short = snapshot&.public_send("#{venue}_short_eth")
      open_orders_count = venue == "extended" ? snapshot&.open_orders_count_extended : 0
      [ venue, {
        short_eth: decimal_or_nil(short),
        position_status: snapshot ? "ok" : "error",
        open_orders_count: open_orders_count,
        open_orders_status: open_orders_count.nil? ? "unknown" : (open_orders_count.to_i.zero? ? "zero" : "blocked")
      } ]
    end
    active = venues.select { |_venue, report| report[:short_eth] && report[:short_eth] > BigDecimal("0.001") }.keys
    blockers = []
    blockers << "dashboard snapshot is unavailable for random readiness diagnostics" unless snapshot
    blockers << "all enabled route proofs must be READY_FOR_RANDOM" if enabled_missing_route_proofs(proof_report).present?
    blockers << "stale route proofs must be resolved" if proof_report.fetch(:stale_route_proofs).present?
    blockers << "more than one venue has exposure" if active.size > 1
    blockers << "no venue has the production hedge" if snapshot && active.empty?
    blockers << "app production venue and actual venue exposure disagree" if snapshot && active.one? && active.first != HedgeVenues.normalize(position.hedge&.execution_venue)
    blockers << "inside tolerance cannot be confirmed" if snapshot&.inside_tolerance.nil?
    blockers << "current hedge outside tolerance" if snapshot&.inside_tolerance == false
    venues.each do |venue, report|
      blockers << "#{venue} short amount is unknown" if report[:short_eth].nil?
      blockers << "#{venue} open orders could not be confirmed zero" if report[:open_orders_status] == "unknown"
      blockers << "#{venue} open orders must be zero" if report[:open_orders_status] == "blocked"
    end
    {
      accepted: blockers.empty?,
      blockers: blockers.uniq,
      warnings: [],
      production_venue: HedgeVenues.normalize(position.hedge&.execution_venue),
      venues: venues,
      inside_tolerance: snapshot&.inside_tolerance == true,
      proof_report: proof_report
    }
  end

  def live_blockers(proof_report:, live_plan:, pending_continuation:)
    blockers = []
    blockers << "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "all enabled route proofs must be READY_FOR_RANDOM" if enabled_missing_route_proofs(proof_report).present?
    blockers << "no eligible proven route from current production venue" if live_plan.fetch(:selected_route).blank?
    blockers << "pending ShortRebalance must be resolved before random migration" if pending_rebalance?
    blockers << "pending recovery must be resolved before random migration" if pending_recovery?
    blockers << "pending target=Nado migration continuation must be completed before random migration" if pending_continuation
    blockers << "dashboard health must be HEALTHY" unless dashboard_healthy?
    blockers.uniq
  end

  def next_recommended_canary(proof_report)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    preferred = preferred_missing_route(proof_report.fetch(:routes), current) ||
      proof_report.fetch(:routes).find { |route| route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] }
    return nil unless preferred

    preferred.merge(commands_for(preferred[:from_venue], preferred[:to_venue]))
  end

  def preferred_missing_route(routes, current)
    candidates = routes.select { |route| route[:from_venue] == current && route[:status] != MigrationRouteProofRegistry::STATUSES[:ready] }
    return candidates.find { |route| route[:to_venue] == "ethereal" } if current == "nado"

    candidates.first
  end

  def operator_commands(next_canary)
    commands = {
      route_proofs: "bin/rails migration:route_proofs position_id=#{position.id}",
      random_readiness: "bin/rails migration:random_readiness position_id=#{position.id}",
      random_rehearse: "bin/rails migration:random_rehearse position_id=#{position.id} dry_run=true"
    }
    return commands unless next_canary

    commands.merge(commands_for(next_canary[:from_venue], next_canary[:to_venue]))
  end

  def commands_for(from, to)
    strategy = MigrationRouteOperationalPolicy.new(env: @env).route_strategy(from: from, to: to)
    {
      next_canary_dry_run: "bin/rails migration:rehearse_route position_id=#{position.id} from=#{from} to=#{to} mode=full sequence=#{strategy} dry_run=true",
      next_canary_live: "bin/rails migration:run_manual_live_canary position_id=#{position.id} from=#{from} to=#{to} sequence=#{strategy} confirmation=#{MigrationManualLiveCanaryRunner::CONFIRMATION}",
      nado_target_continuation: to == "nado" && strategy == "target_first" ? "bin/rails migration:continue_target_first_after_nado_confirmed position_id=#{position.id} from=#{from} to=#{to} dry_run=true" : nil,
      recovery: "bin/rails migration:recover_target_first_source_close position_id=#{position.id} from=#{from} to=#{to} dry_run=true"
    }.compact
  end

  def random_live_gates
    {
      migration_random_rotation_live_enabled: bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED"),
      migration_live_enabled: bool_env("MIGRATION_LIVE_ENABLED"),
      migration_auto_enabled: bool_env("MIGRATION_AUTO_ENABLED")
    }
  end

  def nado_auto_summary
    rows = position.hedge&.short_rebalances&.where(venue: "nado")&.order(created_at: :desc) || ShortRebalance.none
    pending_rows = rows.select { |row| row.status == ShortRebalance::STATUS_PENDING }
    active_pending = pending_rows.find { |row| NadoStalePendingRebalanceResolver.new.active_pending?(row, position: position) }
    {
      latest_nado_auto_success: rows.find { |row| row.status == ShortRebalance::STATUS_SUCCESS }&.id,
      latest_nado_pending: active_pending&.id,
      historical_nado_pending_count: pending_rows.size,
      stale_acknowledged_nado_pending_count: rows.count { |row| row.status.in?(ShortRebalance::STALE_PENDING_STATUSES) },
      latest_nado_failure: rows.find { |row| row.status == ShortRebalance::STATUS_FAILED }&.id,
      historical_prefix_confirmation_failed_count: rows.count { |row| row.status == ShortRebalance::STATUS_FAILED && row.message.to_s.include?("submitted confirmation must equal") }
    }
  end

  def pending_rebalance?
    return false unless position.hedge

    position.hedge.short_rebalances.where(status: ShortRebalance::STATUS_PENDING).any? do |rebalance|
      rebalance.venue == "nado" ? NadoStalePendingRebalanceResolver.new.active_pending?(rebalance, position: position) : true
    end
  end

  def pending_recovery?
    false
  end

  def decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def dashboard_healthy?
    status = @dashboard_health || combined_dashboard_status || "HEALTHY"
    status.to_s.in?(%w[HEALTHY OK healthy ok])
  end

  def combined_dashboard_status
    snapshot = position.position_dashboard_snapshot
    return unless snapshot
    return "ACTION REQUIRED" if snapshot.inside_tolerance == false
    return "OVERHEDGED" if active_short_venues(snapshot).size > 1
    "HEALTHY" if snapshot.inside_tolerance == true && active_short_venues(snapshot).size == 1
  end

  def active_short_venues(snapshot)
    %w[extended ethereal nado].select do |venue|
      BigDecimal(snapshot.public_send("#{venue}_short_eth").to_s) > BigDecimal("0.001")
    rescue ArgumentError, TypeError
      false
    end
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def enabled_missing_route_proofs(proof_report)
    policy = MigrationRouteOperationalPolicy.new(env: env)
    proof_report.fetch(:missing_route_proofs).reject do |route|
      !policy.route_enabled?(from: route[:from_venue], to: route[:to_venue])
    end
  end

  def env
    @env
  end
end
