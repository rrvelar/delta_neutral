class AerodromeLiveObservationWindow
  BANNER = "AERODROME LIVE OBSERVATION WINDOW"
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_LIVE_HEDGE_OBSERVATION"
  MAX_DURATION_SECONDS = 10_800
  MIN_INTERVAL_SECONDS = 60
  MAX_SHORT_ETH = BigDecimal("0.02")
  MAX_SHORT_NOTIONAL_USD = BigDecimal("50")

  def initialize(
    hyperliquid_service: nil,
    position_sync: ->(position_id) { PositionSyncJob.perform_now(position_id) },
    hedge_sync: ->(hedge_id) { HedgeSyncJob.perform_now(hedge_id) },
    emergency_close_factory: -> { AerodromeLiveEmergencyClose.new },
    sleeper: ->(seconds) { sleep(seconds) },
    log_dir: Rails.root.join("storage", "aerodrome_live_observation"),
    clock: -> { Time.current }
  )
    @hyperliquid_service = hyperliquid_service
    @position_sync = position_sync
    @hedge_sync = hedge_sync
    @emergency_close_factory = emergency_close_factory
    @sleeper = sleeper
    @log_dir = Pathname(log_dir)
    @clock = clock
    @iterations = []
    @errors = []
    @final_close = nil
    @final_position = nil
    @final_position_confirmed = false
    @final_readback_attempts = []
    @manual_action_required = false
  end

  def report
    errors = gate_errors
    return blocked(errors) if errors.any?

    before = read_eth_position
    if short_size(before).positive?
      return blocked([ "mainnet ETH position must be nil before observation window" ], final_position: before)
    end

    initialize_log
    record_event(type: "start", gates: gates, hedge_id: hedge.id, position_id: position.id)
    run_loop
    finish
  rescue => e
    @errors << "#{e.class}: #{e.message}"
    finish
  end

  private

  def run_loop
    max_iterations.times do |index|
      iteration_number = index + 1
      before_rebalance_id = ShortRebalance.maximum(:id) || 0
      error = nil

      begin
        @position_sync.call(position.id)
        position.reload
        @hedge_sync.call(hedge.id)
      rescue => e
        error = "#{e.class}: #{e.message}"
        @errors << error
      end

      actual_position = read_eth_position
      new_rebalances = hedge.short_rebalances.where("id > ?", before_rebalance_id).order(:id).to_a
      event = iteration_event(iteration_number, actual_position, new_rebalances, error)
      @iterations << event
      record_event(event.merge(type: "iteration"))

      break if error
      if new_rebalances.any? { |rebalance| rebalance.status == ShortRebalance::STATUS_FAILED }
        @errors << "failed ShortRebalance created during observation window"
        break
      end

      if short_size(actual_position) > max_short_eth
        @errors << "actual ETH short exceeds AERODROME_MAX_SHORT_ETH"
        break
      end

      @sleeper.call(interval_seconds) if iteration_number < max_iterations
    end
  end

  def finish
    before_close, before_close_error = safe_eth_position_read("final pre-close")
    should_close = short_size(before_close).positive? || before_close_error.present?
    @final_close = should_close ? safe_run_final_close : { status: "noop", errors: [] }
    @final_position = final_readback
    @manual_action_required = !@final_position_confirmed || short_size(@final_position).positive?
    record_event(
      type: "final",
      final_close: @final_close,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      final_readback_attempts: @final_readback_attempts,
      errors: @errors,
      manual_action_required: @manual_action_required
    )

    status = final_status
    base_report(status)
  end

  def safe_run_final_close
    run_final_close
  rescue => e
    error = "final emergency close failed: #{e.class}: #{e.message}"
    @errors << error
    { status: "failed", errors: [ error ], attempts: [] }
  end

  def run_final_close
    previous_paused = ENV["AERODROME_HEDGE_PAUSED"]
    ENV["AERODROME_HEDGE_PAUSED"] = "true"
    report = @emergency_close_factory.call.report
    report.deep_symbolize_keys
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
      attempt = index + 1
      begin
        position = read_eth_position
        @final_position_confirmed = true
        @final_readback_attempts << {
          attempt: attempt,
          status: "success",
          position: serialize_position(position)
        }
        return position
      rescue => e
        error = "final ETH readback attempt #{attempt} failed: #{e.class}: #{e.message}"
        @errors << error
        @final_readback_attempts << {
          attempt: attempt,
          status: "error",
          error: "#{e.class}: #{e.message}"
        }
        @sleeper.call(final_readback_sleep_seconds) if attempt < final_readback_attempts
      end
    end

    nil
  end

  def final_status
    return "close_unknown" unless @final_position_confirmed
    return "failed" if short_size(@final_position).positive?
    return "failed" if @errors.any?
    return "failed" if @final_close && @final_close[:status].to_s == "failed"

    "success"
  end

  def initialize_log
    FileUtils.mkdir_p(@log_dir)
    @log_path = @log_dir.join("#{log_timestamp}-#{SecureRandom.hex(4)}.jsonl")
  end

  def record_event(event)
    return unless @log_path

    File.open(@log_path, "a") { |file| file.puts(JSON.generate(event)) }
  end

  def iteration_event(iteration_number, actual_position, new_rebalances, error)
    {
      iteration: iteration_number,
      timestamp: @clock.call.iso8601,
      position: position_snapshot,
      target_short: target_short.to_s("F"),
      actual_eth_position: serialize_position(actual_position),
      new_short_rebalances: new_rebalances.map { |rebalance| serialize_rebalance(rebalance) },
      errors: [ error ].compact
    }
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

  def gate_errors
    errors = []
    errors << "HYPERLIQUID_TESTNET must be false" unless boolean_env("HYPERLIQUID_TESTNET") == false
    errors << "AERODROME_LIVE_APPROVED must be true" unless boolean_env("AERODROME_LIVE_APPROVED") == true
    errors << "AERODROME_HEDGE_ENABLED must be true" unless boolean_env("AERODROME_HEDGE_ENABLED") == true
    errors << "AERODROME_HEDGE_PAUSED must be false" unless boolean_env("AERODROME_HEDGE_PAUSED") == false
    errors << "AERODROME_LIVE_OBSERVATION_ENABLED must be true" unless boolean_env("AERODROME_LIVE_OBSERVATION_ENABLED") == true
    errors << "AERODROME_LIVE_OBSERVATION_CONFIRM must equal #{CONFIRMATION}" unless ENV["AERODROME_LIVE_OBSERVATION_CONFIRM"].to_s == CONFIRMATION
    errors << "AERODROME_LIVE_OBSERVATION_DURATION_SECONDS must be configured" unless duration_seconds
    errors << "AERODROME_LIVE_OBSERVATION_INTERVAL_SECONDS must be configured" unless interval_seconds
    errors << "duration must be <= #{MAX_DURATION_SECONDS} seconds" if duration_seconds && duration_seconds > MAX_DURATION_SECONDS
    errors << "interval must be >= #{MIN_INTERVAL_SECONDS} seconds" if interval_seconds && interval_seconds < MIN_INTERVAL_SECONDS
    errors << "AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH must be true" unless boolean_env("AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH") == true
    errors << "AERODROME_MAX_LEVERAGE must be 1" unless max_leverage == BigDecimal("1")
    errors << "AERODROME_MAX_SHORT_ETH must be configured and <= #{MAX_SHORT_ETH.to_s('F')}" unless max_short_eth && max_short_eth <= MAX_SHORT_ETH
    errors << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured and <= #{MAX_SHORT_NOTIONAL_USD.to_s('F')}" unless max_short_notional_usd && max_short_notional_usd <= MAX_SHORT_NOTIONAL_USD
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true" unless boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED") == true
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{AerodromeLiveEmergencyClose::CONFIRMATION}" unless ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and >= AERODROME_MAX_SHORT_ETH" unless emergency_close_max_eth && max_short_eth && emergency_close_max_eth >= max_short_eth
    errors << "No Aerodrome hedge/position found" unless hedge
    errors
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
      gates: gates,
      iterations: @iterations,
      final_close: @final_close,
      final_position: serialize_position(@final_position),
      final_position_confirmed: @final_position_confirmed,
      final_readback_attempts: @final_readback_attempts,
      manual_action_required: @manual_action_required,
      errors: @errors
    }
  end

  def gates
    {
      hyperliquid_testnet: ENV["HYPERLIQUID_TESTNET"],
      live_approved: boolean_env("AERODROME_LIVE_APPROVED"),
      hedge_enabled: boolean_env("AERODROME_HEDGE_ENABLED"),
      hedge_paused: boolean_env("AERODROME_HEDGE_PAUSED"),
      observation_enabled: boolean_env("AERODROME_LIVE_OBSERVATION_ENABLED"),
      confirmation_valid: ENV["AERODROME_LIVE_OBSERVATION_CONFIRM"].to_s == CONFIRMATION,
      duration_seconds: duration_seconds,
      interval_seconds: interval_seconds,
      close_on_finish: boolean_env("AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH"),
      max_leverage: max_leverage&.to_s("F"),
      max_short_eth: max_short_eth&.to_s("F"),
      max_short_notional_usd: max_short_notional_usd&.to_s("F"),
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
    amount = if position.asset0.to_s.upcase.in?(%w[ETH WETH])
      position.asset0_amount
    elsif position.asset1.to_s.upcase.in?(%w[ETH WETH])
      position.asset1_amount
    else
      BigDecimal("0")
    end
    (amount || 0) * hedge.target
  end

  def read_eth_position
    hyperliquid.get_position("ETH")
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def max_iterations
    [ (duration_seconds.to_f / interval_seconds).ceil, 1 ].max
  end

  def duration_seconds
    integer_env("AERODROME_LIVE_OBSERVATION_DURATION_SECONDS")
  end

  def interval_seconds
    integer_env("AERODROME_LIVE_OBSERVATION_INTERVAL_SECONDS")
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

  def emergency_close_max_eth
    decimal_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
  end

  def final_readback_attempts
    integer_env("AERODROME_LIVE_OBSERVATION_FINAL_READBACK_ATTEMPTS") || 5
  end

  def final_readback_sleep_seconds
    integer_env("AERODROME_LIVE_OBSERVATION_FINAL_READBACK_SLEEP_SECONDS") || 10
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

  def log_timestamp
    @clock.call.utc.strftime("%Y%m%d%H%M%S")
  end
end
