require "digest"
require "fileutils"

class AerodromeWatchdogAlertState
  DEFAULT_PATH = Rails.root.join("storage", "aerodrome_watchdog_alerts", "state.json")

  def initialize(path: DEFAULT_PATH, clock: -> { Time.current })
    @path = Pathname(path)
    @clock = clock
  end

  def self.fingerprint(alert)
    payload = {
      severity: alert.fetch(:severity),
      blockers: alert.fetch(:blockers),
      warnings: alert.fetch(:warnings),
      alerts: alert.fetch(:watchdog_alerts, []),
      recommended_actions: alert.fetch(:recommended_actions),
      latest_observation_summary: alert.fetch(:latest_observation_summary)
    }
    Digest::SHA256.hexdigest(JSON.generate(payload))
  end

  def evaluate(alert:, cooldown_seconds:, blocked_repeat_seconds:)
    fingerprint = self.class.fingerprint(alert)
    current = read
    changed = current.fetch("last_fingerprint", nil) != fingerprint
    escalated = severity_value(alert.fetch(:severity)) > severity_value(current.fetch("last_severity", nil))
    repeat_after = alert.fetch(:severity) == "blocked" ? blocked_repeat_seconds : cooldown_seconds
    last_sent_at = parse_time(current.fetch("last_sent_at", nil))
    cooldown_elapsed = last_sent_at.nil? || @clock.call >= last_sent_at + repeat_after
    allowed = changed || escalated || cooldown_elapsed

    {
      fingerprint: fingerprint,
      fingerprint_changed: changed,
      severity_escalated: escalated,
      cooldown_seconds: repeat_after,
      last_sent_at: last_sent_at&.iso8601,
      send_allowed: allowed,
      skipped_reason: allowed ? nil : "suppressed by alert cooldown"
    }
  end

  def record_sent(alert:, fingerprint:)
    FileUtils.mkdir_p(@path.dirname)
    data = {
      last_fingerprint: fingerprint,
      last_severity: alert.fetch(:severity),
      last_sent_at: @clock.call.iso8601,
      last_title: alert.fetch(:title),
      last_summary: alert.fetch(:summary)
    }
    @path.write(JSON.pretty_generate(data))
  end

  private

  def read
    return {} unless @path.exist?

    JSON.parse(@path.read)
  rescue JSON::ParserError
    {}
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def severity_value(value)
    AerodromeWatchdogAlerts::SEVERITY_ORDER.fetch(value, -1)
  end
end
