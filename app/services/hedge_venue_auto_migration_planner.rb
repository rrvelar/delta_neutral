class HedgeVenueAutoMigrationPlanner
  Result = Data.define(:would_migrate, :blockers, :warnings, :receipt)

  STRATEGY = "random_rotation".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_random_rotation")
  LIVE_DISABLED_BLOCKERS = [
    "Nado live migration path not implemented."
  ].freeze

  def initialize(env: ENV, now: -> { Time.current }, migration_events: nil, route_proof_events: nil, route_matrix: nil, random_seed: nil, receipt_dir: RECEIPT_DIR, current_venue_override: nil, virtual_mode: false)
    @env = env
    @now = now
    @migration_events = migration_events
    @route_proof_events = route_proof_events
    @route_matrix = route_matrix
    @random_seed = random_seed || env["MIGRATION_RANDOM_SEED"]
    @receipt_dir = Pathname(receipt_dir)
    @current_venue_override = current_venue_override
    @virtual_mode = virtual_mode
  end

  def plan(position:, recommended_venue: nil, reason: nil)
    production_current = HedgeVenues.normalize(position.hedge&.execution_venue)
    current = HedgeVenues.normalize(current_venue_override.presence || production_current)
    allowed = allowed_venues
    matrix = route_matrix_for(position)
    cooldown = cooldown_remaining
    daily_count = daily_migration_count
    base_blockers = base_blockers(current: current, allowed: allowed, daily_count: daily_count, cooldown: cooldown)
    routes = Array(matrix[:routes] || matrix["routes"])
    candidates = allowed.reject { |venue| venue == current }.map { |venue| route_for(routes, current, venue) }
    dry_run_eligible, decision_excluded, live_eligible, live_blocked = classify_routes(position: position, current: current, candidates: candidates)
    base_blockers << "route proof incomplete because snapshot critical fields are missing" if route_proof_incomplete?(routes)
    selected = base_blockers.empty? ? random_route(dry_run_eligible) : nil
    warnings = [ "Random rotation planner is decision-only; no orders are submitted and no venue is finalized." ]
    selected_live_available = selected ? live_eligible.any? { |route| same_route?(route, selected) } : false

    receipt = {
      action: "random_rotation_decision",
      position_id: position.id,
      strategy: STRATEGY,
      current_venue: current,
      production_venue: production_current,
      virtual_mode: virtual_mode,
      virtual_route: virtual_mode,
      production_source_short_not_required: virtual_mode,
      allowed_venues: allowed,
      eligible_target_venues: dry_run_eligible.map { |route| route.fetch(:to_venue) },
      eligible_routes: dry_run_eligible,
      dry_run_eligible_routes: dry_run_eligible,
      live_eligible_routes: live_eligible,
      excluded_routes: decision_excluded,
      decision_excluded_routes: decision_excluded,
      live_blocked_routes: live_blocked,
      selected_route: selected,
      randomly_selected_route: selected,
      selected_target_venue: selected&.fetch(:to_venue, nil),
      randomly_selected_target_venue: selected&.fetch(:to_venue, nil),
      selected_route_live_available: selected_live_available,
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
      route_proof_status: route_proof_summary(dry_run_eligible: dry_run_eligible, decision_excluded: decision_excluded, live_eligible: live_eligible, live_blocked: live_blocked),
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

  attr_reader :env, :now, :migration_events, :route_proof_events, :route_matrix, :random_seed, :receipt_dir, :current_venue_override, :virtual_mode

  def base_blockers(current:, allowed:, daily_count:, cooldown:)
    blockers = []
    blockers << "MIGRATION_AUTO_STRATEGY must be random_rotation" unless env.fetch("MIGRATION_AUTO_STRATEGY", STRATEGY) == STRATEGY
    blockers << "current venue #{current} is not in MIGRATION_ALLOWED_VENUES" unless allowed.include?(current)
    blockers << "daily migration limit reached" if daily_count >= max_per_day
    blockers << "migration cooldown remaining #{cooldown.round(2)}h" if cooldown.positive?
    blockers
  end

  def classify_routes(position:, current:, candidates:)
    candidates.each_with_object([ [], [], [], [] ]) do |route, (dry_run_eligible, decision_excluded, live_eligible, live_blocked)|
      if route.nil?
        missing = { from_venue: current, to_venue: nil, reasons: [ "route is missing from proof matrix" ] }
        decision_excluded << missing
        live_blocked << missing.merge(live_blockers: missing.fetch(:reasons))
        next
      end

      decision_reasons = decision_exclusion_reasons(position: position, route: route)
      live_reasons = live_exclusion_reasons(position: position, route: route)
      payload = route_payload(route)
      if decision_reasons.empty?
        dry_run_eligible << payload.merge(dry_run_decision_eligible: true, live_execution_eligible: live_reasons.empty?)
      else
        decision_excluded << payload.merge(dry_run_decision_eligible: false, reasons: decision_reasons)
      end

      if live_reasons.empty?
        live_eligible << payload.merge(dry_run_decision_eligible: decision_reasons.empty?, live_execution_eligible: true)
      else
        live_blocked << payload.merge(dry_run_decision_eligible: decision_reasons.empty?, live_execution_eligible: false, live_blockers: live_reasons)
      end
    end
  end

  def decision_exclusion_reasons(position:, route:)
    reasons = []
    route_key = "#{route.fetch(:from_venue)}->#{route.fetch(:to_venue)}"
    reasons << "route #{route_key} is not in MIGRATION_ALLOWED_ROUTES" unless route_allowed?(route_key)
    reasons << "route proof is not READY_FOR_DRY_RUN" if require_route_proof? && !decision_route_proven?(route)
    reasons << "route preview is unavailable" unless decision_preview_available?(route)
    reasons << "source venue has no current short" if !virtual_mode && !venue_short(position, route.fetch(:from_venue)).positive?
    reasons.concat(decision_safety_blockers(route))
    reasons.uniq
  end

  def live_exclusion_reasons(position:, route:)
    reasons = []
    route_key = "#{route.fetch(:from_venue)}->#{route.fetch(:to_venue)}"
    reasons << "route #{route_key} is not in MIGRATION_ALLOWED_ROUTES" unless route_allowed?(route_key)
    reasons << "route proof is not READY_FOR_DRY_RUN" if require_route_proof? && route[:route_status] != "READY_FOR_DRY_RUN"
    reasons << "route preview is unavailable" unless route[:preview_available]
    reasons << "source venue has no current short" unless venue_short(position, route.fetch(:from_venue)).positive?
    reasons << "route live execution is unavailable" unless route[:live_available]
    reasons.concat(Array(route[:blockers]))
    reasons.uniq
  end

  def decision_safety_blockers(route)
    Array(route[:blockers]).reject do |blocker|
      live_disabled_blocker?(blocker) || (virtual_mode && blocker.to_s.match?(/source venue .* has no current short to migrate/i))
    end
  end

  def live_disabled_blocker?(blocker)
    LIVE_DISABLED_BLOCKERS.include?(blocker.to_s) ||
      blocker.to_s.match?(/live .*not implemented|live .*disabled|live migration.*unavailable|live submit|live execution|live path/i)
  end

  def route_payload(route)
    {
      from_venue: route.fetch(:from_venue),
      to_venue: route.fetch(:to_venue),
      route_status: route[:route_status],
      preview_available: route[:preview_available],
      live_available: route[:live_available] || false,
      blockers: Array(route[:blockers]),
      last_proof_time: route[:last_proof_time],
      nado_readiness: route[:nado_readiness],
      virtual_route: virtual_mode,
      production_source_short_not_required: virtual_mode
    }
  end

  def decision_route_proven?(route)
    route[:route_status] == "READY_FOR_DRY_RUN" || (virtual_mode && virtual_capability_proven?(route))
  end

  def decision_preview_available?(route)
    route[:preview_available] || (virtual_mode && virtual_capability_proven?(route))
  end

  def virtual_capability_proven?(route)
    return true if route[:route_status] == "READY_FOR_DRY_RUN"
    return false unless route.fetch(:from_venue) == "nado"

    readiness = (route[:nado_readiness] || {}).with_indifferent_access
    readiness[:nado_reduce_only_close_preview_available] && readiness[:nado_reduce_only_close_preview_proof_mode].present?
  end

  def same_route?(left, right)
    left.fetch(:from_venue) == right.fetch(:from_venue) && left.fetch(:to_venue) == right.fetch(:to_venue)
  end

  def route_for(routes, from, to)
    routes.find { |route| route[:from_venue] == from && route[:to_venue] == to } ||
      routes.find { |route| route["from_venue"] == from && route["to_venue"] == to }&.deep_symbolize_keys
  end

  def route_matrix_for(position)
    return route_matrix.deep_symbolize_keys if route_matrix.present?

    HedgeVenueMigrationRouteMatrix.new(position: position).report
  end

  def route_proof_incomplete?(routes)
    blockers = routes.flat_map { |route| Array(route[:blockers] || route["blockers"]) }
    blockers.any? { |blocker| blocker.to_s.match?(/target short is unavailable|snapshot critical fields|Position dashboard snapshot.*missing|missing critical migration fields/i) }
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

  def route_proof_summary(dry_run_eligible:, decision_excluded:, live_eligible:, live_blocked:)
    {
      dry_run_eligible_count: dry_run_eligible.size,
      decision_excluded_count: decision_excluded.size,
      live_eligible_count: live_eligible.size,
      live_blocked_count: live_blocked.size,
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
