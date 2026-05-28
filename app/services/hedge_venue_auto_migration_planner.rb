class HedgeVenueAutoMigrationPlanner
  Result = Data.define(:would_migrate, :blockers, :warnings, :receipt)

  STRATEGY = "random_rotation".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_random_rotation")
  LIVE_DISABLED_BLOCKERS = [
    "Nado live migration path not implemented."
  ].freeze

  def initialize(env: ENV, now: -> { Time.current }, migration_events: nil, route_proof_events: nil, route_matrix: nil, random_seed: nil, receipt_dir: RECEIPT_DIR)
    @env = env
    @now = now
    @migration_events = migration_events
    @route_proof_events = route_proof_events
    @route_matrix = route_matrix
    @random_seed = random_seed || env["MIGRATION_RANDOM_SEED"]
    @receipt_dir = Pathname(receipt_dir)
  end

  def plan(position:, recommended_venue: nil, reason: nil)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    allowed = allowed_venues
    matrix = route_matrix_for(position)
    cooldown = cooldown_remaining
    daily_count = daily_migration_count
    base_blockers = base_blockers(current: current, allowed: allowed, daily_count: daily_count, cooldown: cooldown)
    routes = Array(matrix[:routes] || matrix["routes"])
    candidates = allowed.reject { |venue| venue == current }.map { |venue| route_for(routes, current, venue) }
    eligible, excluded = classify_routes(position: position, current: current, candidates: candidates)
    selected = base_blockers.empty? ? random_route(eligible) : nil
    warnings = [ "Random rotation planner is decision-only; no orders are submitted and no venue is finalized." ]

    receipt = {
      action: "random_rotation_decision",
      position_id: position.id,
      strategy: STRATEGY,
      current_venue: current,
      allowed_venues: allowed,
      eligible_target_venues: eligible.map { |route| route.fetch(:to_venue) },
      eligible_routes: eligible,
      excluded_routes: excluded,
      selected_route: selected,
      randomly_selected_route: selected,
      selected_target_venue: selected&.fetch(:to_venue, nil),
      randomly_selected_target_venue: selected&.fetch(:to_venue, nil),
      random_seed: random_seed.presence,
      selection_id: selection_id(selected),
      status: selected ? "RANDOM_ROUTE_SELECTED" : "NO_ELIGIBLE_ROUTE",
      auto_enabled: bool_env("MIGRATION_AUTO_ENABLED"),
      dry_run_only: bool_env_default("MIGRATION_AUTO_DRY_RUN_ONLY", true),
      live_execution_enabled: false,
      live_available: false,
      would_migrate: false,
      blockers: selected ? base_blockers : (base_blockers + [ "no eligible random rotation route" ]).uniq,
      warnings: warnings,
      cooldown_status: { remaining_hours: cooldown, passed: cooldown.zero? },
      daily_limit_status: { count: daily_count, max_per_day: max_per_day, passed: daily_count < max_per_day },
      route_proof_status: route_proof_summary(eligible: eligible, excluded: excluded),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
    Result.new(false, receipt[:blockers], warnings, receipt)
  end

  def write_receipt(receipt)
    HedgeVenueMigrationReceiptWriter.new(now: now, receipt_dir: receipt_dir).write(receipt)
  end

  private

  attr_reader :env, :now, :migration_events, :route_proof_events, :route_matrix, :random_seed, :receipt_dir

  def base_blockers(current:, allowed:, daily_count:, cooldown:)
    blockers = []
    blockers << "MIGRATION_AUTO_STRATEGY must be random_rotation" unless env.fetch("MIGRATION_AUTO_STRATEGY", STRATEGY) == STRATEGY
    blockers << "current venue #{current} is not in MIGRATION_ALLOWED_VENUES" unless allowed.include?(current)
    blockers << "daily migration limit reached" if daily_count >= max_per_day
    blockers << "migration cooldown remaining #{cooldown.round(2)}h" if cooldown.positive?
    blockers
  end

  def classify_routes(position:, current:, candidates:)
    candidates.each_with_object([ [], [] ]) do |route, (eligible, excluded)|
      if route.nil?
        excluded << { from_venue: current, to_venue: nil, reasons: [ "route is missing from proof matrix" ] }
        next
      end

      reasons = exclusion_reasons(position: position, route: route)
      if reasons.empty?
        eligible << route_payload(route)
      else
        excluded << route_payload(route).merge(reasons: reasons)
      end
    end
  end

  def exclusion_reasons(position:, route:)
    reasons = []
    route_key = "#{route.fetch(:from_venue)}->#{route.fetch(:to_venue)}"
    reasons << "route #{route_key} is not in MIGRATION_ALLOWED_ROUTES" unless route_allowed?(route_key)
    reasons << "route proof is not READY_FOR_DRY_RUN" if require_route_proof? && route[:route_status] != "READY_FOR_DRY_RUN"
    reasons << "source venue has no current short" unless venue_short(position, route.fetch(:from_venue)).positive?
    reasons.concat(safety_blockers(route))
    reasons.uniq
  end

  def safety_blockers(route)
    Array(route[:blockers]).reject { |blocker| live_disabled_blocker?(blocker) }
  end

  def live_disabled_blocker?(blocker)
    LIVE_DISABLED_BLOCKERS.include?(blocker.to_s) || blocker.to_s.match?(/live .*not implemented|live .*disabled|live migration.*unavailable/i)
  end

  def route_payload(route)
    {
      from_venue: route.fetch(:from_venue),
      to_venue: route.fetch(:to_venue),
      route_status: route[:route_status],
      preview_available: route[:preview_available],
      live_available: false,
      blockers: Array(route[:blockers]),
      last_proof_time: route[:last_proof_time]
    }
  end

  def route_for(routes, from, to)
    routes.find { |route| route[:from_venue] == from && route[:to_venue] == to } ||
      routes.find { |route| route["from_venue"] == from && route["to_venue"] == to }&.deep_symbolize_keys
  end

  def route_matrix_for(position)
    return route_matrix.deep_symbolize_keys if route_matrix.present?

    HedgeVenueMigrationRouteMatrix.new(position: position).report
  end

  def random_route(eligible)
    return nil if eligible.empty?

    eligible[random_generator.rand(eligible.size)]
  end

  def random_generator
    return Random.new unless random_seed.present?

    Random.new(Digest::SHA256.hexdigest(random_seed.to_s).to_i(16) % (2**31))
  end

  def selection_id(selected)
    base = [ random_seed.presence || SecureRandom.hex(8), selected&.fetch(:from_venue, nil), selected&.fetch(:to_venue, nil), now.call.utc.iso8601 ].join(":")
    Digest::SHA256.hexdigest(base).first(16)
  end

  def route_proof_summary(eligible:, excluded:)
    {
      eligible_count: eligible.size,
      excluded_count: excluded.size,
      require_route_proof: require_route_proof?
    }
  end

  def allowed_venues
    env.fetch("MIGRATION_ALLOWED_VENUES", "extended,ethereal,nado").split(",").map { |value| HedgeVenues.normalize(value.strip) }.reject(&:blank?)
  end

  def route_allowed?(route_key)
    values = env["MIGRATION_ALLOWED_ROUTES"].to_s.split(",").map(&:strip).reject(&:blank?)
    values.empty? || values.include?(route_key)
  end

  def require_route_proof?
    bool_env_default("MIGRATION_REQUIRE_ROUTE_PROOF", true)
  end

  def venue_short(position, venue)
    snapshot = position.position_dashboard_snapshot
    BigDecimal(snapshot&.public_send("#{venue}_short_eth").to_s)
  rescue ArgumentError, NoMethodError
    BigDecimal("0")
  end

  def daily_migration_count
    events.count { |event| event[:timestamp] && Time.zone.parse(event[:timestamp].to_s) >= now.call.beginning_of_day }
  rescue ArgumentError
    0
  end

  def cooldown_remaining
    latest = events.filter_map { |event| Time.zone.parse(event[:timestamp].to_s) rescue nil }.max
    return 0 unless latest

    elapsed_hours = (now.call - latest) / 1.hour
    [ min_cooldown_hours - elapsed_hours, 0 ].max
  end

  def events
    @events ||= migration_events || read_receipt_events
  end

  def read_receipt_events
    Dir.glob(receipt_dir.join("*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map { |line| JSON.parse(line).symbolize_keys rescue nil }
    end
  rescue SystemCallError
    []
  end

  def max_per_day
    Integer(env.fetch("MIGRATION_MAX_PER_DAY", "1"))
  rescue ArgumentError
    1
  end

  def min_cooldown_hours
    BigDecimal(env.fetch("MIGRATION_MIN_COOLDOWN_HOURS", "24")).to_f
  rescue ArgumentError
    24
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def bool_env_default(key, default)
    return default unless env.key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end
end
