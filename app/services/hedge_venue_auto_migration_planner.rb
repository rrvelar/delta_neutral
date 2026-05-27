class HedgeVenueAutoMigrationPlanner
  Result = Data.define(:would_migrate, :blockers, :warnings, :receipt)

  def initialize(env: ENV, now: -> { Time.current }, migration_events: nil)
    @env = env
    @now = now
    @migration_events = migration_events
  end

  def plan(position:, recommended_venue: nil, reason: nil)
    current = HedgeVenues.normalize(position.hedge&.execution_venue)
    recommended = recommended_venue.present? ? HedgeVenues.normalize(recommended_venue) : current
    blockers = []
    warnings = []
    blockers << "MIGRATION_AUTO_ENABLED must be true" unless bool_env("MIGRATION_AUTO_ENABLED")
    blockers << "migration reason is required" if bool_env_default("MIGRATION_REASON_REQUIRED", true) && reason.blank?
    blockers << "recommended venue matches current venue" if recommended == current
    blockers << "current venue #{current} is not in MIGRATION_ALLOWED_FROM_VENUES" unless allowed?("MIGRATION_ALLOWED_FROM_VENUES", current)
    blockers << "recommended venue #{recommended} is not in MIGRATION_ALLOWED_TO_VENUES" unless allowed?("MIGRATION_ALLOWED_TO_VENUES", recommended)
    blockers << "daily migration limit reached" if daily_migration_count >= max_per_day
    cooldown = cooldown_remaining
    blockers << "migration cooldown remaining #{cooldown.round(2)}h" if cooldown.positive?
    warnings << "Auto migration is decision-only; no orders are submitted by this planner."

    receipt = {
      action: "hedge_venue_auto_migration_decision",
      position_id: position.id,
      current_venue: current,
      recommended_venue: recommended,
      reason: reason,
      would_migrate: blockers.empty?,
      blockers: blockers,
      warnings: warnings,
      daily_migration_count: daily_migration_count,
      cooldown_remaining_hours: cooldown,
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
    Result.new(receipt[:would_migrate], blockers, warnings, receipt)
  end

  private

  def allowed?(key, venue)
    values = @env[key].to_s.split(",").map { |value| HedgeVenues.normalize(value.strip) }.reject(&:blank?)
    values.empty? || values.include?(venue)
  end

  def daily_migration_count
    events.count { |event| event[:timestamp] && Time.zone.parse(event[:timestamp].to_s) >= @now.call.beginning_of_day }
  rescue ArgumentError
    0
  end

  def cooldown_remaining
    latest = events.filter_map { |event| Time.zone.parse(event[:timestamp].to_s) rescue nil }.max
    return 0 unless latest

    elapsed_hours = (@now.call - latest) / 1.hour
    [ min_cooldown_hours - elapsed_hours, 0 ].max
  end

  def events
    @events ||= @migration_events || read_receipt_events
  end

  def read_receipt_events
    Dir.glob(Rails.root.join("storage/hedge_migration_checks/*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map { |line| JSON.parse(line).symbolize_keys rescue nil }
    end
  rescue SystemCallError
    []
  end

  def max_per_day
    Integer(@env.fetch("MIGRATION_MAX_PER_DAY", "1"))
  rescue ArgumentError
    1
  end

  def min_cooldown_hours
    BigDecimal(@env.fetch("MIGRATION_MIN_COOLDOWN_HOURS", "12")).to_f
  rescue ArgumentError
    12
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def bool_env_default(key, default)
    return default unless @env.key?(key)

    ActiveModel::Type::Boolean.new.cast(@env[key])
  end
end
