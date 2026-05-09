class AerodromePreLiveCheck
  BANNER = "PRE-LIVE READINESS CHECK — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  attr_reader :check_hyperliquid

  def initialize(check_hyperliquid: false, hyperliquid_service: nil)
    @check_hyperliquid = check_hyperliquid
    @hyperliquid_service = hyperliquid_service
    @checks = { env: [], db: [], risk_limits: [], rehearsal_evidence: [], hyperliquid_readback: [] }
    @blockers = []
    @warnings = []
  end

  def report
    add_safety_checks
    positions = check_database
    check_risk_limits(positions)
    check_rehearsal_evidence(positions)
    check_hyperliquid_readback if check_hyperliquid

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

  def add_safety_checks
    check_boolean(:env, "AERODROME_READ_ONLY_ENABLED", true, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_ENABLED", false, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_PAUSED", true, blocker: true)
    check_boolean(:env, "HYPERLIQUID_TESTNET", true, blocker: true)

    %w[
      AERODROME_MAX_LEVERAGE
      AERODROME_MAX_SHORT_ETH
      AERODROME_MAX_SHORT_NOTIONAL_USD
      BASE_RPC_URL
      AERODROME_SLIPSTREAM_TOKEN_IDS
      AERODROME_USDC_ADDRESS
      AERODROME_WETH_ADDRESS
    ].each { |key| check_presence(:env, key, blocker: true) }
  end

  def check_database
    dex = Dex.find_by(name: DEX_NAME)
    add_check(:db, "Aerodrome dex exists", dex.present?, blocker: true)
    return Position.none unless dex

    positions = Position.includes(:user, :hedge).where(dex: dex)
    active_positions = positions.select(&:active?)
    add_check(:db, "Aerodrome active position exists", active_positions.any?, blocker: true)

    active_positions.each { |position| check_position(position) }
    active_positions
  end

  def check_position(position)
    prefix = "Position #{position.id}"
    add_check(:db, "#{prefix} has asset0/asset1", position.asset0.present? && position.asset1.present?, blocker: true)
    add_check(:db, "#{prefix} has asset amounts", position.asset0_amount.present? && position.asset1_amount.present?, blocker: true)
    add_check(:db, "#{prefix} has USD prices", position.asset0_price_usd.present? && position.asset1_price_usd.present?, blocker: true)

    hedge = position.hedge
    add_check(:db, "#{prefix} explicit Hedge exists", hedge.present?, blocker: true)
    return unless hedge

    add_check(:db, "Hedge #{hedge.id} active", hedge.active?, blocker: true)
    add_check(:db, "Hedge #{hedge.id} target valid", hedge.target.present? && hedge.target.positive?, blocker: true)
    add_check(:db, "Hedge #{hedge.id} tolerance valid", hedge.tolerance.present? && hedge.tolerance.positive?, blocker: true)
  end

  def check_risk_limits(positions)
    positions.each do |position|
      hedge = position.hedge
      next unless hedge

      setting = position.user.setting
      add_check(:risk_limits, "Setting exists for user #{position.user_id}", setting.present?, blocker: true)
      check_leverage(setting) if setting

      hedge_asset = hedgeable_asset(position)
      add_check(:risk_limits, "Position #{position.id} ETH/WETH side is hedgeable", hedge_asset.present?, blocker: true)
      add_check(:risk_limits, "Position #{position.id} USDC side is not hedgeable", usdc_skipped?(position), blocker: true)
      check_target_limits(position, hedge, hedge_asset) if hedge_asset
    end
  end

  def check_leverage(setting)
    limit = decimal_env("AERODROME_MAX_LEVERAGE")
    return add_check(:risk_limits, "AERODROME_MAX_LEVERAGE parseable", false, blocker: true) unless limit

    add_check(
      :risk_limits,
      "Setting leverage <= AERODROME_MAX_LEVERAGE",
      BigDecimal(setting.hyperliquid_leverage.to_s) <= limit,
      blocker: true,
      value: setting.hyperliquid_leverage
    )
  end

  def check_target_limits(position, hedge, hedge_asset)
    target_short = hedge_asset.fetch(:amount) * hedge.target
    target_notional = target_short * hedge_asset.fetch(:price)
    max_short = decimal_env("AERODROME_MAX_SHORT_ETH")
    max_notional = decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")

    add_check(:risk_limits, "AERODROME_MAX_SHORT_ETH parseable", max_short.present?, blocker: true)
    add_check(:risk_limits, "AERODROME_MAX_SHORT_NOTIONAL_USD parseable", max_notional.present?, blocker: true)
    return unless max_short && max_notional

    add_check(
      :risk_limits,
      "Position #{position.id} target ETH short <= limit",
      target_short <= max_short,
      blocker: true,
      value: target_short.to_s("F")
    )
    add_check(
      :risk_limits,
      "Position #{position.id} target ETH notional <= limit",
      target_notional <= max_notional,
      blocker: true,
      value: target_notional.to_s("F")
    )
  end

  def check_rehearsal_evidence(positions)
    positions.each do |position|
      hedge = position.hedge
      next unless hedge

      rebalances = hedge.short_rebalances.order(:rebalanced_at, :id).to_a
      weth_successes = rebalances.select { |rebalance| weth_rebalance?(rebalance) && success?(rebalance) }
      failed_weth = rebalances.select { |rebalance| weth_rebalance?(rebalance) && failed?(rebalance) }
      usdc_successes = rebalances.select { |rebalance| rebalance.asset == "USDC" && success?(rebalance) }

      open = weth_successes.any? { |r| decimal(r.old_short_size).zero? && decimal(r.new_short_size).positive? }
      adjustment = weth_successes.any? { |r| decimal(r.old_short_size).positive? && decimal(r.new_short_size).positive? && decimal(r.old_short_size) != decimal(r.new_short_size) }
      close = weth_successes.reverse.find { |r| decimal(r.old_short_size).positive? && decimal(r.new_short_size).zero? }

      add_check(:rehearsal_evidence, "Hedge #{hedge.id} WETH success open exists", open, blocker: true)
      add_check(:rehearsal_evidence, "Hedge #{hedge.id} WETH success rebalance up/down exists", adjustment, warning: true)
      add_check(:rehearsal_evidence, "Hedge #{hedge.id} WETH success close-to-zero exists", close.present?, blocker: true)
      add_check(:rehearsal_evidence, "Hedge #{hedge.id} has no successful USDC rebalance", usdc_successes.empty?, blocker: true)

      failed_after_close = close ? failed_weth.any? { |r| r.rebalanced_at && r.rebalanced_at > close.rebalanced_at } : false
      add_check(:rehearsal_evidence, "Hedge #{hedge.id} no failed WETH rebalances after last close", !failed_after_close, warning: true)
      add_check(:rehearsal_evidence, "Hedge #{hedge.id} historical failed WETH rebalances", failed_weth.empty?, warning: true)
    end
  end

  def check_hyperliquid_readback
    position = hyperliquid_service.get_position("ETH")
    current_short = position ? decimal(position[:size]).abs : BigDecimal("0")
    open_position = current_short.positive?
    @checks[:hyperliquid_readback] << {
      name: "Hyperliquid get_position(\"ETH\") read-only",
      status: "ok",
      value: current_short.to_s("F")
    }
    add_check(
      :hyperliquid_readback,
      "No open ETH short while Aerodrome hedge disabled and paused",
      !production_safe_flags? || !open_position,
      blocker: true,
      value: current_short.to_s("F")
    )
  rescue => e
    add_check(:hyperliquid_readback, "Hyperliquid read-only get_position(\"ETH\")", false, warning: true, value: e.message)
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

  def usdc_skipped?(position)
    [ position.asset0, position.asset1 ].any? { |symbol| symbol.to_s.upcase == "USDC" }
  end

  def check_boolean(section, key, expected, blocker:)
    actual = ActiveModel::Type::Boolean.new.cast(ENV[key])
    add_check(section, "#{key} is #{expected}", actual == expected, blocker: blocker, value: ENV[key].inspect)
  end

  def check_presence(section, key, blocker:)
    add_check(section, "#{key} present", ENV[key].present?, blocker: blocker)
  end

  def add_check(section, name, passed, blocker: false, warning: false, value: nil)
    result = {
      name: name,
      status: passed ? "pass" : "fail"
    }
    result[:value] = value unless value.nil?
    @checks.fetch(section) << result
    return if passed

    message = value.nil? ? name : "#{name}: #{value}"
    if blocker
      @blockers << message
    elsif warning
      @warnings << message
    end
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Resolve blockers before any further rehearsal or live discussion." ] if @blockers.any?
    return [ "Review warnings and rerun the read-only check before any live discussion." ] if @warnings.any?

    [ "Passing this check is not live approval. Live requires a separate future approval/change." ]
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

  def production_safe_flags?
    ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_HEDGE_ENABLED"]) == false &&
      ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_HEDGE_PAUSED"]) == true
  end
end
