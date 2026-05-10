require "test_helper"

class AerodromeWatchdogSchedulerCheckTest < ActiveSupport::TestCase
  test "dry run pass with safe env and nil mainnet ETH" do
    with_safe_env("AERODROME_ALERTS_DELIVERY" => "dry_run") do
      report = build_service.report

      assert_equal "PASS", report.fetch(:status)
      assert_empty report.fetch(:blockers)
      assert_empty report.fetch(:warnings)
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "watchdog tick script exists and is executable" do
    path = Rails.root.join("bin", "aerodrome-watchdog-tick")

    assert_predicate path, :exist?
    assert_predicate path, :executable?
    assert_includes path.read, "bin/rails aerodrome:watchdog_alerts"
  end

  test "email mode missing recipient is warning" do
    with_safe_env("AERODROME_ALERTS_DELIVERY" => "email", "AERODROME_ALERT_EMAIL_RECIPIENT" => nil) do
      report = build_service.report

      assert_equal "WARN", report.fetch(:status)
      assert_includes report.fetch(:warnings), "Email delivery recipient configured"
    end
  end

  test "unsafe env is blocked" do
    with_safe_env("AERODROME_HEDGE_ENABLED" => "true") do
      report = build_service.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), 'AERODROME_HEDGE_ENABLED is false: "true"'
    end
  end

  test "mainnet ETH open is blocked" do
    with_safe_env do
      report = build_service(mainnet_position: { size: "-0.011" }).report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "Mainnet ETH position nil: 0.011"
    end
  end

  test "latest observation final position blocks" do
    with_safe_env do
      report = build_service(observation: observation_report(final_position: { "size" => "-0.011" })).report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), 'Latest observation final position nil: {"size" => "-0.011"}'
    end
  end

  test "JSON output is valid shape" do
    with_safe_env do
      report = build_service.report
      json = JSON.parse(JSON.generate(report))

      assert_equal "PASS", json.fetch("status")
      assert_equal false, json.fetch("database_write")
      assert json.fetch("checks").key?("alerts_env")
    end
  end

  test "does not write to the database" do
    with_safe_env do
      writes = capture_write_sql { build_service.report }

      assert_empty writes
    end
  end

  test "does not call Hyperliquid execution methods" do
    service = HyperliquidReadOnly.new(nil)

    with_safe_env do
      AerodromeWatchdogSchedulerCheck.new(
        mainnet_hyperliquid_service: service,
        observation_summary: ObservationSummary.new(observation_report)
      ).report
    end

    assert_equal [ :get_position ], service.calls
  end

  private

  class HyperliquidReadOnly
    attr_reader :calls

    def initialize(position)
      @position = position
      @calls = []
    end

    def get_position(asset)
      raise "unexpected asset" unless asset == "ETH"

      @calls << :get_position
      @position
    end

    def open_short(*)
      @calls << :open_short
    end

    def close_short(*)
      @calls << :close_short
    end

    def set_leverage(*)
      @calls << :set_leverage
    end
  end

  class ObservationSummary
    def initialize(report)
      @report = report
    end

    def report
      @report
    end
  end

  def build_service(mainnet_position: nil, observation: observation_report)
    AerodromeWatchdogSchedulerCheck.new(
      mainnet_hyperliquid_service: HyperliquidReadOnly.new(mainnet_position),
      observation_summary: ObservationSummary.new(observation)
    )
  end

  def observation_report(final_position: nil, manual_action_required: false, status: "PASS")
    {
      status: status,
      final_position: final_position,
      manual_action_required: manual_action_required
    }
  end

  def with_safe_env(overrides = {})
    values = {
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true",
      "AERODROME_ALERTS_ENABLED" => "false",
      "AERODROME_ALERTS_DELIVERY" => "dry_run",
      "AERODROME_ALERT_EMAIL_RECIPIENT" => "operator@example.com",
      "AERODROME_ALERT_EMAIL_MIN_SEVERITY" => "warn"
    }.merge(overrides)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
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
end
