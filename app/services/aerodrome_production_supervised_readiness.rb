require "open3"

class AerodromeProductionSupervisedReadiness
  BANNER = "AERODROME PRODUCTION SUPERVISED READINESS — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(
    mainnet_hyperliquid_service: nil,
    testnet_hyperliquid_service: nil,
    rewards_check: nil,
    fees_check: nil,
    observation_summary: nil,
    log_dir: Rails.root.join("storage", "aerodrome_live_observation")
  )
    @mainnet_hyperliquid_service = mainnet_hyperliquid_service
    @testnet_hyperliquid_service = testnet_hyperliquid_service
    @rewards_check = rewards_check
    @fees_check = fees_check
    @observation_summary = observation_summary
    @log_dir = Pathname(log_dir)
    @checks = {
      git: [],
      env: [],
      preflight: [],
      emergency_close: [],
      history: [],
      hyperliquid_readback: [],
      dashboard: [],
      logs: []
    }
    @blockers = []
    @warnings = []
  end

  def report
    add_git_and_runtime
    check_safe_env
    position = active_aerodrome_position
    check_preflight_context(position)
    check_emergency_close_gates
    check_history(position)
    check_hyperliquid_readback
    check_dashboard(position)
    summary = check_logs

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      git_sha: git_sha,
      git_sha_source: git_sha_source,
      rails_env: Rails.env,
      safe_env: safe_env,
      checks: @checks,
      observation_summary: summary,
      backup_path_suggestion: "storage/backups",
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  private

  def add_git_and_runtime
    add_check(:git, "Git SHA available", git_sha.present?, warning: true, value: git_sha || "unavailable")
    add_check(:git, "Git SHA source", true, value: git_sha_source)
    add_check(:git, "Rails env", true, value: Rails.env)
  end

  def check_safe_env
    check_boolean(:env, "AERODROME_HEDGE_ENABLED", false, blocker: true)
    check_boolean(:env, "AERODROME_HEDGE_PAUSED", true, blocker: true)
    check_boolean(:env, "AERODROME_LIVE_APPROVED", false, blocker: true)
    check_boolean(:env, "HYPERLIQUID_TESTNET", true, blocker: true)
  end

  def active_aerodrome_position
    dex = Dex.find_by(name: DEX_NAME)
    add_check(:dashboard, "Aerodrome dex exists", dex.present?, blocker: true)
    return nil unless dex

    position = Position.includes(:wallet, :pnl_snapshots, :hedge).where(dex: dex, active: true).order(:id).first
    add_check(:dashboard, "Active Aerodrome position exists", position.present?, blocker: true)
    position
  end

  def check_preflight_context(position)
    add_check(:preflight, "Live preflight service exists", defined?(AerodromeLivePreflightCheck).present?, blocker: true)
    add_check(:preflight, "Production supervised readiness is read-only", true, value: "no DB writes, no orders")
    return unless position

    hedge = position.hedge
    add_check(:preflight, "Explicit Aerodrome hedge exists", hedge.present?, blocker: true)
    add_check(:preflight, "Aerodrome hedge active", hedge&.active? == true, blocker: true) if hedge
    add_check(:preflight, "Position has persisted USD prices", position.asset0_price_usd.present? && position.asset1_price_usd.present?, blocker: true)
  end

  def check_emergency_close_gates
    enabled = boolean_env("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED")
    confirm_ok = ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION
    max_close = decimal_env("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
    add_check(:emergency_close, "Live emergency close task exists", defined?(AerodromeLiveEmergencyClose).present?, blocker: true)
    add_check(:emergency_close, "Emergency close enabled gate currently false/missing as safe default", enabled != true, warning: false, value: ENV["AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED"].inspect)
    add_check(:emergency_close, "Emergency close confirmation not persistently armed", !confirm_ok, warning: true, value: confirm_ok.to_s)
    add_check(:emergency_close, "Emergency close max ETH configured for future run", max_close.present?, warning: true, value: ENV["AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"].inspect)
  end

  def check_history(position)
    return unless position&.hedge

    rebalances = position.hedge.short_rebalances.order(rebalanced_at: :desc, id: :desc).to_a
    latest_success = rebalances.find { |rebalance| weth_rebalance?(rebalance) && success?(rebalance) }
    failed_weth = rebalances.select { |rebalance| weth_rebalance?(rebalance) && failed?(rebalance) }
    unacknowledged = failed_weth.reject { |rebalance| acknowledged_zero_size_failure?(rebalance) }

    add_check(:history, "Latest WETH success exists", latest_success.present?, blocker: true, value: latest_success&.id)
    add_check(:history, "No unacknowledged failed WETH rebalances", unacknowledged.empty?, blocker: true, value: unacknowledged.map(&:id).join(", "))
    @checks[:history] << {
      name: "Latest failed WETH rows",
      status: failed_weth.empty? ? "pass" : "warn",
      value: failed_weth.first(5).map { |rebalance| failure_summary(rebalance) }
    }
  end

  def check_hyperliquid_readback
    mainnet = read_eth_position(:mainnet, mainnet_hyperliquid_service)
    add_check(
      :hyperliquid_readback,
      "Mainnet ETH position is nil",
      short_size(mainnet).zero?,
      blocker: true,
      value: short_size(mainnet).to_s("F")
    )

    testnet = read_eth_position(:testnet, testnet_hyperliquid_service)
    add_check(
      :hyperliquid_readback,
      "Testnet ETH position is nil",
      short_size(testnet).zero?,
      warning: true,
      value: short_size(testnet).to_s("F")
    )
  end

  def check_dashboard(position)
    return unless position

    latest_snapshot = position.pnl_snapshots.order(captured_at: :desc, id: :desc).first
    add_check(:dashboard, "Latest PnL snapshot exists", latest_snapshot.present?, warning: true, value: latest_snapshot&.captured_at&.iso8601)
    check_rewards if boolean_env("AERODROME_REWARDS_ENABLED") == true
    check_fees if boolean_env("AERODROME_FEES_ENABLED") == true
  end

  def check_rewards
    report = rewards_check.report
    add_check(:dashboard, "AERO rewards check status", report.fetch(:status) != "BLOCKED", warning: true, value: report.fetch(:status))
  rescue => e
    add_check(:dashboard, "AERO rewards check status", false, warning: true, value: e.message)
  end

  def check_fees
    report = fees_check.report
    add_check(:dashboard, "Aerodrome fees check status", report.fetch(:status) != "BLOCKED", warning: true, value: report.fetch(:status))
  rescue => e
    add_check(:dashboard, "Aerodrome fees check status", false, warning: true, value: e.message)
  end

  def check_logs
    add_check(:logs, "Observation log directory exists", @log_dir.exist?, warning: true, value: @log_dir.to_s)
    summary = observation_summary.report
    add_check(:logs, "Latest observation final position nil", summary.fetch(:final_position).nil?, blocker: true, value: summary.fetch(:log_path))
    add_check(:logs, "Latest observation manual_action_required false", summary.fetch(:manual_action_required) == false, blocker: true, value: summary.fetch(:manual_action_required).inspect)
    summary
  end

  def read_eth_position(label, service)
    position = service.get_position("ETH")
    @checks[:hyperliquid_readback] << {
      name: "#{label} get_position(\"ETH\") read-only",
      status: "pass",
      value: position ? short_size(position).to_s("F") : "0"
    }
    position
  rescue => e
    add_check(:hyperliquid_readback, "#{label} ETH position readback", false, blocker: label == :mainnet, warning: label != :mainnet, value: e.message)
    nil
  end

  def mainnet_hyperliquid_service
    @mainnet_hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def testnet_hyperliquid_service
    @testnet_hyperliquid_service ||= HyperliquidService.new(testnet: true)
  end

  def rewards_check
    @rewards_check ||= AerodromeRewardsCheck.new
  end

  def fees_check
    @fees_check ||= AerodromeFeesCheck.new
  end

  def observation_summary
    @observation_summary ||= AerodromeLiveObservationSummary.new(log_dir: @log_dir)
  end

  def safe_env
    %w[
      AERODROME_HEDGE_ENABLED
      AERODROME_HEDGE_PAUSED
      AERODROME_LIVE_APPROVED
      HYPERLIQUID_TESTNET
    ].to_h { |key| [ key, ENV[key] ] }
  end

  def git_sha
    @git_sha ||= begin
      sha, = git_sha_with_source
      sha
    end
  end

  def git_sha_source
    @git_sha_source ||= begin
      _, source = git_sha_with_source
      source
    end
  end

  def git_sha_with_source
    return [ @git_sha_value, @git_sha_source_value ] if defined?(@git_sha_value)

    env_sha = ENV["APP_GIT_SHA"].presence
    if env_sha
      @git_sha_value = env_sha
      @git_sha_source_value = "env"
      return [ @git_sha_value, @git_sha_source_value ]
    end

    git_sha = git_command_sha
    if git_sha
      @git_sha_value = git_sha
      @git_sha_source_value = "git"
      return [ @git_sha_value, @git_sha_source_value ]
    end

    @git_sha_value = nil
    @git_sha_source_value = "unavailable"
    [ @git_sha_value, @git_sha_source_value ]
  end

  def git_command_sha
    stdout, _stderr, status = Open3.capture3("git", "rev-parse", "--short", "HEAD", chdir: Rails.root.to_s)
    return nil unless status.success?

    stdout.strip.presence
  rescue Errno::ENOENT
    nil
  end

  def check_boolean(section, key, expected, blocker:)
    actual = boolean_env(key)
    add_check(section, "#{key} is #{expected}", actual == expected, blocker: blocker, value: ENV[key].inspect)
  end

  def add_check(section, name, passed, blocker: false, warning: false, value: nil)
    result = { name: name, status: passed ? "pass" : "fail" }
    result[:value] = value unless value.nil?
    @checks.fetch(section) << result
    return if passed

    message = value.nil? ? name : "#{name}: #{value}"
    blocker ? @blockers << message : (@warnings << message if warning)
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

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
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

  def failure_summary(rebalance)
    {
      id: rebalance.id,
      status: rebalance.status,
      acknowledged: acknowledged_zero_size_failure?(rebalance),
      rebalanced_at: rebalance.rebalanced_at&.iso8601
    }
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Resolve blockers before any production supervised run." ] if @blockers.any?
    return [ "Review warnings, rerun readiness, and verify emergency close plan before production supervised mode." ] if @warnings.any?

    [ "PASS is readiness evidence only. Production supervised mode still requires manual approval, active monitoring, and emergency close readiness." ]
  end
end
