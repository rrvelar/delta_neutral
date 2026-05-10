class AerodromeLivePreflightCheck
  BANNER = "AERODROME LIVE PREFLIGHT — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(check_hyperliquid: false, hyperliquid_service: nil)
    @check_hyperliquid = check_hyperliquid
    @hyperliquid_service = hyperliquid_service
    @checks = { env: [], db: [], risk: [], testnet_evidence: [], hyperliquid_readback: [] }
    @blockers = []
    @warnings = []
  end

  def report
    check_environment
    positions = check_database
    check_risk(positions)
    check_testnet_evidence(positions)
    check_hyperliquid_readback if @check_hyperliquid

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      checks: @checks,
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  private

  def check_environment
    check_boolean(:env, "HYPERLIQUID_TESTNET", false, blocker: true)
    check_boolean(:env, "AERODROME_LIVE_APPROVED", false, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_ENABLED", false, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_PAUSED", true, blocker: true)
    check_boolean(:env, "AERODROME_READ_ONLY_ENABLED", true, blocker: true)

    check_presence(:env, "AERODROME_MAX_SHORT_ETH", blocker: true)
    check_presence(:env, "AERODROME_MAX_SHORT_NOTIONAL_USD", blocker: true)
    check_presence(:env, "AERODROME_MIN_ORDER_NOTIONAL_USD", blocker: true)
    check_presence(:env, "BASE_RPC_URL", blocker: true)
    check_presence(:env, "AERODROME_SLIPSTREAM_TOKEN_IDS", blocker: true)
    check_presence(:env, "AERODROME_USDC_ADDRESS", blocker: true)
    check_presence(:env, "AERODROME_WETH_ADDRESS", blocker: true)

    max_leverage = decimal_env("AERODROME_MAX_LEVERAGE")
    add_check(:env, "AERODROME_MAX_LEVERAGE is 1", max_leverage == BigDecimal("1"), blocker: true, value: ENV["AERODROME_MAX_LEVERAGE"].inspect)
  end

  def check_database
    dex = Dex.find_by(name: DEX_NAME)
    add_check(:db, "Aerodrome dex exists", dex.present?, blocker: true)
    return [] unless dex

    positions = Position.includes(:user, :hedge).where(dex: dex).select(&:active?)
    add_check(:db, "Aerodrome active position exists", positions.any?, blocker: true)
    positions.each { |position| check_position(position) }
    positions
  end

  def check_position(position)
    hedge = position.hedge
    add_check(:db, "Position #{position.id} explicit hedge exists", hedge.present?, blocker: true)
    return unless hedge

    add_check(:db, "Hedge #{hedge.id} active", hedge.active?, blocker: true)
    add_check(:db, "Hedge #{hedge.id} target valid", hedge.target.present? && hedge.target.positive?, blocker: true)
    add_check(:db, "Hedge #{hedge.id} tolerance valid", hedge.tolerance.present? && hedge.tolerance.positive?, blocker: true)
  end

  def check_risk(positions)
    positions.each do |position|
      hedge = position.hedge
      next unless hedge

      setting = position.user.setting
      add_check(:risk, "Setting exists for user #{position.user_id}", setting.present?, blocker: true)
      if setting
        max_leverage = decimal_env("AERODROME_MAX_LEVERAGE")
        add_check(:risk, "Setting leverage <= max leverage", max_leverage && BigDecimal(setting.hyperliquid_leverage.to_s) <= max_leverage, blocker: true, value: setting.hyperliquid_leverage)
      end

      hedge_asset = hedgeable_asset(position)
      add_check(:risk, "ETH/WETH side is hedgeable", hedge_asset.present?, blocker: true)
      next unless hedge_asset

      target_short = hedge_asset.fetch(:amount) * hedge.target
      target_notional = target_short * hedge_asset.fetch(:price)
      max_short = decimal_env("AERODROME_MAX_SHORT_ETH")
      max_notional = decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
      add_check(:risk, "Target ETH short <= max", max_short && target_short <= max_short, blocker: true, value: target_short.to_s("F"))
      add_check(:risk, "Target ETH notional <= max", max_notional && target_notional <= max_notional, blocker: true, value: target_notional.to_s("F"))
    end
  end

  def check_testnet_evidence(positions)
    positions.each do |position|
      hedge = position.hedge
      next unless hedge

      rebalances = hedge.short_rebalances.order(:rebalanced_at, :id).to_a
      weth_successes = rebalances.select { |rebalance| weth_rebalance?(rebalance) && success?(rebalance) }
      failed_weth = rebalances.select { |rebalance| weth_rebalance?(rebalance) && failed?(rebalance) }
      usdc_successes = rebalances.select { |rebalance| rebalance.asset == "USDC" && success?(rebalance) }
      close = weth_successes.reverse.find { |r| decimal(r.old_short_size).positive? && decimal(r.new_short_size).zero? }

      add_check(:testnet_evidence, "WETH open success exists", weth_successes.any? { |r| decimal(r.old_short_size).zero? && decimal(r.new_short_size).positive? }, blocker: true)
      add_check(:testnet_evidence, "WETH rebalance up/down success exists", weth_successes.any? { |r| decimal(r.old_short_size).positive? && decimal(r.new_short_size).positive? && decimal(r.old_short_size) != decimal(r.new_short_size) }, blocker: true)
      add_check(:testnet_evidence, "WETH close-to-zero success exists", close.present?, blocker: true)
      add_check(:testnet_evidence, "No successful USDC rebalance exists", usdc_successes.empty?, blocker: true)
      failed_after_close = close ? failed_weth.select { |r| r.rebalanced_at && r.rebalanced_at > close.rebalanced_at } : []
      blocking_failures = failed_after_close.reject { |rebalance| acknowledged_zero_size_failure?(rebalance) }
      add_check(:testnet_evidence, "No failed WETH after last close", blocking_failures.empty?, blocker: true)
    end
  end

  def check_hyperliquid_readback
    position = hyperliquid_service.get_position("ETH")
    current_short = position ? decimal(position[:size]).abs : BigDecimal("0")
    @checks[:hyperliquid_readback] << { name: "Hyperliquid get_position(\"ETH\") read-only", status: "pass", value: current_short.to_s("F") }
    add_check(:hyperliquid_readback, "No open ETH short before first live micro-run", current_short.zero?, blocker: true, value: current_short.to_s("F"))
    read_account_balance
  rescue => e
    add_check(:hyperliquid_readback, "Hyperliquid ETH position readback", false, warning: true, value: e.message)
  end

  def read_account_balance
    return nil unless hyperliquid_service.respond_to?(:account_balance)

    wallet_address = ENV["HYPERLIQUID_WALLET_ADDRESS"].presence
    unless wallet_address
      add_check(:hyperliquid_readback, "Hyperliquid account balance read-only", false, warning: true, value: "HYPERLIQUID_WALLET_ADDRESS missing")
      return nil
    end

    balance = hyperliquid_service.account_balance(wallet_address)
    @checks[:hyperliquid_readback] << {
      name: "Hyperliquid account balance read-only",
      status: "pass",
      wallet_address: wallet_address,
      account_value: decimal(balance[:account_value]).to_s("F"),
      withdrawable: decimal(balance[:withdrawable]).to_s("F")
    }
    balance
  rescue => e
    add_check(:hyperliquid_readback, "Hyperliquid account balance read-only", false, warning: true, value: e.message)
    nil
  end

  def hyperliquid_service
    @hyperliquid_service ||= HyperliquidService.new
  end

  def hedgeable_asset(position)
    [
      { symbol: position.asset0, amount: position.asset0_amount, price: position.asset0_price_usd },
      { symbol: position.asset1, amount: position.asset1_amount, price: position.asset1_price_usd }
    ].find { |asset| HEDGEABLE_SYMBOLS.include?(asset.fetch(:symbol).to_s.upcase) }
  end

  def add_check(section, name, passed, blocker: false, warning: false, value: nil)
    result = { name: name, status: passed ? "pass" : "fail" }
    result[:value] = value unless value.nil?
    @checks.fetch(section) << result
    return if passed

    message = value.nil? ? name : "#{name}: #{value}"
    blocker ? @blockers << message : (@warnings << message if warning)
  end

  def check_boolean(section, key, expected, blocker:)
    actual = ActiveModel::Type::Boolean.new.cast(ENV[key])
    add_check(section, "#{key} is #{expected}", actual == expected, blocker: blocker, value: ENV[key].inspect)
  end

  def check_presence(section, key, blocker:)
    add_check(section, "#{key} present", ENV[key].present?, blocker: blocker)
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Resolve blockers before any first-live procedure." ] if @blockers.any?
    return [ "Review warnings before any first-live procedure." ] if @warnings.any?

    [ "PASS is not permission to live trade. First live micro-run requires a separate manual procedure and ready emergency close plan." ]
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

  def success?(rebalance)
    rebalance.status == ShortRebalance::STATUS_SUCCESS
  end

  def failed?(rebalance)
    rebalance.status == ShortRebalance::STATUS_FAILED
  end

  def weth_rebalance?(rebalance)
    HEDGEABLE_SYMBOLS.include?(rebalance.asset.to_s.upcase)
  end

  def acknowledged_zero_size_failure?(rebalance)
    failed?(rebalance) &&
      decimal(rebalance.old_short_size).zero? &&
      decimal(rebalance.new_short_size).zero? &&
      rebalance.message.to_s.include?(AerodromeFailedRebalanceAcknowledgment::MARKER)
  end
end
