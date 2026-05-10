class AerodromeWatchdogAlerts
  BANNER = "AERODROME WATCHDOG ALERTS — READ ONLY"
  SEVERITY_ORDER = { "pass" => 0, "warn" => 1, "blocked" => 2 }.freeze

  def initialize(watchdog_check: nil, clock: -> { Time.current })
    @watchdog_check = watchdog_check
    @clock = clock
  end

  def report
    watchdog = watchdog_report
    severity = severity_for(watchdog)
    alert = {
      safety_banner: BANNER,
      status: watchdog.fetch(:status),
      severity: severity,
      title: title_for(severity),
      summary: summary_for(watchdog),
      body: body_for(watchdog),
      blockers: watchdog.fetch(:blockers),
      warnings: watchdog.fetch(:warnings),
      recommended_actions: recommended_actions(watchdog),
      timestamp: @clock.call.iso8601,
      git_sha: git_sha,
      safe_env: safe_env,
      latest_observation_summary: latest_observation_summary(watchdog),
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false
    }
    delivery = deliver_alert(alert)
    alert[:delivery] = delivery
    alert[:sent] = delivery.fetch(:sent)
    alert[:recipient] = delivery.fetch(:recipient)
    alert[:skipped_reason] = delivery.fetch(:skipped_reason)
    alert
  end

  private

  def watchdog_report
    @watchdog_report ||= watchdog_check.report
  end

  def watchdog_check
    @watchdog_check ||= AerodromeWatchdogCheck.new
  end

  def severity_for(watchdog)
    return "blocked" if watchdog.fetch(:status) == "BLOCKED" || watchdog.fetch(:blockers).any?
    return "warn" if watchdog.fetch(:status) == "WARN" || watchdog.fetch(:warnings).any?

    "pass"
  end

  def title_for(severity)
    case severity
    when "blocked" then "Aerodrome watchdog BLOCKED"
    when "warn" then "Aerodrome watchdog warning"
    else "Aerodrome watchdog PASS"
    end
  end

  def summary_for(watchdog)
    [
      "status=#{watchdog.fetch(:status)}",
      "alerts=#{watchdog.fetch(:alerts).size}",
      "blockers=#{watchdog.fetch(:blockers).size}",
      "warnings=#{watchdog.fetch(:warnings).size}"
    ].join(", ")
  end

  def body_for(watchdog)
    [
      "Watchdog status: #{watchdog.fetch(:status)}",
      "Alerts:",
      list_or_none(watchdog.fetch(:alerts)),
      "Blockers:",
      list_or_none(watchdog.fetch(:blockers)),
      "Warnings:",
      list_or_none(watchdog.fetch(:warnings)),
      "Recommended actions:",
      list_or_none(recommended_actions(watchdog))
    ].join("\n")
  end

  def recommended_actions(watchdog)
    messages = watchdog.fetch(:blockers) + watchdog.fetch(:alerts) + watchdog.fetch(:warnings)
    actions = messages.flat_map { |message| actions_for(message) }.uniq
    return [ "Continue read-only monitoring. This is not live approval." ] if actions.empty?

    actions
  end

  def actions_for(message)
    text = message.to_s.downcase
    actions = []
    if text.include?("mainnet eth position")
      actions << "Mainnet ETH is open while safe env is expected: run live emergency close or close manually in Hyperliquid UI."
    end
    if text.include?("manual_action_required")
      actions << "Inspect the latest observation log and run emergency close/readback before any further live window."
    end
    if text.include?("final position")
      actions << "Latest observation final position is not nil: run emergency close and verify mainnet ETH nil."
    end
    if text.include?("unacknowledged failed weth")
      actions << "Inspect failed WETH rebalance; acknowledge only if it is a reviewed zero-size no-position case."
    end
    if text.include?("usdc")
      actions << "Successful USDC rebalance is unexpected: stop immediately and investigate before any live window."
    end
    if text.include?("pnl snapshot")
      actions << "PnL snapshot is stale: run or restore position sync before relying on dashboard state."
    end
    if text.include?("rewards")
      actions << "Rewards unavailable: check rewards configuration/RPC; rewards remain read-only."
    end
    if text.include?("fees")
      actions << "Fees unavailable: staked NFT fee reads may be a known limitation; do not treat unavailable fees as realized PnL."
    end
    if text.include?("acknowledged failed weth")
      actions << "Acknowledged failed WETH is historical warning only; confirm it remains reviewed."
    end
    actions
  end

  def list_or_none(values)
    return "  none" if values.empty?

    values.map { |value| "  - #{value}" }.join("\n")
  end

  def deliver_alert(alert)
    result = delivery_config
    return result.merge(sent: false, skipped_reason: "delivery mode dry_run") if result.fetch(:mode) == "dry_run"
    return result.merge(sent: false, skipped_reason: "unsupported delivery mode") unless result.fetch(:mode) == "email"
    return result.merge(sent: false, skipped_reason: "alerts disabled") unless result.fetch(:enabled)
    unless recipient.present?
      return result.merge(sent: false, skipped_reason: "missing AERODROME_ALERT_EMAIL_RECIPIENT")
    end

    unless severity_allowed?(alert.fetch(:severity), result.fetch(:min_severity))
      return result.merge(sent: false, skipped_reason: "severity below #{result.fetch(:min_severity)}")
    end

    AerodromeWatchdogMailer.watchdog_alert(recipient: recipient, alert: alert).deliver_now
    result.merge(sent: true, skipped_reason: nil)
  rescue => e
    result.merge(sent: false, skipped_reason: "email delivery failed: #{e.class}: #{e.message}")
  end

  def delivery_config
    {
      enabled: ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_ALERTS_ENABLED"]) == true,
      mode: ENV["AERODROME_ALERTS_DELIVERY"].presence || "dry_run",
      recipient: redacted_recipient,
      min_severity: min_severity
    }
  end

  def severity_allowed?(severity, minimum)
    SEVERITY_ORDER.fetch(severity) >= SEVERITY_ORDER.fetch(minimum)
  end

  def min_severity
    value = ENV["AERODROME_ALERT_EMAIL_MIN_SEVERITY"].presence || "warn"
    SEVERITY_ORDER.key?(value) ? value : "warn"
  end

  def recipient
    ENV["AERODROME_ALERT_EMAIL_RECIPIENT"].presence
  end

  def redacted_recipient
    value = recipient
    return nil unless value

    local, domain = value.split("@", 2)
    return "[redacted]" unless domain

    "#{local.first}***@#{domain}"
  end

  def safe_env
    %w[
      AERODROME_HEDGE_ENABLED
      AERODROME_HEDGE_PAUSED
      AERODROME_LIVE_APPROVED
      HYPERLIQUID_TESTNET
    ].to_h { |key| [ key, ENV[key] ] }
  end

  def latest_observation_summary(watchdog)
    watchdog.fetch(:checks).fetch(:observation, [])
  end

  def git_sha
    ENV["APP_GIT_SHA"].presence
  end
end
