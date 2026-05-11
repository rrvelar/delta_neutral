class AerodromeProductionTargetStepTest
  BANNER = "AERODROME TARGET STEP TEST"
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_LIVE_TARGET_STEP_REBALANCE_TEST"
  MAX_TARGET = BigDecimal("0.02")
  MAX_SHORT_ETH = BigDecimal("0.02")
  MAX_SHORT_NOTIONAL_USD = BigDecimal("50")
  MIN_ORDER_NOTIONAL_USD = BigDecimal("10")
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(
    hyperliquid_service: nil,
    position_sync: ->(position_id) { PositionSyncJob.perform_now(position_id) },
    hedge_sync: ->(hedge_id) { HedgeSyncJob.perform_now(hedge_id) },
    volatility_guard: nil,
    emergency_close_factory: -> { AerodromeLiveEmergencyClose.new },
    sleeper: ->(seconds) { sleep(seconds) },
    log_dir: Rails.root.join("storage", "aerodrome_target_step_test"),
    clock: -> { Time.current }
  )
    @hyperliquid_service = hyperliquid_service
    @position_sync = position_sync
    @hedge_sync = hedge_sync
    @volatility_guard = volatility_guard
    @emergency_close_factory = emergency_close_factory
    @sleeper = sleeper
    @log_dir = Pathname(log_dir)
    @clock = clock
    @errors = []
    @warnings = []
    @guard_results = []
    @rebalance_rows = []
    @target_restored = false
    @final_position = nil
    @final_position_confirmed = false
    @manual_action_required = false
    @close_result = nil
    @original_target = nil
  end

  def report
    errors = gate_errors
    return blocked(errors) if errors.any?

    before = read_eth_position
    return blocked([ "mainnet ETH position must be nil before target-step start" ], final_position: before) if short_size(before).positive?

    @original_target = hedge.target
    return blocked([ "original hedge target missing" ]) unless @original_target

    cap_errors = target_cap_errors
    return blocked(cap_errors) if cap_errors.any?

    initialize_log
    record_event(type: "start", timestamp: timestamp, original_target: decimal_string(@original_target), up_target: decimal_string(up_target), down_target: decimal_string(down_target), gates: gates)
    begin
      run_steps
    rescue => e
      @errors << "#{e.class}: #{e.message}"
    ensure
      restore_target
      final_close
    end

    @final_report
  end

  private

  def run_steps
    run_step("up", up_target)
    @sleeper.call(step_sleep_seconds)
    run_step("down", down_target)
  end

  def run_step(name, target)
    before_id = ShortRebalance.maximum(:id) || 0
    hedge.update!(target: target)
    record_event(type: "target_changed", timestamp: timestamp, step: name, target: decimal_string(target))

    @position_sync.call(position.id)
    position.reload
    current = read_eth_position
    guard = guard_report(current)
    @guard_results << guard.merge(step: name)
    record_event(type: "guard_check", timestamp: timestamp, step: name, guard: guard)

    if guard.fetch(:allowed)
      record_event(type: "rebalance_attempt", timestamp: timestamp, step: name)
      @hedge_sync.call(hedge.id)
    else
      record_event(type: "rebalance_attempt", timestamp: timestamp, step: name, skipped_by_volatility_guard: true, reason: guard.fetch(:reason))
    end

    rows = hedge.short_rebalances.where("id > ?", before_id).order(:id).to_a
    @rebalance_rows.concat(rows)
    volatility_guard.record_rebalance!(at: @clock.call) if rows.any? { |row| weth_rebalance?(row) && row.status == ShortRebalance::STATUS_SUCCESS }
    record_event(type: "rebalance_result", timestamp: timestamp, step: name, rows: rows.map { |row| serialize_rebalance(row) })
  rescue => e
    @errors << "#{name} step failed: #{e.class}: #{e.message}"
  end

  def restore_target
    return if @target_restored

    if boolean_env("AERODROME_TARGET_STEP_TEST_RESTORE_TARGET") == true
      hedge.update!(target: @original_target)
      @target_restored = true
      record_event(type: "target_restored", timestamp: timestamp, target: decimal_string(@original_target))
    end
  rescue => e
    @errors << "target restore failed: #{e.class}: #{e.message}"
  end

  def final_close
    return @final_report if defined?(@final_report)

    if boolean_env("AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH") == true
      record_event(type: "final_close_start", timestamp: timestamp) if @log_path
      @close_result = safe_run_final_close
      record_event(type: "final_close_done", timestamp: timestamp, close_result: @close_result) if @log_path
    end
    @final_position = final_readback
    @manual_action_required = manual_action_required?
    status = final_status
    record_event(type: "finish", timestamp: timestamp, status: status, target_restored: @target_restored, final_position: serialize_position(@final_position), final_position_confirmed: @final_position_confirmed, manual_action_required: @manual_action_required, errors: @errors)
    @final_report = base_report(status)
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
    readback_attempts.times do |index|
      begin
        position = read_eth_position
        @final_position_confirmed = true
        return position
      rescue => e
        @errors << "final ETH readback attempt #{index + 1} failed: #{e.class}: #{e.message}"
        @sleeper.call(readback_sleep_seconds) if index + 1 < readback_attempts
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
    errors << "AERODROME_TARGET_STEP_TEST_ENABLED must be true" unless boolean_env("AERODROME_TARGET_STEP_TEST_ENABLED") == true
    errors << "AERODROME_TARGET_STEP_TEST_CONFIRM must equal #{CONFIRMATION}" unless ENV["AERODROME_TARGET_STEP_TEST_CONFIRM"].to_s == CONFIRMATION
    errors << "AERODROME_TARGET_STEP_TEST_UP_TARGET must be configured" unless up_target
    errors << "AERODROME_TARGET_STEP_TEST_DOWN_TARGET must be configured" unless down_target
    errors << "AERODROME_TARGET_STEP_TEST_RESTORE_TARGET must be true" unless boolean_env("AERODROME_TARGET_STEP_TEST_RESTORE_TARGET") == true
    errors << "AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH must be true" unless boolean_env("AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH") == true
    errors << "AERODROME_MAX_LEVERAGE must be 1" unless max_leverage == BigDecimal("1")
    errors << "AERODROME_MAX_SHORT_ETH must be configured and <= #{MAX_SHORT_ETH.to_s('F')}" unless max_short_eth && max_short_eth <= MAX_SHORT_ETH
    errors << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= #{MAX_SHORT_NOTIONAL_USD.to_s('F')}" unless max_short_notional_usd && max_short_notional_usd <= MAX_SHORT_NOTIONAL_USD
    errors << "AERODROME_MIN_ORDER_NOTIONAL_USD must be configured and >= #{MIN_ORDER_NOTIONAL_USD.to_s('F')}" unless min_order_notional_usd && min_order_notional_usd >= MIN_ORDER_NOTIONAL_USD
    errors << "AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED must be true" unless boolean_env("AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED") == true
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true" unless boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED") == true
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{AerodromeLiveEmergencyClose::CONFIRMATION}" unless ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH" unless emergency_close_max_eth && max_short_eth && emergency_close_max_eth >= max_short_eth
    errors << "No Aerodrome hedge/position found" unless hedge
    [ up_target, down_target ].compact.each do |target|
      errors << "target step targets must be > 0 and <= #{MAX_TARGET.to_s('F')}" unless target.positive? && target <= MAX_TARGET
    end
    errors
  end

  def target_cap_errors
    [ up_target, down_target ].filter_map do |target|
      target_short = weth_amount * target
      notional = target_short * eth_price
      if target_short > max_short_eth
        "target #{decimal_string(target)} implies ETH short #{target_short.to_s('F')} above max"
      elsif notional > max_short_notional_usd
        "target #{decimal_string(target)} implies notional #{notional.to_s('F')} above max"
      end
    end
  end

  def guard_report(current)
    volatility_guard.report(
      lp_price_usd: eth_price,
      mark_price_usd: current&.fetch(:mark_price, nil),
      target_short: weth_amount * hedge.target,
      current_short: short_size(current)
    )
  end

  def manual_action_required?
    return true unless @target_restored
    return true unless @final_position_confirmed
    return true if short_size(@final_position).positive?
    return true if @close_result && @close_result[:status].to_s == "failed"

    false
  end

  def final_status
    return "blocked" if @errors.any? && @log_path.nil?
    return "close_unknown" unless @final_position_confirmed
    return "failed" if @manual_action_required
    return "warn" if @guard_results.any? { |guard| guard.fetch(:allowed) == false }

    "success"
  end

  def blocked(errors, final_position: nil)
    @errors.concat(errors)
    @final_position = final_position
    base_report("blocked")
  end

  def base_report(status)
    {
      safety_banner: BANNER,
      status: status,
      live_order_capable: true,
      log_path: @log_path&.to_s,
      original_target: decimal_string(@original_target),
      up_target: decimal_string(up_target),
      down_target: decimal_string(down_target),
      rebalance_rows: @rebalance_rows.map { |row| serialize_rebalance(row) },
      guard_results: @guard_results,
      target_restored: @target_restored,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      manual_action_required: @manual_action_required,
      close_result: @close_result,
      errors: @errors,
      database_write: status != "blocked",
      orders_enabled: status != "blocked",
      hyperliquid_execution: status != "blocked"
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

  def read_eth_position
    hyperliquid.get_position("ETH")
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def volatility_guard
    @volatility_guard ||= AerodromeRebalanceVolatilityGuard.new(clock: @clock)
  end

  def hedge
    @hedge ||= Hedge.joins(position: :dex).includes(:short_rebalances, position: :dex).find_by(positions: { dexes: { name: "aerodrome_slipstream" } })
  end

  def position
    hedge.position
  end

  def weth_amount
    if HEDGEABLE_SYMBOLS.include?(position.asset0.to_s.upcase)
      position.asset0_amount || BigDecimal("0")
    elsif HEDGEABLE_SYMBOLS.include?(position.asset1.to_s.upcase)
      position.asset1_amount || BigDecimal("0")
    else
      BigDecimal("0")
    end
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

  def serialize_position(position)
    return nil unless position

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
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

  def weth_rebalance?(rebalance)
    HEDGEABLE_SYMBOLS.include?(rebalance.asset.to_s.upcase)
  end

  def gates
    {
      hyperliquid_testnet: ENV["HYPERLIQUID_TESTNET"],
      live_approved: boolean_env("AERODROME_LIVE_APPROVED"),
      hedge_enabled: boolean_env("AERODROME_HEDGE_ENABLED"),
      hedge_paused: boolean_env("AERODROME_HEDGE_PAUSED"),
      target_step_enabled: boolean_env("AERODROME_TARGET_STEP_TEST_ENABLED"),
      confirmation_valid: ENV["AERODROME_TARGET_STEP_TEST_CONFIRM"].to_s == CONFIRMATION,
      restore_target: boolean_env("AERODROME_TARGET_STEP_TEST_RESTORE_TARGET"),
      close_on_finish: boolean_env("AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH"),
      max_leverage: max_leverage&.to_s("F"),
      max_short_eth: max_short_eth&.to_s("F"),
      max_short_notional_usd: max_short_notional_usd&.to_s("F"),
      min_order_notional_usd: min_order_notional_usd&.to_s("F"),
      volatility_guard_enabled: boolean_env("AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED"),
      emergency_close_enabled: boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED")
    }
  end

  def up_target
    decimal_env("AERODROME_TARGET_STEP_TEST_UP_TARGET")
  end

  def down_target
    decimal_env("AERODROME_TARGET_STEP_TEST_DOWN_TARGET")
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

  def step_sleep_seconds
    integer_env("AERODROME_TARGET_STEP_TEST_STEP_SLEEP_SECONDS", 10)
  end

  def readback_attempts
    integer_env("AERODROME_TARGET_STEP_TEST_READBACK_ATTEMPTS", 5)
  end

  def readback_sleep_seconds
    integer_env("AERODROME_TARGET_STEP_TEST_READBACK_SLEEP_SECONDS", 10)
  end

  def boolean_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def integer_env(key, default)
    Integer(ENV[key].presence || default)
  rescue ArgumentError
    default
  end

  def decimal_string(value)
    value ? BigDecimal(value.to_s).to_s("F") : nil
  end

  def timestamp
    @clock.call.iso8601
  end

  def timestamp_for_path
    @clock.call.strftime("%Y%m%d%H%M%S")
  end
end
