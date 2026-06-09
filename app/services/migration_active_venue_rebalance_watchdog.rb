class MigrationActiveVenueRebalanceWatchdog
  LOG_DIR = Rails.root.join("storage/active_venue_rebalance_watchdog")

  Result = Data.define(:status, :checks, :blockers, :warnings, :receipt_path, :summary)

  def initialize(position:, live: false, interval_seconds: 300, duration_minutes: nil, once: true,
                 disable_after: false, rebalance_only_if_outside_tolerance: true, env: ENV,
                 active_rebalance_factory: nil, now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) },
                 log_dir: LOG_DIR, rebalance_readback_recheck_attempts: 4,
                 rebalance_readback_recheck_interval_seconds: 5)
    @position = position
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @interval_seconds = interval_seconds.to_i
    @duration_minutes = duration_minutes&.to_i
    @once = ActiveModel::Type::Boolean.new.cast(once)
    @disable_after = ActiveModel::Type::Boolean.new.cast(disable_after)
    @rebalance_only_if_outside_tolerance = ActiveModel::Type::Boolean.new.cast(rebalance_only_if_outside_tolerance)
    @env = env
    @active_rebalance_factory = active_rebalance_factory
    @rebalance_readback_recheck_attempts = rebalance_readback_recheck_attempts.to_i
    @rebalance_readback_recheck_interval_seconds = rebalance_readback_recheck_interval_seconds.to_i
    @now = now
    @sleeper = sleeper
    @log_dir = Pathname(log_dir)
    @started_at = @now.call
    @receipt_path = @log_dir.join("#{@started_at.utc.strftime('%Y%m%d_%H%M%S')}_position_#{position.id}.jsonl")
  end

  def run
    prepare_log!
    checks = []
    blockers = []
    loop do
      check = active_rebalancer.run(reason: "watchdog")
      event = check.merge(event: "active_venue_rebalance_watchdog_check", position_id: position.id)
      write_event(event)
      checks << check
      blockers = Array(check[:blockers])
      break if blockers.any? || once || deadline_reached?

      sleeper.call(interval_seconds) if interval_seconds.positive?
    end
    disable_after_run if disable_after
    status = blockers.any? ? "blocked" : "success"
    summary = summary_payload(status: status, checks: checks, blockers: blockers)
    write_event(summary)
    Result.new(status, checks, blockers, [], receipt_path.to_s, summary)
  rescue => e
    disable_after_run if disable_after
    blockers = [ "#{e.class}: #{e.message}" ]
    summary = summary_payload(status: "failed", checks: [], blockers: blockers)
    write_event(summary) if receipt_path
    Result.new("failed", [], blockers, [], receipt_path.to_s, summary)
  end

  private

  attr_reader :position, :interval_seconds, :duration_minutes, :once, :disable_after,
    :rebalance_only_if_outside_tolerance, :env, :active_rebalance_factory, :now, :sleeper,
    :log_dir, :started_at, :receipt_path, :rebalance_readback_recheck_attempts,
    :rebalance_readback_recheck_interval_seconds

  def live?
    @live
  end

  def active_rebalancer
    return active_rebalance_factory.call(position: position) if active_rebalance_factory

    ActiveVenueOneShotRebalance.new(
      position: position,
      live: live?,
      env: env,
      only_if_outside_tolerance: rebalance_only_if_outside_tolerance,
      recheck_attempts: rebalance_readback_recheck_attempts,
      recheck_interval_seconds: rebalance_readback_recheck_interval_seconds,
      sleeper: sleeper,
      now: now
    )
  end

  def deadline_reached?
    return true if duration_minutes.nil? || duration_minutes <= 0

    now.call >= started_at + duration_minutes.minutes
  end

  def prepare_log!
    FileUtils.mkdir_p(log_dir)
    FileUtils.touch(receipt_path)
    FileUtils.cp(receipt_path, latest_path)
  end

  def write_event(event)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(event)) }
    FileUtils.cp(receipt_path, latest_path)
  end

  def latest_path
    log_dir.join("latest_position_#{position.id}.jsonl")
  end

  def summary_payload(status:, checks:, blockers:)
    {
      event: "active_venue_rebalance_watchdog_finished",
      status: status,
      position_id: position.id,
      checks_count: checks.size,
      blockers: blockers,
      orders_submitted: checks.sum { |check| check[:orders_submitted].to_i },
      orders_placed: checks.sum { |check| check[:orders_placed].to_i },
      signatures_created: checks.sum { |check| check[:signatures_created].to_i },
      live: live?,
      disable_after: disable_after,
      migration_live_enabled_final: OperationalSettings.enabled?("MIGRATION_LIVE_ENABLED"),
      migration_auto_enabled_final: OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED"),
      migration_random_rotation_live_enabled_final: OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    }
  end

  def disable_after_run
    return unless live?

    OperationalSettings.set!(key: "MIGRATION_LIVE_ENABLED", enabled: false, reason: "active venue rebalance watchdog disable_after")
    OperationalSettings.set!(key: "MIGRATION_AUTO_ENABLED", enabled: false, reason: "active venue rebalance watchdog disable_after")
    OperationalSettings.set!(key: "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED", enabled: false, reason: "active venue rebalance watchdog disable_after")
    ActiveVenueAutoPolicy.new(position: position).disable_all!(reason: "active venue rebalance watchdog disable_after")
    OperationalSettings.set!(key: "AERODROME_NADO_HEDGE_LIVE_ENABLED", enabled: false, reason: "active venue rebalance watchdog disable_after")
    OperationalSettings.set!(key: "AERODROME_NADO_LIVE_MIGRATION_ENABLED", enabled: false, reason: "active venue rebalance watchdog disable_after")
  end
end
