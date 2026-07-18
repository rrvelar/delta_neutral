# Operator-controlled staged venue re-admission (2026-07-17/18: Extended submit
# endpoint failed live -> quarantined; re-admission is staged, never immediate).
#
# States (per venue):
#   "quarantined" — EXTENDED_VENUE_QUARANTINED=true (wins over probation).
#     Autonomous production must not select routes involving the venue; the
#     runner refuses to start; supervised canaries may not TARGET the venue.
#   "probation"   — EXTENDED_VENUE_PROBATION=true (quarantine false).
#     Autonomous production still fully blocked; a supervised canary may target
#     the venue ONLY with the explicit per-run env gate
#     EXTENDED_PROBATION_CANARY_ALLOWED=true passed inline (never persisted).
#   "normal"      — neither flag set; existing route policy applies.
#
# Recovery and migrate-out paths (closing or moving exposure OFF the venue,
# including canaries whose SOURCE is the venue) are allowed in every state.
module HedgeVenueQuarantine
  KEYS = { "extended" => "EXTENDED_VENUE_QUARANTINED" }.freeze
  PROBATION_KEYS = { "extended" => "EXTENDED_VENUE_PROBATION" }.freeze
  # Per-run supervised-canary gate, read from process ENV only (pass inline on
  # the canary command); deliberately NOT an OperationalSettings key so it can
  # never be persisted in the DB.
  PROBATION_CANARY_GATE_KEYS = { "extended" => "EXTENDED_PROBATION_CANARY_ALLOWED" }.freeze

  STATES = %w[normal probation quarantined].freeze

  def self.quarantined?(venue, env: ENV)
    key = KEYS[HedgeVenues.normalize(venue)]
    return false unless key

    OperationalSettings.enabled?(key, env: env)
  end

  def self.probation?(venue, env: ENV)
    key = PROBATION_KEYS[HedgeVenues.normalize(venue)]
    return false unless key

    OperationalSettings.enabled?(key, env: env)
  end

  # Quarantine wins when both flags are set (fail-closed).
  def self.state(venue, env: ENV)
    return "quarantined" if quarantined?(venue, env: env)
    return "probation" if probation?(venue, env: env)

    "normal"
  end

  # Autonomous production (random rotation runner) is blocked from a venue in
  # BOTH quarantined and probation states.
  def self.autonomous_blocked?(venue, env: ENV)
    state(venue, env: env) != "normal"
  end

  def self.quarantined_venues(env: ENV)
    KEYS.keys.select { |venue| quarantined?(venue, env: env) }
  end

  def self.autonomous_blocked_venues(env: ENV)
    KEYS.keys.select { |venue| autonomous_blocked?(venue, env: env) }
  end

  def self.probation_canary_gate_key(venue)
    PROBATION_CANARY_GATE_KEYS[HedgeVenues.normalize(venue)]
  end

  def self.probation_canary_allowed?(venue, env: ENV)
    key = probation_canary_gate_key(venue)
    return false unless key

    ActiveModel::Type::Boolean.new.cast(env[key]) == true
  end

  # Blockers for a SUPERVISED canary targeting `to_venue`. A canary whose source
  # is the venue (migrate-out) gets no blockers from here.
  def self.supervised_canary_blockers(to_venue:, env: ENV)
    venue = HedgeVenues.normalize(to_venue)
    case state(venue, env: env)
    when "quarantined"
      [ "#{venue} is quarantined; supervised canaries may not target it (recovery/migrate-out from #{venue} remain allowed)" ]
    when "probation"
      if probation_canary_allowed?(venue, env: env)
        []
      else
        [ "#{venue} is in probation; a supervised canary targeting it requires #{probation_canary_gate_key(venue)}=true passed inline for this run" ]
      end
    else
      []
    end
  end

  # Structured status for the runner status file / dashboard.
  def self.status_report(venue: "extended", env: ENV)
    venue = HedgeVenues.normalize(venue)
    venue_state = state(venue, env: env)
    gate_set = probation_canary_allowed?(venue, env: env)
    canary_targeting = case venue_state
    when "quarantined" then "refused"
    when "probation" then gate_set ? "allowed_with_per_run_gate" : "requires_#{probation_canary_gate_key(venue)}"
    else "allowed"
    end
    report = {
      venue: venue,
      state: venue_state.upcase,
      autonomous_production_blocked: venue_state != "normal",
      supervised_canary_targeting: canary_targeting,
      probation_canary_gate_set: gate_set,
      recovery_and_migrate_out: "always_allowed"
    }
    if venue == "extended"
      health = ExtendedSubmitHealth.snapshot
      report[:submit_health] = {
        last_success_at: health["last_success_at"],
        last_failure_at: health["last_failure_at"],
        consecutive_failures: health.fetch("consecutive_failures", 0).to_i,
        successes_since_last_failure: health.fetch("successes_since_last_failure", 0).to_i,
        recently_failed: ExtendedSubmitHealth.recently_failed?,
        window_seconds: ExtendedSubmitHealth::DEFAULT_WINDOW_SECONDS
      }
    end
    report
  end
end
