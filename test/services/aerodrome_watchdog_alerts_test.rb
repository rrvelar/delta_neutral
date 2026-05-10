require "test_helper"

class AerodromeWatchdogAlertsTest < ActiveSupport::TestCase
  setup do
    ActionMailer::Base.deliveries.clear
  end

  test "dry-run output for pass" do
    with_env("AERODROME_ALERTS_ENABLED" => "false", "AERODROME_ALERTS_DELIVERY" => "dry_run", "APP_GIT_SHA" => "abc123") do
      report = build_service(watchdog: WatchdogReport.new(status: "PASS")).report

      assert_equal "pass", report.fetch(:severity)
      assert_equal "Aerodrome watchdog PASS", report.fetch(:title)
      assert_equal "dry_run", report.dig(:delivery, :mode)
      assert_equal false, report.dig(:delivery, :sent)
      assert_equal false, report.fetch(:sent)
      assert_equal "delivery mode dry_run", report.dig(:delivery, :skipped_reason)
      assert_equal "delivery mode dry_run", report.fetch(:skipped_reason)
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal "abc123", report.fetch(:git_sha)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "warning output when watchdog returns warnings" do
    report = build_service(watchdog: WatchdogReport.new(status: "WARN", warnings: [ "Latest PnL snapshot fresh" ])).report

    assert_equal "warn", report.fetch(:severity)
    assert_equal "Aerodrome watchdog warning", report.fetch(:title)
    assert_includes report.fetch(:recommended_actions), "PnL snapshot is stale: run or restore position sync before relying on dashboard state."
  end

  test "blocked output when watchdog returns blockers" do
    report = build_service(watchdog: WatchdogReport.new(status: "BLOCKED", blockers: [ "Mainnet ETH position is nil: 0.011" ])).report

    assert_equal "blocked", report.fetch(:severity)
    assert_equal "Aerodrome watchdog BLOCKED", report.fetch(:title)
    assert_includes report.fetch(:recommended_actions), "Mainnet ETH is open while safe env is expected: run live emergency close or close manually in Hyperliquid UI."
  end

  test "recommended action for manual action required" do
    report = build_service(watchdog: WatchdogReport.new(status: "BLOCKED", alerts: [ "latest observation manual_action_required=true" ])).report

    assert_includes report.fetch(:recommended_actions), "Inspect the latest observation log and run emergency close/readback before any further live window."
  end

  test "does not send real notifications" do
    report = build_service(watchdog: WatchdogReport.new(status: "PASS")).report

    assert_equal false, report.dig(:delivery, :sent)
    assert_empty ActionMailer::Base.deliveries
  end

  test "email disabled does not send" do
    with_env(email_env("AERODROME_ALERTS_ENABLED" => "false")) do
      report = build_service(watchdog: WatchdogReport.new(status: "WARN", warnings: [ "Latest PnL snapshot fresh" ])).report

      assert_equal false, report.dig(:delivery, :sent)
      assert_equal "alerts disabled", report.dig(:delivery, :skipped_reason)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "email delivery missing recipient does not send" do
    with_env(email_env("AERODROME_ALERT_EMAIL_RECIPIENT" => nil)) do
      report = build_service(watchdog: WatchdogReport.new(status: "WARN", warnings: [ "Latest PnL snapshot fresh" ])).report

      assert_equal false, report.dig(:delivery, :sent)
      assert_equal "missing AERODROME_ALERT_EMAIL_RECIPIENT", report.dig(:delivery, :skipped_reason)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "severity pass with min severity warn does not send" do
    with_env(email_env) do
      report = build_service(watchdog: WatchdogReport.new(status: "PASS")).report

      assert_equal false, report.dig(:delivery, :sent)
      assert_equal "severity below warn", report.dig(:delivery, :skipped_reason)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "severity warn sends when enabled email and recipient present" do
    with_env(email_env) do
      report = build_service(watchdog: WatchdogReport.new(status: "WARN", warnings: [ "Latest PnL snapshot fresh" ])).report

      assert_equal true, report.dig(:delivery, :sent)
      assert_equal true, report.fetch(:sent)
      assert_nil report.dig(:delivery, :skipped_reason)
      assert_nil report.fetch(:skipped_reason)
      assert_equal "o***@example.com", report.dig(:delivery, :recipient)
      assert_equal "o***@example.com", report.fetch(:recipient)
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end

  test "severity blocked sends when enabled email and recipient present" do
    with_env(email_env) do
      report = build_service(watchdog: WatchdogReport.new(status: "BLOCKED", blockers: [ "mainnet ETH position exists" ])).report

      assert_equal true, report.dig(:delivery, :sent)
      assert_equal 1, ActionMailer::Base.deliveries.size
    end
  end

  test "min severity blocked suppresses warn" do
    with_env(email_env("AERODROME_ALERT_EMAIL_MIN_SEVERITY" => "blocked")) do
      report = build_service(watchdog: WatchdogReport.new(status: "WARN", warnings: [ "Latest PnL snapshot fresh" ])).report

      assert_equal false, report.dig(:delivery, :sent)
      assert_equal "severity below blocked", report.dig(:delivery, :skipped_reason)
      assert_empty ActionMailer::Base.deliveries
    end
  end

  test "mail subject and body include alert details" do
    with_env(email_env("APP_GIT_SHA" => "abc123")) do
      build_service(
        watchdog: WatchdogReport.new(
          status: "BLOCKED",
          alerts: [ "latest observation manual_action_required=true" ],
          warnings: [ "Latest PnL snapshot fresh" ],
          blockers: [ "mainnet ETH position exists" ]
        )
      ).report

      email = ActionMailer::Base.deliveries.last
      body = email.body.encoded
      assert_match "[Aerodrome BLOCKED] Aerodrome watchdog BLOCKED", email.subject
      assert_match "Severity: blocked", body
      assert_match "mainnet ETH position exists", body
      assert_match "Latest PnL snapshot fresh", body
      assert_match "Inspect the latest observation log", body
      assert_match "Git SHA: abc123", body
      assert_match "This alert is read-only. It did not close or open positions.", body
    end
  end

  test "does not write to the database" do
    with_env("AERODROME_ALERTS_DELIVERY" => "dry_run") do
      writes = capture_write_sql do
        build_service(watchdog: WatchdogReport.new(status: "PASS")).report
      end

      assert_empty writes
    end
  end

  test "does not call Hyperliquid execution methods" do
    watchdog = WatchdogReport.new(status: "PASS")

    build_service(watchdog: watchdog).report

    assert_empty watchdog.order_calls
  end

  private

  class WatchdogReport
    attr_reader :order_calls

    def initialize(status:, alerts: [], warnings: [], blockers: [])
      @status = status
      @alerts = alerts
      @warnings = warnings
      @blockers = blockers
      @order_calls = []
    end

    def report
      {
        safety_banner: AerodromeWatchdogCheck::BANNER,
        status: @status,
        database_write: false,
        orders_enabled: false,
        hyperliquid_execution: false,
        alerts: @alerts,
        warnings: @warnings,
        blockers: @blockers,
        checks: {
          observation: [
            { name: "Latest observation final position nil", status: "pass" }
          ]
        },
        next_steps: []
      }
    end

    def open_short(*)
      @order_calls << :open_short
    end

    def close_short(*)
      @order_calls << :close_short
    end

    def set_leverage(*)
      @order_calls << :set_leverage
    end
  end

  def build_service(watchdog:)
    AerodromeWatchdogAlerts.new(watchdog_check: watchdog, clock: -> { Time.zone.local(2026, 5, 10, 12, 0, 0) })
  end

  def email_env(overrides = {})
    {
      "AERODROME_ALERTS_ENABLED" => "true",
      "AERODROME_ALERTS_DELIVERY" => "email",
      "AERODROME_ALERT_EMAIL_RECIPIENT" => "operator@example.com",
      "AERODROME_ALERT_EMAIL_MIN_SEVERITY" => "warn"
    }.merge(overrides)
  end

  def capture_write_sql
    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      sql = payload.fetch(:sql)
      writes << sql if sql.match?(/\A\s*(INSERT|UPDATE|DELETE|CREATE|DROP|ALTER)\b/i)
    end
    yield
    writes
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
