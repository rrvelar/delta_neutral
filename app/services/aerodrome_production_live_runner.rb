class AerodromeProductionLiveRunner
  BANNER = "AERODROME PRODUCTION LIVE RUN"
  CONFIRMATION = AerodromeProductionLiveRuntimeSafetyCheck::CONFIRMATION
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
    sleeper: ->(seconds) { sleep(seconds) },
    log_dir: Rails.root.join("storage", "aerodrome_production_live"),
    lock_path: Rails.root.join("storage", "aerodrome_production_live", "run.lock"),
    clock: -> { Time.current }
  )
    @hyperliquid_service = hyperliquid_service
    @position_sync = position_sync
    @hedge_sync = hedge_sync
    @emergency_close_factory = emergency_close_factory
    @readiness = readiness
    @sleeper = sleeper
    @log_dir = Pathname(log_dir)
    @lock_path = Pathname(lock_path)
    @clock = clock
    @iterations = []
    @errors = []
    @rebalances = []
    @stop_reason = nil
    @close_result = nil
    @final_position = nil
    @final_position_confirmed = false
    @position_left_open = false
    @manual_action_required = false
    @last_known_short = BigDecimal("0")
    @stop_requested = false
    @signal = nil
    @run_start_rebalance_id = nil
  end

  def report
    errors = gate_errors
    return blocked(errors) if errors.any?

    with_lock do
      before = read_eth_position
      if short_size(before).positive? && !adopt_existing_eth_short?
        return blocked([ "mainnet ETH position must be nil before live run start unless adopt existing is true" ], final_position: before)
      end
      if short_size(before).positive? && !position_within_caps?(before)
        return blocked([ "existing mainnet ETH position exceeds caps" ], final_position: before)
      end

      initialize_log
      @last_known_short = short_size(before)
      @run_start_rebalance_id = ShortRebalance.maximum(:id) || 0
      install_signal_handlers
      record_event(type: "start", timestamp: timestamp, gates: gates, hedge_id: hedge.id, position_id: position.id, adopted_position: serialize_position(before))
      run_loop
      finish
    ensure
      restore_signal_handlers
    end
  rescue AlreadyRunning
    blocked([ "another production live runner is active" ])
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
    runtime_safety = nil

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
      runtime_safety = runtime_safety_report(actual_position)
    rescue => e
      iteration_errors << "#{e.class}: #{e.message}"
      @errors.concat(iteration_errors)
    end

    @rebalances.concat(new_rebalances)
    record_iteration(iteration_number, actual_position, new_rebalances, new_snapshot, iteration_errors, runtime_safety: runtime_safety)
    evaluate_stop_conditions(actual_position, new_rebalances, iteration_errors, runtime_safety)
  end

  def record_iteration(iteration_number, actual_position, new_rebalances, new_snapshot, iteration_errors, runtime_safety: nil)
    event = {
      type: "iteration",
      timestamp: timestamp,
      iteration: iteration_number,
      position: position_snapshot,
      target_short: target_short.to_s("F"),
      actual_eth_position: serialize_position(actual_position),
      new_short_rebalances: new_rebalances.map { |rebalance| serialize_rebalance(rebalance) },
      pnl_snapshot_id: new_snapshot&.id,
      runtime_safety_status: runtime_safety&.fetch(:status, nil),
      runtime_safety_blockers: runtime_safety&.fetch(:blockers, []),
      runtime_safety_warnings: runtime_safety&.fetch(:warnings, []),
      errors: iteration_errors
    }
    @iterations << event
    record_event(type: "heartbeat", timestamp: timestamp, iteration: iteration_number, actual_eth_position: serialize_position(actual_position))
    new_rebalances.each { |rebalance| record_event(type: "rebalance", timestamp: timestamp, rebalance: serialize_rebalance(rebalance)) }
    record_event(event)
  end

  def evaluate_stop_conditions(actual_position, new_rebalances, iteration_errors, runtime_safety)
    if iteration_errors.any?
      @stop_reason = "iteration error"
    elsif new_rebalances.any? { |rebalance| weth_rebalance?(rebalance) && rebalance.status == ShortRebalance::STATUS_FAILED }
      @stop_reason = "failed WETH rebalance"
    elsif new_rebalances.any? { |rebalance| rebalance.asset == "USDC" && rebalance.status == ShortRebalance::STATUS_SUCCESS }
      @stop_reason = "unexpected successful USDC rebalance"
    elsif short_size(actual_position) > max_short_eth
      @stop_reason = "actual ETH short exceeds max"
    elsif eth_notional(actual_position) > max_short_notional_usd
      @stop_reason = "actual ETH notional exceeds max"
    elsif runtime_safety && runtime_safety.fetch(:status) == "BLOCKED"
      @stop_reason = "runtime safety BLOCKED: #{runtime_safety.fetch(:blockers).join('; ')}"
    end
    record_event(type: "stop_condition", timestamp: timestamp, reason: @stop_reason) if @stop_reason
  end

  def runtime_safety_report(actual_position)
    AerodromeProductionLiveRuntimeSafetyCheck.new(
      hedge: hedge,
      eth_position: actual_position,
      since_rebalance_id: @run_start_rebalance_id
    ).report
  end

  def stop_requested!(reason)
    @stop_reason = reason
    record_event(type: "signal", timestamp: timestamp, signal: @signal)
    true
  end

  def finish
    if clean_duration_completion?
      @close_result = { status: "not_run_leave_position_open", errors: [] }
    elsif close_for_stop_reason?
      record_event(type: "close_on_error_start", timestamp: timestamp) if @log_path
      @close_result = safe_run_final_close
      record_event(type: "close_on_error_done", timestamp: timestamp, close_result: @close_result) if @log_path
    else
      @close_result = { status: "not_run", errors: [ "close disabled for stop reason" ] }
    end

    @final_position = final_readback
    @position_left_open = clean_duration_completion? && @final_position_confirmed && final_position_allowed_open?
    @manual_action_required = manual_action_required?

    status = final_status
    record_event(
      type: "finish",
      timestamp: timestamp,
      status: status,
      stop_reason: @stop_reason,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      position_left_open: @position_left_open,
      close_result: @close_result,
      manual_action_required: @manual_action_required,
      errors: @errors
    )
    base_report(status)
  end

  def clean_duration_completion?
    @stop_reason == "duration complete" && boolean_env("AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN") == true
  end

  def close_for_stop_reason?
    signal_stop? ? boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL") == true : boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR") == true
  end

  def signal_stop?
    @stop_reason.to_s.start_with?("signal")
  end

  def final_position_allowed_open?
    size = short_size(@final_position)
    return true if size.zero? && target_short.zero?

    size.positive? && position_within_caps?(@final_position)
  end

  def manual_action_required?
    return true unless @final_position_confirmed
    return true if clean_duration_completion? && !final_position_allowed_open?
    return true if !clean_duration_completion? && short_size(@final_position).positive?
    return true if @close_result && @close_result[:status].to_s == "failed"

    false
  end

  def final_status
    return "close_unknown" unless @final_position_confirmed
    return "success" if clean_duration_completion? && final_position_allowed_open?
    return "success" if !clean_duration_completion? && short_size(@final_position).zero? && @close_result&.fetch(:status, nil).to_s == "success"

    "failed"
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

  def final_readback
    final_readback_attempts.times do |index|
      begin
        position = read_eth_position
        @final_position_confirmed = true
        record_event(type: "final_readback", timestamp: timestamp, attempt: index + 1, position: serialize_position(position)) if @log_path
        return position
      rescue => e
        error = "final ETH readback attempt #{index + 1} failed: #{e.class}: #{e.message}"
        @errors << error
        record_event(type: "final_readback", timestamp: timestamp, attempt: index + 1, error: error) if @log_path
        @sleeper.call(final_readback_sleep_seconds) if index + 1 < final_readback_attempts
      end
    end
    nil
  end

  def gate_errors
    errors = []
    errors << "HYPERLIQUID_TESTNET must be false" unless boolean_env("HYPERLIQUID_TESTNET") == false
    errors << "AERODROME_LIVE_APPROVED must be true" unless boolean_env("AERODROME_LIVE_APPROVED") == true
    errors << "AERODROME_HEDGE_ENABLED must be true" unless boolean_env("AERODROME_HEDGE_ENABLED") == true
    errors << "AERODROME_HEDGE_PAUSED must be false" unless boolean_env("AERODROME_HEDGE_PAUSED") == false
    errors << "AERODROME_PRODUCTION_LIVE_ENABLED must be true" unless boolean_env("AERODROME_PRODUCTION_LIVE_ENABLED") == true
    errors << "AERODROME_PRODUCTION_LIVE_CONFIRM must equal #{CONFIRMATION}" unless ENV["AERODROME_PRODUCTION_LIVE_CONFIRM"].to_s == CONFIRMATION
    errors << "AERODROME_PRODUCTION_LIVE_DURATION_SECONDS must be configured" unless duration_seconds
    errors << "AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS must be configured" unless interval_seconds
    errors << "duration must be <= #{MAX_DURATION_SECONDS} seconds" if duration_seconds && duration_seconds > MAX_DURATION_SECONDS
    errors << "interval must be >= #{MIN_INTERVAL_SECONDS} seconds" if interval_seconds && interval_seconds < MIN_INTERVAL_SECONDS
    errors << "AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN must be true" unless boolean_env("AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN") == true
    errors << "AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR must be true" unless boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR") == true
    errors << "AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL must be true" unless boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL") == true
    errors << "AERODROME_MAX_LEVERAGE must be 1" unless max_leverage == BigDecimal("1")
    errors << "AERODROME_MAX_SHORT_ETH must be configured and <= #{MAX_SHORT_ETH.to_s('F')}" unless max_short_eth && max_short_eth <= MAX_SHORT_ETH
    errors << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= #{MAX_SHORT_NOTIONAL_USD.to_s('F')}" unless max_short_notional_usd && max_short_notional_usd <= MAX_SHORT_NOTIONAL_USD
    errors << "AERODROME_MIN_ORDER_NOTIONAL_USD must be configured and >= #{MIN_ORDER_NOTIONAL_USD.to_s('F')}" unless min_order_notional_usd && min_order_notional_usd >= MIN_ORDER_NOTIONAL_USD
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true" unless boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED") == true
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{AerodromeLiveEmergencyClose::CONFIRMATION}" unless ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH" unless emergency_close_max_eth && max_short_eth && emergency_close_max_eth >= max_short_eth
    errors << "No Aerodrome hedge/position found" unless hedge
    errors.concat(history_gate_errors) if hedge
    errors.concat(previous_log_gate_errors)
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

  def previous_log_gate_errors
    final = latest_final_event
    return [] unless final

    errors = []
    errors << "previous production live/canary log has manual_action_required=true" if final.fetch("manual_action_required", nil) == true
    errors << "previous production live/canary log final_position is not nil" if final.fetch("final_position", nil).present?
    errors
  rescue JSON::ParserError, Errno::ENOENT
    []
  end

  def latest_final_event
    paths = [ @log_dir, Rails.root.join("storage", "aerodrome_production_canary") ].flat_map { |dir| Dir.glob(Pathname(dir).join("*.jsonl")) }
    path = paths.max_by { |candidate| File.mtime(candidate) }
    return nil unless path

    File.readlines(path).filter_map do |line|
      event = JSON.parse(line)
      event if %w[finish final].include?(event["type"])
    end.last
  end

  def readiness_gate_errors
    blockers = readiness.report.fetch(:blockers, [])
    filtered = blockers.reject { |message| expected_live_readiness_blocker?(message) }
    filtered.map { |message| "production supervised readiness blocker: #{message}" }
  rescue => e
    [ "production supervised readiness failed: #{e.class}: #{e.message}" ]
  end

  def expected_live_readiness_blocker?(message)
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
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      position_left_open: @position_left_open,
      close_result: @close_result,
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
      production_live_enabled: boolean_env("AERODROME_PRODUCTION_LIVE_ENABLED"),
      confirmation_valid: ENV["AERODROME_PRODUCTION_LIVE_CONFIRM"].to_s == CONFIRMATION,
      duration_seconds: duration_seconds,
      interval_seconds: interval_seconds,
      leave_position_open: boolean_env("AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN"),
      close_on_error: boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR"),
      close_on_signal: boolean_env("AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL"),
      adopt_existing_eth_short: adopt_existing_eth_short?,
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

  def position_within_caps?(eth_position)
    short_size(eth_position) <= max_short_eth && eth_notional(eth_position) <= max_short_notional_usd
  end

  def eth_notional(eth_position)
    short_size(eth_position) * (eth_price || BigDecimal("0"))
  end

  def eth_price
    if HEDGEABLE_SYMBOLS.include?(position.asset0.to_s.upcase)
      position.asset0_price_usd || BigDecimal("0")
    elsif HEDGEABLE_SYMBOLS.include?(position.asset1.to_s.upcase)
      position.asset1_price_usd || BigDecimal("0")
    else
      BigDecimal("0")
    end
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
    integer_env("AERODROME_PRODUCTION_LIVE_DURATION_SECONDS")
  end

  def interval_seconds
    integer_env("AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS")
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

  def adopt_existing_eth_short?
    boolean_env("AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT") == true
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
