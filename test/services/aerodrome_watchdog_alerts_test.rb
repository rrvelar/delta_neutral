require "test_helper"

class AerodromeWatchdogAlertsTest < ActiveSupport::TestCase
  test "dry-run output for pass" do
    with_env("AERODROME_ALERTS_ENABLED" => "false", "AERODROME_ALERTS_DELIVERY" => "dry_run", "APP_GIT_SHA" => "abc123") do
      report = build_service(watchdog: WatchdogReport.new(status: "PASS")).report

      assert_equal "pass", report.fetch(:severity)
      assert_equal "Aerodrome watchdog PASS", report.fetch(:title)
      assert_equal "dry_run", report.dig(:delivery, :mode)
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
      assert_equal "abc123", report.fetch(:git_sha)
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

    assert_equal({ enabled: false, mode: "dry_run" }, report.fetch(:delivery))
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
        checks: {},
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

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
