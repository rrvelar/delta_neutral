class AerodromeProductionLiveRuntimeSafetyCheck
  BANNER = "AERODROME PRODUCTION LIVE RUNTIME SAFETY — READ ONLY"
  CONFIRMATION = "I_UNDERSTAND_THIS_RUNS_PRODUCTION_LIVE_HEDGE"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(
    hedge:,
    eth_position: nil,
    since_rebalance_id: 0,
    log_dirs: [
      Rails.root.join("storage", "aerodrome_production_live"),
      Rails.root.join("storage", "aerodrome_production_canary")
    ]
  )
    @hedge = hedge
    @position = hedge&.position
    @eth_position = eth_position
    @since_rebalance_id = since_rebalance_id || 0
    @log_dirs = log_dirs.map { |path| Pathname(path) }
    @checks = { env: [], risk: [], db: [], history: [], previous_run: [] }
    @blockers = []
    @warnings = []
  end

  def report
    check_env
    check_db
    check_risk
    check_history
    check_previous_run

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      checks: @checks,
      blockers: @blockers,
      warnings: @warnings
    }
  end

  private

  def check_env
    check_boolean(:env, "HYPERLIQUID_TESTNET", false)
    check_boolean(:env, "AERODROME_LIVE_APPROVED", true)
    check_boolean(:env, "AERODROME_HEDGE_ENABLED", true)
    check_boolean(:env, "AERODROME_HEDGE_PAUSED", false)
    check_boolean(:env, "AERODROME_PRODUCTION_LIVE_ENABLED", true)
    check_boolean(:env, "AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN", true)
    check_boolean(:env, "AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR", true)
    check_boolean(:env, "AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL", true)
    check_boolean(:env, "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED", true)
    add_check(:env, "AERODROME_PRODUCTION_LIVE_CONFIRM valid", ENV["AERODROME_PRODUCTION_LIVE_CONFIRM"].to_s == CONFIRMATION, blocker: true)
    add_check(:env, "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM valid", ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION, blocker: true)
  end

  def check_db
    add_check(:db, "Position exists", @position.present?, blocker: true)
    add_check(:db, "Position active", @position&.active? == true, blocker: true)
    add_check(:db, "Hedge exists", @hedge.present?, blocker: true)
    add_check(:db, "Hedge active", @hedge&.active? == true, blocker: true)
  end

  def check_risk
    size = short_size(@eth_position)
    max_eth = decimal_env("AERODROME_MAX_SHORT_ETH")
    max_notional = decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
    price = eth_price
    notional = size * (price || BigDecimal("0"))

    add_check(:risk, "ETH short <= max ETH", max_eth && size <= max_eth, blocker: true, value: size.to_s("F"))
    add_check(:risk, "ETH notional <= max notional", max_notional && price && notional <= max_notional, blocker: true, value: notional.to_s("F"))
  end

  def check_history
    return unless @hedge

    recent = @hedge.short_rebalances.where("id > ?", @since_rebalance_id).order(:id).to_a
    add_check(:history, "No failed WETH during live run", recent.none? { |rebalance| weth_rebalance?(rebalance) && failed?(rebalance) }, blocker: true)
    add_check(:history, "No successful USDC during live run", recent.none? { |rebalance| rebalance.asset == "USDC" && success?(rebalance) }, blocker: true)
  end

  def check_previous_run
    final_event = latest_final_event
    return unless final_event

    if final_event.fetch("manual_action_required", nil) == true
      add_check(:previous_run, "Previous live/canary manual_action_required false", false, blocker: true)
    end
    if final_event.fetch("final_position", nil).present?
      add_check(:previous_run, "Previous live/canary final position nil", false, blocker: true, value: final_event.fetch("final_position").inspect)
    end
  rescue JSON::ParserError, Errno::ENOENT
    add_check(:previous_run, "Previous live/canary log readable", true)
  end

  def latest_final_event
    paths = @log_dirs.flat_map { |dir| Dir.glob(dir.join("*.jsonl")) }
    path = paths.max_by { |candidate| File.mtime(candidate) }
    return nil unless path

    File.readlines(path).filter_map do |line|
      event = JSON.parse(line)
      event if %w[finish final].include?(event["type"])
    end.last
  end

  def check_boolean(section, key, expected)
    add_check(section, "#{key} is #{expected}", boolean_env(key) == expected, blocker: true, value: ENV[key].inspect)
  end

  def add_check(section, name, passed, blocker: false, warning: false, value: nil)
    result = { name: name, status: passed ? "pass" : "fail" }
    result[:value] = value unless value.nil?
    @checks.fetch(section) << result
    return if passed

    message = value.nil? ? name : "#{name}: #{value}"
    blocker ? @blockers << message : (@warnings << message if warning)
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def eth_price
    return nil unless @position

    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
    end
  end

  def decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def boolean_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def success?(rebalance)
    rebalance.status == ShortRebalance::STATUS_SUCCESS
  end

  def failed?(rebalance)
    rebalance.status == ShortRebalance::STATUS_FAILED
  end

  def weth_rebalance?(rebalance)
    HEDGEABLE_SYMBOLS.include?(rebalance.asset.to_s.upcase)
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end
end
