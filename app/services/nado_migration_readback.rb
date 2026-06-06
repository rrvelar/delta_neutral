class NadoMigrationReadback
  def self.confirm_target_short(**kwargs)
    new(**kwargs).confirm_target_short
  end

  def initialize(position:, from:, to:, expected_target_short:, tolerance_eth:, env: ENV,
                 attempts: MigrationTargetFirstFinalVerifier::DEFAULT_ATTEMPTS,
                 interval_seconds: MigrationTargetFirstFinalVerifier::DEFAULT_INTERVAL_SECONDS,
                 sleeper: ->(seconds) { sleep(seconds) }, now: -> { Time.current }, venues: nil)
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @expected_target_short = expected_target_short
    @tolerance_eth = tolerance_eth
    @env = env
    @attempts = attempts
    @interval_seconds = interval_seconds
    @sleeper = sleeper
    @now = now
    @venues = venues
  end

  def confirm_target_short
    verification = MigrationTargetFirstFinalVerifier.new(
      position: position,
      from: from,
      to: to,
      expected_target_short: expected_target_short,
      tolerance_eth: tolerance_eth,
      env: env,
      venues: venues,
      attempts: attempts,
      interval_seconds: interval_seconds,
      sleeper: sleeper,
      now: now
    ).verify
    latest = verification.fetch(:latest_attempt)
    {
      status: verification.fetch(:confirmed) ? "confirmed" : "recheck_required",
      confirmed: verification.fetch(:confirmed),
      target_confirmed: verification.fetch(:target_confirmed),
      source_flat: verification.fetch(:source_flat),
      third_venue_flat: verification.fetch(:third_venue_flat),
      combined_inside_tolerance: verification.fetch(:combined_inside_tolerance),
      open_orders_clear: verification.fetch(:open_orders_clear),
      target_short_eth: latest[:target_venue_short_eth],
      source_short_eth: latest[:source_short_eth],
      combined_short_eth: latest[:combined_short_eth],
      expected_target_short_eth: latest[:expected_target_short_eth],
      tolerance_eth: latest[:tolerance_eth],
      latest_attempt: latest,
      verification: verification,
      blockers: verification.fetch(:blockers),
      readback_source: "canonical_nado_migration_readback"
    }
  end

  private

  attr_reader :position, :from, :to, :expected_target_short, :tolerance_eth, :env, :attempts, :interval_seconds, :sleeper, :now, :venues
end
