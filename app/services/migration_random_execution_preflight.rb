class MigrationRandomExecutionPreflight
  PENDING_CONTINUATION_BLOCKER = "pending target=Nado migration continuation must be completed before migration".freeze

  def initialize(position:, env: ENV, proof_registry: nil, venue_builder: HedgeVenues, signer_client: nil,
                 fresh_target_factory: nil, canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR,
                 direct_preflight_factory: nil, live: false, confirmation: nil, expected_confirmation: nil,
                 tolerance_multiplier: "1.0", extra_tolerance_eth: "0",
                 max_allowed_drift_eth: nil, max_allowed_drift_ratio: nil)
    @position = position
    @env = env
    @proof_registry = proof_registry || MigrationRouteProofRegistry.new
    @venue_builder = venue_builder
    @signer_client = signer_client
    @fresh_target_factory = fresh_target_factory
    @canary_dir = canary_dir
    @direct_preflight_factory = direct_preflight_factory
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @confirmation = confirmation
    @expected_confirmation = expected_confirmation
    @tolerance_multiplier = tolerance_multiplier
    @extra_tolerance_eth = extra_tolerance_eth
    @max_allowed_drift_eth = max_allowed_drift_eth
    @max_allowed_drift_ratio = max_allowed_drift_ratio
  end

  def report
    direct = direct_report
    proof_report = report_value(direct, :proof_report)
    pending = MigrationPendingNadoContinuationClassifier.new(
      position: position,
      proof_registry: proof_registry,
      proof_report: proof_report,
      direct_report: direct,
      canary_dir: canary_dir
    ).report
    blockers = Array(direct[:blockers])
    blockers << PENDING_CONTINUATION_BLOCKER if pending[:pending_nado_target_continuation_blocking]
    blockers.concat(live_gate_blockers)
    direct.merge(
      preflight_source: "migration_random_execution_preflight",
      status: blockers.empty? ? (Array(direct[:warnings]).empty? ? "ready" : "warning") : "blocked",
      accepted: blockers.empty?,
      can_submit: blockers.empty?,
      blockers: blockers.uniq,
      hard_blockers: blockers.uniq,
      readiness: random_readiness_payload(direct, pending, blockers),
      pending_nado_target_continuation: pending[:pending_nado_target_continuation],
      pending_nado_target_continuation_blocking: pending[:pending_nado_target_continuation_blocking],
      stale_pending_continuation_ignored: pending[:stale_pending_continuation_ignored],
      pending_continuation_classification: pending[:pending_continuation_classification],
      pending_continuation_diagnostics: pending[:pending_continuation_diagnostics],
      direct_venue_shorts: direct_venue_shorts(direct),
      direct_open_orders: direct_open_orders(direct),
      random_execution_preflight: true
    )
  end

  private

  attr_reader :position, :env, :proof_registry, :venue_builder, :signer_client, :fresh_target_factory,
    :canary_dir, :direct_preflight_factory, :live, :confirmation, :expected_confirmation,
    :tolerance_multiplier, :extra_tolerance_eth, :max_allowed_drift_eth, :max_allowed_drift_ratio

  def direct_report
    if direct_preflight_factory
      return direct_preflight_factory.call(position: position, stage: "random_execution_preflight")
    end

    kwargs = {
      position: position,
      env: env,
      proof_registry: proof_registry,
      venue_builder: venue_builder,
      signer_client: signer_client,
      fresh_target_factory: fresh_target_factory,
      readiness_factory: ->(**) { {} },
      require_route_proofs: true,
      require_random_readiness: false,
      tolerance_multiplier: tolerance_multiplier,
      extra_tolerance_eth: extra_tolerance_eth,
      max_allowed_drift_eth: max_allowed_drift_eth,
      max_allowed_drift_ratio: max_allowed_drift_ratio
    }.compact
    MigrationExecutionPreflight.new(**kwargs).report
  end

  def live_gate_blockers
    return [] unless live

    blockers = []
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{expected_confirmation}" if expected_confirmation && confirmation != expected_confirmation
    blockers
  end

  def random_readiness_payload(direct, pending, blockers)
    {
      pending_nado_target_continuation: pending[:pending_nado_target_continuation],
      pending_nado_target_continuation_blocking: pending[:pending_nado_target_continuation_blocking],
      stale_pending_continuation_ignored: pending[:stale_pending_continuation_ignored],
      pending_continuation_classification: pending[:pending_continuation_classification],
      blockers: blockers.uniq,
      preflight_source: "migration_random_execution_preflight",
      direct_venue_shorts: direct_venue_shorts(direct),
      direct_open_orders: direct_open_orders(direct)
    }
  end

  def direct_venue_shorts(report)
    %w[extended ethereal nado].to_h do |venue|
      [ venue, venue_value(report, venue, :short_eth)&.to_s("F") ]
    end
  end

  def direct_open_orders(report)
    %w[extended ethereal nado].to_h do |venue|
      details = venue_report(report, venue)
      [ venue, {
        status: hash_value(details, :open_orders_status),
        count: hash_value(details, :open_orders_count),
        message: hash_value(details, :open_orders_message)
      }.compact ]
    end
  end

  def report_value(report, key)
    hash_value(report, key)
  end

  def venue_value(report, venue, key)
    hash_value(venue_report(report, venue), key)
  end

  def venue_report(report, venue)
    venues = report_value(report, :venues) || {}
    hash_value(venues, venue) || {}
  end

  def hash_value(hash, key)
    return nil unless hash.respond_to?(:[])

    hash[key] || hash[key.to_s]
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
