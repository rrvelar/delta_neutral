class AerodromeWatchdogSchedulerCheck
  BANNER = "AERODROME WATCHDOG SCHEDULER CHECK — READ ONLY"

  def initialize(
    mainnet_hyperliquid_service: nil,
    observation_summary: nil
  )
    @mainnet_hyperliquid_service = mainnet_hyperliquid_service
    @observation_summary = observation_summary
    @checks = { tasks: [], alerts_env: [], safe_env: [], hyperliquid: [], observation: [] }
    @blockers = []
    @warnings = []
  end

  def report
    check_tasks
    check_alerts_env
    check_safe_env
    check_mainnet_eth
    check_observation

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

  def check_tasks
    add_check(:tasks, "aerodrome:watchdog_alerts task exists", task_defined?("aerodrome:watchdog_alerts"), blocker: true)
    add_check(:tasks, "aerodrome:production_supervised_readiness task exists", task_defined?("aerodrome:production_supervised_readiness"), blocker: true)
  end

  def check_alerts_env
    delivery = ENV["AERODROME_ALERTS_DELIVERY"].presence || "dry_run"
    recipient = ENV["AERODROME_ALERT_EMAIL_RECIPIENT"].presence
    add_check(:alerts_env, "AERODROME_ALERTS_ENABLED", true, value: ENV["AERODROME_ALERTS_ENABLED"].inspect)
    add_check(:alerts_env, "AERODROME_ALERTS_DELIVERY", true, value: delivery)
    add_check(:alerts_env, "AERODROME_ALERT_EMAIL_RECIPIENT", true, value: redacted_recipient(recipient))
    add_check(:alerts_env, "AERODROME_ALERT_EMAIL_MIN_SEVERITY", true, value: ENV["AERODROME_ALERT_EMAIL_MIN_SEVERITY"].presence || "warn")
    if delivery == "email" && recipient.blank?
      add_check(:alerts_env, "Email delivery recipient configured", false, warning: true)
    end
  end

  def check_safe_env
    check_boolean(:safe_env, "AERODROME_HEDGE_ENABLED", false)
    check_boolean(:safe_env, "AERODROME_HEDGE_PAUSED", true)
    check_boolean(:safe_env, "AERODROME_LIVE_APPROVED", false)
    check_boolean(:safe_env, "HYPERLIQUID_TESTNET", true)
  end

  def check_mainnet_eth
    position = mainnet_hyperliquid_service.get_position("ETH")
    add_check(:hyperliquid, "Mainnet ETH position nil", short_size(position).zero?, blocker: true, value: short_size(position).to_s("F"))
  rescue => e
    add_check(:hyperliquid, "Mainnet ETH position readback", false, blocker: true, value: e.message)
  end

  def check_observation
    summary = observation_summary.report
    add_check(:observation, "Latest observation summary PASS", summary.fetch(:status) == "PASS", warning: true, value: summary.fetch(:status))
    add_check(:observation, "Latest observation final position nil", summary.fetch(:final_position).nil?, blocker: true, value: summary.fetch(:final_position).inspect)
    add_check(:observation, "Latest observation manual_action_required false", summary.fetch(:manual_action_required) == false, blocker: true, value: summary.fetch(:manual_action_required).inspect)
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

  def task_defined?(name)
    return true if Rake::Task.task_defined?(name)
    return true if name == "aerodrome:watchdog_alerts" && defined?(AerodromeWatchdogAlerts).present?
    return true if name == "aerodrome:production_supervised_readiness" && defined?(AerodromeProductionSupervisedReadiness).present?

    false
  rescue
    false
  end

  def mainnet_hyperliquid_service
    @mainnet_hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def observation_summary
    @observation_summary ||= AerodromeLiveObservationSummary.new
  end

  def boolean_env(key)
    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def redacted_recipient(value)
    return nil unless value

    local, domain = value.split("@", 2)
    return "[redacted]" unless domain

    "#{local.first}***@#{domain}"
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Do not rely on scheduled watchdog alerts until blockers are resolved." ] if @blockers.any?
    return [ "Review scheduler warnings before enabling email delivery." ] if @warnings.any?

    [ "Scheduler foundation is ready for read-only watchdog alert ticks. This is not live approval." ]
  end
end
