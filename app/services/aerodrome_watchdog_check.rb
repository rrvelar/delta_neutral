class AerodromeWatchdogCheck
  BANNER = "AERODROME WATCHDOG CHECK — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze
  PNL_STALE_AFTER = 10.minutes

  def initialize(
    mainnet_hyperliquid_service: nil,
    testnet_hyperliquid_service: nil,
    observation_summary: nil,
    production_readiness: nil,
    rewards_check: nil,
    fees_check: nil,
    approved_open_position: nil,
    log_dir: Rails.root.join("storage", "aerodrome_live_observation"),
    clock: -> { Time.current }
  )
    @mainnet_hyperliquid_service = mainnet_hyperliquid_service
    @testnet_hyperliquid_service = testnet_hyperliquid_service
    @observation_summary = observation_summary
    @production_readiness = production_readiness
    @rewards_check = rewards_check
    @fees_check = fees_check
    @approved_open_position = approved_open_position
    @log_dir = Pathname(log_dir)
    @clock = clock
    @checks = { env: [], hyperliquid: [], approved_open_position: [], observation: [], history: [], dashboard: [], readiness: [], logs: [], metadata: [] }
    @alerts = []
    @warnings = []
    @blockers = []
  end

  def report
    position = active_aerodrome_position
    check_env
    check_metadata
    check_hyperliquid
    check_observation
    check_history(position)
    check_dashboard(position)
    check_production_readiness
    check_logs

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      alerts: @alerts,
      warnings: @warnings,
      blockers: @blockers,
      approved_open_position: @approved_open_position_report,
      readiness_status: @readiness_status,
      readiness_blockers: @readiness_blockers || [],
      readiness_warnings: @readiness_warnings || [],
      readiness_blockers_suppressed_due_approved_open: @readiness_blockers_suppressed_due_approved_open || [],
      checks: @checks,
      next_steps: next_steps
    }
  end

  private

  def check_env
    check_boolean(:env, "AERODROME_HEDGE_ENABLED", false, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_PAUSED", true, blocker: true)
    check_boolean(:env, "AERODROME_LIVE_APPROVED", false, blocker: true)
    check_boolean(:env, "HYPERLIQUID_TESTNET", true, blocker: true)
  end

  def check_metadata
    if Rails.env.production?
      add_check(:metadata, "APP_GIT_SHA present in production", ENV["APP_GIT_SHA"].present?, blocker: true)
    else
      add_check(:metadata, "APP_GIT_SHA present", ENV["APP_GIT_SHA"].present?, warning: true)
    end
  end

  def check_hyperliquid
    mainnet = read_eth_position(:mainnet, mainnet_hyperliquid_service)
    approved = approved_open_position(mainnet).report
    record_approved_open_position(approved)

    if safe_env? && short_size(mainnet).positive?
      if approved.fetch(:approval_status) == "approved"
        add_check(:hyperliquid, "Mainnet ETH position approved open while safe env", true, value: short_size(mainnet).to_s("F"))
        @alerts << "approved open ETH hedge monitored"
      else
        add_check(:hyperliquid, "Mainnet ETH position nil while safe env", false, blocker: true, value: short_size(mainnet).to_s("F"))
        @alerts << "mainnet ETH position exists while Aerodrome hedge is disabled/paused"
      end
    else
      add_check(:hyperliquid, "Mainnet ETH position nil while safe env", true, value: short_size(mainnet).to_s("F"))
    end

    testnet = read_eth_position(:testnet, testnet_hyperliquid_service)
    add_check(:hyperliquid, "Testnet ETH position read-only", true, value: short_size(testnet).to_s("F"))
  end

  def record_approved_open_position(report)
    @approved_open_position_report = report
    @checks[:approved_open_position] << {
      name: "Approved open position status",
      status: report.fetch(:status).downcase,
      value: report.fetch(:approval_status)
    }

    case report.fetch(:approval_status)
    when "approved"
      nil
    when "current_nil"
      @warnings.concat(report.fetch(:warnings))
    else
      @blockers.concat(report.fetch(:blockers))
    end
  end

  def check_observation
    summary = observation_summary.report
    @checks[:observation] << { name: "Latest observation summary status", status: summary.fetch(:status).downcase, value: summary.fetch(:log_path) }

    if summary.fetch(:manual_action_required) == true
      add_check(:observation, "Latest observation manual_action_required false", false, blocker: true, value: "true")
      @alerts << "latest observation requires manual action"
    else
      add_check(:observation, "Latest observation manual_action_required false", true, value: summary.fetch(:manual_action_required).inspect)
    end

    if summary.fetch(:final_position).present?
      add_check(:observation, "Latest observation final position nil", false, blocker: true, value: summary.fetch(:final_position).inspect)
      @alerts << "latest observation final position is not nil"
    else
      add_check(:observation, "Latest observation final position nil", true)
    end

    @warnings.concat(summary.fetch(:warnings, []))
  end

  def check_history(position)
    return unless position&.hedge

    rebalances = position.hedge.short_rebalances.order(rebalanced_at: :desc, id: :desc).to_a
    failed_weth = rebalances.select { |rebalance| weth_rebalance?(rebalance) && failed?(rebalance) }
    close = rebalances.find { |r| weth_rebalance?(r) && success?(r) && decimal(r.old_short_size).positive? && decimal(r.new_short_size).zero? }
    failed_after_close = close ? failed_weth.select { |r| r.rebalanced_at && r.rebalanced_at > close.rebalanced_at } : failed_weth
    unacknowledged = failed_after_close.reject { |rebalance| acknowledged_zero_size_failure?(rebalance) }
    acknowledged = failed_weth.select { |rebalance| acknowledged_zero_size_failure?(rebalance) }
    usdc_successes = rebalances.select { |rebalance| rebalance.asset == "USDC" && success?(rebalance) }

    add_check(:history, "No unacknowledged failed WETH after last close", unacknowledged.empty?, blocker: true, value: unacknowledged.map(&:id).join(", "))
    @alerts << "unacknowledged failed WETH rebalance exists" if unacknowledged.any?
    add_check(:history, "No successful USDC rebalance exists", usdc_successes.empty?, blocker: true, value: usdc_successes.map(&:id).join(", "))
    @alerts << "unexpected successful USDC rebalance exists" if usdc_successes.any?
    add_check(:history, "Acknowledged failed WETH rows", acknowledged.empty?, warning: true, value: acknowledged.map(&:id).join(", "))
  end

  def check_dashboard(position)
    return unless position

    snapshot = position.pnl_snapshots.order(captured_at: :desc, id: :desc).first
    stale = snapshot.nil? || snapshot.captured_at.nil? || snapshot.captured_at < @clock.call - PNL_STALE_AFTER
    add_check(:dashboard, "Latest PnL snapshot fresh", !stale, warning: true, value: snapshot&.captured_at&.iso8601)

    check_rewards if boolean_env("AERODROME_REWARDS_ENABLED") == true
    check_fees if boolean_env("AERODROME_FEES_ENABLED") == true
  end

  def check_rewards
    report = rewards_check.report
    add_check(:dashboard, "Rewards check PASS", report.fetch(:status) == "PASS", warning: true, value: report.fetch(:status))
  rescue => e
    add_check(:dashboard, "Rewards check PASS", false, warning: true, value: e.message)
  end

  def check_fees
    report = fees_check.report
    add_check(:dashboard, "Fees check PASS", report.fetch(:status) == "PASS", warning: true, value: report.fetch(:status))
  rescue => e
    add_check(:dashboard, "Fees check PASS", false, warning: true, value: e.message)
  end

  def check_production_readiness
    report = production_readiness.report
    @readiness_status = report.fetch(:status)
    @readiness_blockers = Array(report.fetch(:blockers, []))
    @readiness_warnings = Array(report.fetch(:warnings, []))
    @readiness_blockers_suppressed_due_approved_open = []

    @checks[:readiness] << { name: "Production readiness status", status: @readiness_status.downcase, value: @readiness_status }
    @checks[:readiness] << { name: "Production readiness blockers", status: @readiness_blockers.empty? ? "pass" : "fail", value: @readiness_blockers }
    @checks[:readiness] << { name: "Production readiness warnings", status: @readiness_warnings.empty? ? "pass" : "warn", value: @readiness_warnings }

    blockers = @readiness_blockers
    if approved_open_monitoring?
      suppressible, blockers = blockers.partition { |message| approved_open_readiness_blocker?(message) }
      @readiness_blockers_suppressed_due_approved_open = suppressible
      if suppressible.any?
        @checks[:readiness] << { name: "Readiness blockers suppressed due approved open", status: "warn", value: suppressible }
        @warnings << "production readiness is strict safe-mode; approved open ETH is monitored by approved-open detector"
      end
    end

    if blockers.empty?
      @checks[:readiness] << { name: "Production readiness unrelated blockers absent", status: "pass" }
    else
      blockers.each do |message|
        add_check(:readiness, "Production readiness blocker", false, blocker: true, value: message)
      end
    end
  end

  def check_logs
    add_check(:logs, "Observation log directory exists", @log_dir.exist?, warning: true, value: @log_dir.to_s)
  end

  def active_aerodrome_position
    dex = Dex.find_by(name: DEX_NAME)
    return nil unless dex

    Position.includes(:pnl_snapshots, :hedge).where(dex: dex, active: true).order(:id).first
  end

  def read_eth_position(label, service)
    service.get_position("ETH")
  rescue => e
    add_check(:hyperliquid, "#{label} ETH position readback", false, blocker: label == :mainnet, warning: label != :mainnet, value: e.message)
    nil
  end

  def mainnet_hyperliquid_service
    @mainnet_hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def testnet_hyperliquid_service
    @testnet_hyperliquid_service ||= HyperliquidService.new(testnet: true)
  end

  def observation_summary
    @observation_summary ||= AerodromeLiveObservationSummary.new(log_dir: @log_dir)
  end

  def production_readiness
    @production_readiness ||= AerodromeProductionSupervisedReadiness.new
  end

  def rewards_check
    @rewards_check ||= AerodromeRewardsCheck.new
  end

  def fees_check
    @fees_check ||= AerodromeFeesCheck.new
  end

  def approved_open_position(mainnet)
    @approved_open_position || AerodromeApprovedOpenPosition.new(current_position: mainnet)
  end

  def approved_open_monitoring?
    @approved_open_position_report&.fetch(:approval_status, nil) == "approved" &&
      @approved_open_position_report&.fetch(:status, nil) == "PASS"
  end

  def approved_open_readiness_blocker?(message)
    message.to_s.include?("Mainnet ETH position is nil")
  end

  def safe_env?
    boolean_env("AERODROME_HEDGE_ENABLED") == false &&
      boolean_env("AERODROME_HEDGE_PAUSED") == true &&
      boolean_env("AERODROME_LIVE_APPROVED") == false &&
      boolean_env("HYPERLIQUID_TESTNET") == true
  end

  def check_boolean(section, key, expected, blocker:)
    add_check(section, "#{key} is #{expected}", boolean_env(key) == expected, blocker: blocker, value: ENV[key].inspect)
  end

  def add_check(section, name, passed, blocker: false, warning: false, value: nil)
    result = { name: name, status: passed ? "pass" : "fail" }
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

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def boolean_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
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

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Stop live operation, inspect blockers, and use manually gated emergency close if ETH remains open." ] if @blockers.any?
    return [ "Review warnings before any further live window." ] if @warnings.any?

    [ "No watchdog blockers. Continue read-only monitoring; this is not live approval." ]
  end
end
