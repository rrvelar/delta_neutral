class AerodromeProductionCanaryRunner
  BANNER = "AERODROME PRODUCTION CANARY RUN"
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_SUPERVISED_LIVE_CANARY"
  MAX_DURATION_SECONDS = 21_600
  MIN_INTERVAL_SECONDS = 180
  MAX_SHORT_ETH = BigDecimal("0.02")
  MAX_SHORT_NOTIONAL_USD = BigDecimal("50")
  MIN_ORDER_NOTIONAL_USD = BigDecimal("10")
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(
    hyperliquid_service: nil,
    position_sync: ->(position_id) { PositionSyncJob.perform_now(position_id) },
    hedge_sync: ->(hedge_id) { HedgeSyncJob.perform_now(hedge_id) },
    emergency_close_factory: -> { AerodromeLiveEmergencyClose.new },
    readiness: nil,
    watchdog: nil,
    sleeper: ->(seconds) { sleep(seconds) },
    log_dir: Rails.root.join("storage", "aerodrome_production_canary"),
    lock_path: Rails.root.join("storage", "aerodrome_production_canary", "run.lock"),
    clock: -> { Time.current }
  )
    @hyperliquid_service = hyperliquid_service
    @position_sync = position_sync
    @hedge_sync = hedge_sync
    @emergency_close_factory = emergency_close_factory
    @readiness = readiness
    @watchdog = watchdog
    @sleeper = sleeper
    @log_dir = Pathname(log_dir)
    @lock_path = Pathname(lock_path)
    @clock = clock
    @iterations = []
    @errors = []
    @rebalances = []
    @stop_reason = nil
    @final_close = nil
    @final_position = nil
    @final_position_confirmed = false
    @manual_action_required = false
    @last_known_short = BigDecimal("0")
    @stop_requested = false
    @signal = nil
  end

  def report
    errors = gate_errors
    return blocked(errors) if errors.any?

    with_lock do
      before = read_eth_position
      return blocked([ "mainnet ETH position must be nil before canary start" ], final_position: before) if short_size(before).positive?

      initialize_log
      install_signal_handlers
      record_event(type: "start", timestamp: timestamp, gates: gates, hedge_id: hedge.id, position_id: position.id)
      run_loop
      finish
    ensure
      restore_signal_handlers
    end
  rescue AlreadyRunning
    blocked([ "another production canary runner is active" ])
  rescue => e
    @errors << "#{e.class}: #{e.message}"
    finish
  end

  private

  class AlreadyRunning < StandardError; end

  def with_lock
    FileUtils.mkdir_p(@lock_path.dirname)
    File.open(@lock_path, File::RDWR | File::CREAT, 0o644) do |file|
      raise AlreadyRunning unless file.flock(File::LOCK_EX | File::LOCK_NB)

      yield
    ensure
      file&.flock(File::LOCK_UN)
    end
  end

  def install_signal_handlers
    @previous_signal_handlers = {}
    %w[INT TERM].each do |signal|
      @previous_signal_handlers[signal] = Signal.trap(signal) do
        @signal = signal
        @stop_requested = true
      end
    end
  rescue ArgumentError
    @previous_signal_handlers = {}
  end

  def restore_signal_handlers
    return unless @previous_signal_handlers

    @previous_signal_handlers.each { |signal, handler| Signal.trap(signal, handler) }
  rescue ArgumentError
    nil
  end

  def run_loop
    max_iterations.times do |index|
      if @stop_requested
        stop_requested!("signal #{signal_name}")
        break
      end

      run_iteration(index + 1)
      break if @stop_reason

      @sleeper.call(interval_seconds) if index + 1 < max_iterations
    end
    @stop_reason ||= "duration complete"
  rescue Interrupt
    @signal = "INT"
    stop_requested!("signal INT")
  end

  def run_iteration(iteration_number)
    before_rebalance_id = ShortRebalance.maximum(:id) || 0
    before_snapshot_id = PnlSnapshot.maximum(:id)
    iteration_errors = []
    actual_position = nil
    new_rebalances = []
    new_snapshot = nil
    watchdog_report = nil

    begin
      @position_sync.call(position.id)
      position.reload
      unless position.active?
        @stop_reason = "position inactive or missing"
        return record_iteration(iteration_number, nil, [], nil, [ @stop_reason ])
      end

      @hedge_sync.call(hedge.id)
      actual_position = read_eth_position
      @last_known_short = short_size(actual_position)
      new_rebalances = hedge.short_rebalances.where("id > ?", before_rebalance_id).order(:id).to_a
      new_snapshot = PnlSnapshot.where("id > ?", before_snapshot_id || 0).order(:id).last if before_snapshot_id
      new_snapshot ||= PnlSnapshot.order(:id).last if before_snapshot_id.nil?
      watchdog_report = watchdog.report
    rescue => e
      iteration_errors << "#{e.class}: #{e.message}"
      @errors.concat(iteration_errors)
    end

    @rebalances.concat(new_rebalances)
    record_iteration(iteration_number, actual_position, new_rebalances, new_snapshot, iteration_errors, watchdog_report: watchdog_report)
    evaluate_stop_conditions(actual_position, new_rebalances, iteration_errors, watchdog_report)
  end

  def record_iteration(iteration_number, actual_position, new_rebalances, new_snapshot, iteration_errors, watchdog_report: nil)
    event = {
      type: "iteration",
      timestamp: timestamp,
      iteration: iteration_number,
      position: position_snapshot,
      target_short: target_short.to_s("F"),
      actual_eth_position: serialize_position(actual_position),
      new_short_rebalances: new_rebalances.map { |rebalance| serialize_rebalance(rebalance) },
      pnl_snapshot_id: new_snapshot&.id,
      watchdog_status: watchdog_report&.fetch(:status, nil),
      errors: iteration_errors
    }
    @iterations << event
    record_event(type: "heartbeat", timestamp: timestamp, iteration: iteration_number, actual_eth_position: serialize_position(actual_position))
    record_event(event)
  end

  def evaluate_stop_conditions(actual_position, new_rebalances, iteration_errors, watchdog_report)
    if iteration_errors.any?
      @stop_reason = "iteration error"
    elsif new_rebalances.any? { |rebalance| weth_rebalance?(rebalance) && rebalance.status == ShortRebalance::STATUS_FAILED }
      @stop_reason = "failed WETH rebalance"
    elsif new_rebalances.any? { |rebalance| rebalance.asset == "USDC" && rebalance.status == ShortRebalance::STATUS_SUCCESS }
      @stop_reason = "unexpected successful USDC rebalance"
    elsif short_size(actual_position) > max_short_eth
      @stop_reason = "actual ETH short exceeds max"
    elsif watchdog_report && watchdog_report.fetch(:status) == "BLOCKED"
      @stop_reason = "watchdog BLOCKED"
    end
    record_event(type: "stop_condition", timestamp: timestamp, reason: @stop_reason) if @stop_reason
  end

  def stop_requested!(reason)
    @stop_reason = reason
    record_event(type: "signal", timestamp: timestamp, signal: @signal)
    true
  end

  def finish
    record_event(type: "final_close_start", timestamp: timestamp) if @log_path
    before_close, before_close_error = safe_eth_position_read("final pre-close")
    @last_known_short = short_size(before_close) if before_close
    should_close = @last_known_short.positive? || short_size(before_close).positive? || before_close_error.present?
    @final_close = should_close ? safe_run_final_close : { status: "noop", errors: [] }
    record_event(type: "final_close_done", timestamp: timestamp, final_close: @final_close) if @log_path
    @final_position = final_readback
    @manual_action_required = !@final_position_confirmed || short_size(@final_position).positive? || @final_close[:status].to_s == "failed"

    status = final_status
    record_event(
      type: "finish",
      timestamp: timestamp,
      status: status,
      stop_reason: @stop_reason,
      final_close: @final_close,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      manual_action_required: @manual_action_required,
      errors: @errors
    )
    base_report(status)
  end

  def safe_run_final_close
    previous_paused = ENV["AERODROME_HEDGE_PAUSED"]
    ENV["AERODROME_HEDGE_PAUSED"] = "true"
    @emergency_close_factory.call.report.deep_symbolize_keys
  rescue => e
    error = "final emergency close failed: #{e.class}: #{e.message}"
    @errors << error
    { status: "failed", errors: [ error ], attempts: [] }
  ensure
    previous_paused.nil? ? ENV.delete("AERODROME_HEDGE_PAUSED") : ENV["AERODROME_HEDGE_PAUSED"] = previous_paused
  end

  def safe_eth_position_read(context)
    position = read_eth_position
    [ position, nil ]
  rescue => e
    error = "#{context} ETH readback failed: #{e.class}: #{e.message}"
    @errors << error
    [ nil, error ]
  end

  def final_readback
    final_readback_attempts.times do |index|
      begin
        position = read_eth_position
        @final_position_confirmed = true
        return position
      rescue => e
        @errors << "final ETH readback attempt #{index + 1} failed: #{e.class}: #{e.message}"
        @sleeper.call(final_readback_sleep_seconds) if index + 1 < final_readback_attempts
      end
    end
    nil
  end

  def final_status
    return "close_unknown" unless @final_position_confirmed
    return "failed" if short_size(@final_position).positive?
    return "failed" if @final_close && @final_close[:status].to_s == "failed"
    return "failed" if @stop_reason.present? && @stop_reason != "duration complete"
    return "failed" if @errors.any?

    "success"
  end

  def gate_errors
    errors = []
    errors << "HYPERLIQUID_TESTNET must be false" unless boolean_env("HYPERLIQUID_TESTNET") == false
    errors << "AERODROME_LIVE_APPROVED must be true" unless boolean_env("AERODROME_LIVE_APPROVED") == true
    errors << "AERODROME_HEDGE_ENABLED must be true" unless boolean_env("AERODROME_HEDGE_ENABLED") == true
    errors << "AERODROME_HEDGE_PAUSED must be false" unless boolean_env("AERODROME_HEDGE_PAUSED") == false
    errors << "AERODROME_PRODUCTION_CANARY_ENABLED must be true" unless boolean_env("AERODROME_PRODUCTION_CANARY_ENABLED") == true
    errors << "AERODROME_PRODUCTION_CANARY_CONFIRM must equal #{CONFIRMATION}" unless ENV["AERODROME_PRODUCTION_CANARY_CONFIRM"].to_s == CONFIRMATION
    errors << "AERODROME_PRODUCTION_CANARY_DURATION_SECONDS must be configured" unless duration_seconds
    errors << "AERODROME_PRODUCTION_CANARY_INTERVAL_SECONDS must be configured" unless interval_seconds
    errors << "duration must be <= #{MAX_DURATION_SECONDS} seconds" if duration_seconds && duration_seconds > MAX_DURATION_SECONDS
    errors << "interval must be >= #{MIN_INTERVAL_SECONDS} seconds" if interval_seconds && interval_seconds < MIN_INTERVAL_SECONDS
    errors << "AERODROME_PRODUCTION_CANARY_CLOSE_ON_FINISH must be true" unless boolean_env("AERODROME_PRODUCTION_CANARY_CLOSE_ON_FINISH") == true
    errors << "AERODROME_MAX_LEVERAGE must be 1" unless max_leverage == BigDecimal("1")
    errors << "AERODROME_MAX_SHORT_ETH must be configured and <= #{MAX_SHORT_ETH.to_s('F')}" unless max_short_eth && max_short_eth <= MAX_SHORT_ETH
    errors << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= #{MAX_SHORT_NOTIONAL_USD.to_s('F')}" unless max_short_notional_usd && max_short_notional_usd <= MAX_SHORT_NOTIONAL_USD
    errors << "AERODROME_MIN_ORDER_NOTIONAL_USD must be configured and >= #{MIN_ORDER_NOTIONAL_USD.to_s('F')}" unless min_order_notional_usd && min_order_notional_usd >= MIN_ORDER_NOTIONAL_USD
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true" unless boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED") == true
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{AerodromeLiveEmergencyClose::CONFIRMATION}" unless ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH" unless emergency_close_max_eth && max_short_eth && emergency_close_max_eth >= max_short_eth
    errors << "No Aerodrome hedge/position found" unless hedge
    errors.concat(history_gate_errors) if hedge
    errors.concat(readiness_gate_errors)
    errors
  end

  def history_gate_errors
    rebalances = hedge.short_rebalances.order(rebalanced_at: :desc, id: :desc).to_a
    failed_weth = rebalances.select { |rebalance| weth_rebalance?(rebalance) && rebalance.status == ShortRebalance::STATUS_FAILED }
    close = rebalances.find { |r| weth_rebalance?(r) && r.status == ShortRebalance::STATUS_SUCCESS && decimal(r.old_short_size).positive? && decimal(r.new_short_size).zero? }
    failed_after_close = close ? failed_weth.select { |r| r.rebalanced_at && r.rebalanced_at > close.rebalanced_at } : failed_weth
    errors = []
    errors << "unacknowledged failed WETH rebalance exists" if failed_after_close.reject { |r| acknowledged_zero_size_failure?(r) }.any?
    errors << "successful USDC rebalance exists" if rebalances.any? { |r| r.asset == "USDC" && r.status == ShortRebalance::STATUS_SUCCESS }
    errors
  end

  def readiness_gate_errors
    blockers = readiness.report.fetch(:blockers, [])
    filtered = blockers.reject { |message| expected_canary_readiness_blocker?(message) }
    filtered.map { |message| "production supervised readiness blocker: #{message}" }
  rescue => e
    [ "production supervised readiness failed: #{e.class}: #{e.message}" ]
  end

  def expected_canary_readiness_blocker?(message)
    [
      "AERODROME_HEDGE_ENABLED is false",
      "AERODROME_HEDGE_PAUSED is true",
      "AERODROME_LIVE_APPROVED is false",
      "HYPERLIQUID_TESTNET is true"
    ].any? { |expected| message.to_s.include?(expected) }
  end

  def blocked(errors, final_position: nil)
    @errors.concat(errors)
    @final_position = final_position
    base_report("blocked")
  end

  def base_report(status)
    live_capable = status != "blocked"
    {
      safety_banner: BANNER,
      status: status,
      live_order_capable: true,
      log_path: @log_path&.to_s,
      gates: gates,
      iterations: @iterations.size,
      iteration_events: @iterations,
      rebalances_count: @rebalances.size,
      stop_reason: @stop_reason,
      final_close: @final_close,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      manual_action_required: @manual_action_required,
      errors: @errors,
      database_write: live_capable,
      orders_enabled: live_capable,
      hyperliquid_execution: live_capable
    }
  end

  def initialize_log
    FileUtils.mkdir_p(@log_dir)
    @log_path = @log_dir.join("#{timestamp_for_path}-#{SecureRandom.hex(4)}.jsonl")
  end

  def record_event(event)
    return unless @log_path

    File.open(@log_path, "a") { |file| file.puts(JSON.generate(event)) }
  end

  def position_snapshot
    {
      id: position.id,
      asset0: position.asset0,
      asset1: position.asset1,
      asset0_amount: position.asset0_amount&.to_s("F"),
      asset1_amount: position.asset1_amount&.to_s("F"),
      asset0_price_usd: position.asset0_price_usd&.to_s("F"),
      asset1_price_usd: position.asset1_price_usd&.to_s("F")
    }
  end

  def serialize_rebalance(rebalance)
    {
      id: rebalance.id,
      asset: rebalance.asset,
      old_short_size: rebalance.old_short_size&.to_s("F"),
      new_short_size: rebalance.new_short_size&.to_s("F"),
      status: rebalance.status,
      message: rebalance.message,
      rebalanced_at: rebalance.rebalanced_at&.iso8601
    }
  end

  def serialize_position(position)
    return nil unless position

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end

  def gates
    {
      hyperliquid_testnet: ENV["HYPERLIQUID_TESTNET"],
      live_approved: boolean_env("AERODROME_LIVE_APPROVED"),
      hedge_enabled: boolean_env("AERODROME_HEDGE_ENABLED"),
      hedge_paused: boolean_env("AERODROME_HEDGE_PAUSED"),
      canary_enabled: boolean_env("AERODROME_PRODUCTION_CANARY_ENABLED"),
      confirmation_valid: ENV["AERODROME_PRODUCTION_CANARY_CONFIRM"].to_s == CONFIRMATION,
      duration_seconds: duration_seconds,
      interval_seconds: interval_seconds,
      close_on_finish: boolean_env("AERODROME_PRODUCTION_CANARY_CLOSE_ON_FINISH"),
      max_leverage: max_leverage&.to_s("F"),
      max_short_eth: max_short_eth&.to_s("F"),
      max_short_notional_usd: max_short_notional_usd&.to_s("F"),
      min_order_notional_usd: min_order_notional_usd&.to_s("F"),
      emergency_close_enabled: boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED"),
      emergency_close_confirmation_valid: ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION,
      emergency_close_max_eth: emergency_close_max_eth&.to_s("F")
    }
  end

  def hedge
    @hedge ||= Hedge.joins(position: :dex).includes(:short_rebalances, position: :dex).find_by(positions: { dexes: { name: "aerodrome_slipstream" } })
  end

  def position
    hedge.position
  end

  def target_short
    asset = [ [ position.asset0, position.asset0_amount ], [ position.asset1, position.asset1_amount ] ].find { |symbol, _| HEDGEABLE_SYMBOLS.include?(symbol.to_s.upcase) }
    ((asset&.last || 0) * hedge.target)
  end

  def read_eth_position
    hyperliquid.get_position("ETH")
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def readiness
    @readiness ||= AerodromeProductionSupervisedReadiness.new
  end

  def watchdog
    @watchdog ||= AerodromeWatchdogCheck.new(mainnet_hyperliquid_service: hyperliquid)
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def acknowledged_zero_size_failure?(rebalance)
    rebalance.status == ShortRebalance::STATUS_FAILED &&
      decimal(rebalance.old_short_size).zero? &&
      decimal(rebalance.new_short_size).zero? &&
      rebalance.message.to_s.include?(AerodromeFailedRebalanceAcknowledgment::MARKER)
  end

  def weth_rebalance?(rebalance)
    HEDGEABLE_SYMBOLS.include?(rebalance.asset.to_s.upcase)
  end

  def max_iterations
    [ (duration_seconds.to_f / interval_seconds).ceil, 1 ].max
  end

  def duration_seconds
    integer_env("AERODROME_PRODUCTION_CANARY_DURATION_SECONDS")
  end

  def interval_seconds
    integer_env("AERODROME_PRODUCTION_CANARY_INTERVAL_SECONDS")
  end

  def final_readback_attempts
    integer_env("AERODROME_LIVE_OBSERVATION_FINAL_READBACK_ATTEMPTS") || 5
  end

  def final_readback_sleep_seconds
    integer_env("AERODROME_LIVE_OBSERVATION_FINAL_READBACK_SLEEP_SECONDS") || 10
  end

  def max_leverage
    decimal_env("AERODROME_MAX_LEVERAGE")
  end

  def max_short_eth
    decimal_env("AERODROME_MAX_SHORT_ETH")
  end

  def max_short_notional_usd
    decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
  end

  def min_order_notional_usd
    decimal_env("AERODROME_MIN_ORDER_NOTIONAL_USD")
  end

  def emergency_close_max_eth
    decimal_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
  end

  def boolean_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def integer_env(key)
    raw = ENV[key].presence
    return nil unless raw

    Integer(raw)
  rescue ArgumentError
    nil
  end

  def decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def decimal(value)
    BigDecimal((value || 0).to_s)
  end

  def timestamp
    @clock.call.iso8601
  end

  def timestamp_for_path
    @clock.call.utc.strftime("%Y%m%d%H%M%S")
  end

  def signal_name
    @signal || "unknown"
  end
end
