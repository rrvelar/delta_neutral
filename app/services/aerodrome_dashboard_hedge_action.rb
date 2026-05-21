class AerodromeDashboardHedgeAction
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_HYPERLIQUID_ORDERS"
  ACTIONS = %w[open rebalance close].freeze
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(position:, action:, execute: false, confirmation: nil, hyperliquid_service: nil, hedge_sync_runner: nil, emergency_close_factory: nil, log_dir: nil)
    @position = position
    @hedge = position.hedge
    @action = action.to_s
    @execute = execute
    @confirmation = confirmation.to_s
    @hyperliquid_service = hyperliquid_service
    @hedge_sync_runner = hedge_sync_runner || ->(hedge_id) { HedgeSyncJob.perform_now(hedge_id) }
    @emergency_close_factory = emergency_close_factory || method(:default_emergency_close)
    @log_dir = log_dir || Rails.root.join("storage", "aerodrome_dashboard_hedge_actions")
    @warnings = []
  end

  def report
    return blocked([ "unsupported dashboard hedge action" ]) unless ACTIONS.include?(@action)

    before_position = current_eth_position
    current_short = short_size(before_position)
    target = target_short
    drift = target ? target - current_short : nil
    blockers = action_blockers(target: target, current_short: current_short, drift: drift)
    blockers.concat(execution_gate_blockers) if @execute
    result = blockers.any? ? blocked(blockers, target: target, current_short: current_short, drift: drift, before_position: before_position) : run_action(target: target, current_short: current_short, drift: drift, before_position: before_position)

    write_receipt(result)
    result
  rescue => e
    result = base_result(
      status: "failed",
      target: target_short,
      current_short: nil,
      drift: nil,
      before_position: nil,
      after_position: nil,
      blockers: [],
      errors: [ "#{e.class}: #{e.message}" ]
    )
    write_receipt(result)
    result
  end

  def self.execution_gate_blockers(action: nil, submitted_confirmation: nil, require_submitted_confirmation: false)
    blockers = []
    blockers << "AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED must be true" unless bool_env("AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED")
    blockers << "AERODROME_DASHBOARD_HEDGE_CONFIRMATION must equal #{CONFIRMATION}" unless ENV["AERODROME_DASHBOARD_HEDGE_CONFIRMATION"].to_s == CONFIRMATION
    if require_submitted_confirmation && submitted_confirmation.to_s != submitted_confirmation_phrase(action)
      blockers << "submitted confirmation must equal #{submitted_confirmation_phrase(action)}"
    end
    blockers << "AERODROME_LIVE_APPROVED must be true" unless bool_env("AERODROME_LIVE_APPROVED")
    blockers << "AERODROME_HEDGE_ENABLED must be true" unless bool_env("AERODROME_HEDGE_ENABLED")
    blockers << "AERODROME_HEDGE_PAUSED must be false" if bool_env("AERODROME_HEDGE_PAUSED", default: true)
    blockers << "HYPERLIQUID_TESTNET must be false" if bool_env("HYPERLIQUID_TESTNET", default: true)
    blockers
  end

  def self.bool_env(key, default: false)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
  end

  def self.submitted_confirmation_phrase(action)
    action.to_s == "close" ? AerodromeLiveEmergencyClose::CONFIRMATION : CONFIRMATION
  end

  private

  def run_action(target:, current_short:, drift:, before_position:)
    after_position = nil
    execution_result = nil

    if @execute
      execution_result = if @action == "close"
        run_emergency_close
      else
        @hedge_sync_runner.call(@hedge.id)
        { status: "submitted" }
      end
      after_position = current_eth_position
    end

    base_result(
      status: @execute ? "submitted" : "preview",
      target: target,
      current_short: current_short,
      drift: drift,
      before_position: before_position,
      after_position: after_position,
      blockers: [],
      errors: [],
      execution_result: execution_result
    )
  end

  def blocked(blockers, target: nil, current_short: nil, drift: nil, before_position: nil)
    base_result(
      status: "blocked",
      target: target,
      current_short: current_short,
      drift: drift,
      before_position: before_position,
      after_position: nil,
      blockers: blockers.uniq,
      errors: []
    )
  end

  def base_result(status:, target:, current_short:, drift:, before_position:, after_position:, blockers:, errors:, execution_result: nil)
    {
      status: status,
      requested_action: @action,
      position_id: @position.id,
      hedge_id: @hedge&.id,
      dry_run: !@execute,
      database_write: false,
      orders_enabled: @execute && blockers.empty?,
      hyperliquid_execution: @execute && blockers.empty?,
      live_order_capable: @execute,
      target_short_eth: target&.to_s("F"),
      target_notional_usd: target && eth_price ? (target * eth_price).to_s("F") : nil,
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      drift_notional_usd: drift && eth_price ? (drift * eth_price).to_s("F") : nil,
      tolerance_eth: tolerance_eth(target)&.to_s("F"),
      submitted_delta_eth: submitted_delta(target: target, current_short: current_short, drift: drift)&.to_s("F"),
      current_position_before: serialize_position(before_position),
      readback_after: serialize_position(after_position),
      result: execution_result,
      blockers: blockers,
      warnings: @warnings,
      errors: errors,
      receipt_path: nil
    }
  end

  def action_blockers(target:, current_short:, drift:)
    blockers = base_blockers(target: target, current_short: current_short)
    return blockers if blockers.any?

    tolerance = tolerance_eth(target)
    case @action
    when "open"
      blockers << "current ETH short already exists; use rebalance or close" if current_short.positive?
      blockers << "target ETH short is zero" unless target&.positive?
      blockers << "target ETH short is within tolerance; open not needed" unless target && tolerance && target > tolerance
    when "rebalance"
      blockers << "drift is within hedge tolerance" unless drift && tolerance && drift.abs > tolerance
    when "close"
      blockers << "no current ETH short to close" unless current_short.positive?
    end
    blockers
  end

  def base_blockers(target:, current_short:)
    blockers = []
    blockers << "position must be Aerodrome Slipstream" unless @position.dex.name == "aerodrome_slipstream"
    blockers << "position is inactive" unless @position.active?
    blockers << "active hedge is required" unless @hedge&.active?
    blockers << "WETH/ETH LP exposure is unavailable" unless weth_amount
    blockers << "WETH/ETH price is unavailable" unless eth_price
    blockers.concat(AerodromeProductionRiskLimits.runtime_cap_errors(
      max_short_eth: decimal_env("AERODROME_MAX_SHORT_ETH"),
      max_short_notional_usd: decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD"),
      emergency_close_max_eth: decimal_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
    ))
    if target && decimal_env("AERODROME_MAX_SHORT_ETH") && target > decimal_env("AERODROME_MAX_SHORT_ETH")
      blockers << "target hedge exceeds AERODROME_MAX_SHORT_ETH"
    end
    if target && eth_price && decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD") && target * eth_price > decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
      blockers << "target hedge notional exceeds AERODROME_MAX_SHORT_NOTIONAL_USD"
    end
    if decimal_env("AERODROME_MAX_SHORT_ETH") && current_short > decimal_env("AERODROME_MAX_SHORT_ETH")
      blockers << "current ETH short exceeds AERODROME_MAX_SHORT_ETH"
    end
    blockers.uniq
  end

  def execution_gate_blockers
    self.class.execution_gate_blockers(action: @action, submitted_confirmation: @confirmation, require_submitted_confirmation: true)
  end

  def run_emergency_close
    old_paused = ENV["AERODROME_HEDGE_PAUSED"]
    ENV["AERODROME_HEDGE_PAUSED"] = "true"
    @emergency_close_factory.call.report
  ensure
    old_paused.nil? ? ENV.delete("AERODROME_HEDGE_PAUSED") : ENV["AERODROME_HEDGE_PAUSED"] = old_paused
  end

  def default_emergency_close
    AerodromeLiveEmergencyClose.new(hyperliquid_service: hyperliquid)
  end

  def current_eth_position
    hyperliquid.get_position("ETH")
  rescue => e
    @warnings << "current ETH readback unavailable: #{e.class}: #{e.message}"
    nil
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def target_short
    return nil unless @hedge && weth_amount

    weth_amount * @hedge.target
  end

  def submitted_delta(target:, current_short:, drift:)
    return nil unless target && current_short

    case @action
    when "open", "rebalance"
      drift
    when "close"
      -current_short
    end
  end

  def tolerance_eth(target)
    return nil unless target && @hedge

    target * @hedge.tolerance
  end

  def weth_amount
    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_amount
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_amount
    end
  end

  def eth_price
    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
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

  def decimal_env(key)
    raw = ENV[key].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def write_receipt(result)
    FileUtils.mkdir_p(@log_dir)
    path = @log_dir.join("#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    event = result.merge(
      event: "dashboard_hedge_action",
      timestamp: Time.current.iso8601,
      receipt_path: path.to_s
    )
    File.open(path, "a") { |file| file.puts(JSON.generate(event)) }
    result[:receipt_path] = path.to_s
  end
end
