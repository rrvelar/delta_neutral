# Explicit approved-route allow-list for autonomous/random production
# (2026-07-18 Path A: restart with Extended excluded). When
# MIGRATION_ALLOWED_ROUTES is set (DB OperationalSetting wins over env), ONLY
# the listed routes are selectable by the runner; every other route is excluded.
#
# Fail-closed: while subset mode is active the runner refuses to start if the
# list is empty/malformed, names an unknown route, includes a route that is
# policy-disabled or not READY_FOR_RANDOM, or involves a venue in quarantine /
# probation. When the key is unset, normal route policy applies unchanged.
class MigrationApprovedRouteSubset
  KEY = OperationalSettings::ROUTE_SUBSET_KEY
  KNOWN_ROUTES = OperationalSettings::ROUTE_KEYS_BY_ROUTE.keys.freeze

  def self.route_allowed?(from:, to:, env: ENV)
    new(env: env).route_allowed?(from: from, to: to)
  end

  def initialize(env: ENV)
    @env = env
  end

  def raw
    setting = OperationalSetting.find_by(key: KEY)
    return setting.value.to_s if setting

    @env[KEY].to_s
  end

  def active?
    raw.strip.present?
  end

  def entries
    raw.split(",").map { |route| route.strip.downcase }.reject(&:blank?)
  end

  def allowed_routes
    entries.select { |route| KNOWN_ROUTES.include?(route) }
  end

  def invalid_entries
    entries.reject { |route| KNOWN_ROUTES.include?(route) }
  end

  def excluded_routes
    KNOWN_ROUTES - allowed_routes
  end

  # Selection guard: with no subset every route passes (normal policy applies);
  # with an active subset only listed routes pass — a malformed subset therefore
  # allows nothing (fail closed).
  def route_allowed?(from:, to:)
    return true unless active?

    allowed_routes.include?("#{HedgeVenues.normalize(from)}->#{HedgeVenues.normalize(to)}")
  end

  def start_blockers(proof_report:)
    return [] unless active?

    blockers = []
    blockers << "#{KEY} is set but contains no valid routes; list allowed routes explicitly (e.g. nado->ethereal,ethereal->nado)" if allowed_routes.empty?
    invalid_entries.each { |entry| blockers << "#{KEY} contains unknown route #{entry.inspect}" }
    policy = MigrationRouteOperationalPolicy.new(env: @env)
    proofs = Array(proof_report && (proof_report[:routes] || proof_report["routes"])).index_by { |route| route[:route] || route["route"] }
    allowed_routes.each do |route|
      from, to = route.split("->")
      [ from, to ].uniq.each do |venue|
        next unless HedgeVenueQuarantine.autonomous_blocked?(venue, env: @env)

        blockers << "#{KEY} includes #{route} but #{venue} is #{HedgeVenueQuarantine.state(venue, env: @env)}; remove it from the approved subset"
      end
      blockers << "#{KEY} includes #{route} but the route is disabled by route policy" unless policy.route_enabled?(from: from, to: to)
      proof = proofs[route]
      status = proof && (proof[:status] || proof["status"])
      unless status == MigrationRouteProofRegistry::STATUSES[:ready]
        blockers << "#{KEY} includes #{route} but its proof is #{status.presence || 'missing'}; every allowed route must be READY_FOR_RANDOM"
      end
    end
    blockers.uniq
  end

  def report(proof_report: nil)
    base = { subset_mode: active?, key: KEY }
    return base unless active?

    base.merge(
      allowed_routes: allowed_routes,
      invalid_entries: invalid_entries.presence,
      excluded_routes: excluded_routes.map { |route| { route: route, reason: "not in approved subset" } },
      blockers: proof_report ? start_blockers(proof_report: proof_report) : nil
    ).compact
  end
end
