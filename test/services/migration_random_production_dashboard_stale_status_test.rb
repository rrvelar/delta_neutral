require "test_helper"

# 2026-07-12 dashboard staleness fix: a stale stopped-runner status file must
# never override fresh authoritative state in the Production Control Center.
class MigrationRandomProductionDashboardStaleStatusTest < ActiveSupport::TestCase
  class FakeRunner
    attr_reader :refresh_calls

    def initialize(active: false, fresh_payload: nil, fail_refresh: false, status_path: nil)
      @active = active
      @fresh_payload = fresh_payload
      @fail_refresh = fail_refresh
      @status_path = status_path
      @refresh_calls = 0
    end

    def process_active? = @active

    def refresh_status_file!
      @refresh_calls += 1
      return { refreshed: false, reason: "boom" } if @fail_refresh

      File.write(@status_path, JSON.pretty_generate(@fresh_payload))
      { refreshed: true, status: @fresh_payload["status"], blockers: @fresh_payload["blockers"] }
    end
  end

  STALE_PAYLOAD = {
    "runner" => "random_production_runner", "status" => "stopped",
    "updated_at" => "2026-07-11T16:39:00Z",
    "blockers" => [ "all enabled route proofs must be READY_FOR_RANDOM" ],
    "current_production_venue" => "nado",
    "direct_venue_shorts" => { "nado" => "1.607", "ethereal" => "0.0", "extended" => "0.0" },
    "inside_tolerance" => true, "current_direct_market_safe" => false
  }.freeze

  def fresh_payload
    {
      "runner" => "random_production_runner", "status" => "stopped",
      "updated_at" => Time.current.utc.iso8601,
      "blockers" => [],
      "current_production_venue" => "ethereal",
      "direct_venue_shorts" => { "nado" => "0.0", "ethereal" => "1.61", "extended" => "0.0" },
      "inside_tolerance" => true, "current_direct_market_safe" => true
    }
  end

  def build(stale: true, runner: nil)
    dir = Rails.root.join("tmp/prod-dash-stale-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(dir)
    position = guard_position
    status_path = dir.join("random_production_status_position_#{position.id}.json")
    payload = stale ? STALE_PAYLOAD : fresh_payload
    File.write(status_path, JSON.pretty_generate(payload))
    # match the dashboard's status_path naming by pointing log_dir at our dir
    actual_path = MigrationRandomProductionDashboard.new(position: position, log_dir: dir).send(:status_path)
    File.write(actual_path, JSON.pretty_generate(payload))
    runner ||= FakeRunner.new(fresh_payload: fresh_payload, status_path: actual_path)
    runner.instance_variable_set(:@status_path, actual_path)
    [ MigrationRandomProductionDashboard.new(position: position, log_dir: dir, runner_factory: ->(position:) { runner }), runner ]
  end

  test "stale file with fresh backend PASS auto-refreshes and shows fresh state" do
    dashboard, runner = build(stale: true)
    report = dashboard.report

    assert_equal 1, runner.refresh_calls
    assert_empty report[:current_blockers]
    assert_equal "ethereal", report[:current_production_venue]
    assert_match(/live authoritative status \(auto-refreshed/, report[:status_source])
  end

  test "stale file with fresh backend BLOCK shows the fresh blockers" do
    blocked = fresh_payload.merge("blockers" => [ "current hedge out_of_burn_in_tolerance: drift" ], "current_direct_market_safe" => false)
    dashboard, runner = build(stale: true)
    runner.instance_variable_set(:@fresh_payload, blocked)
    report = dashboard.report

    assert_equal 1, runner.refresh_calls
    assert_includes report[:current_blockers].join(" "), "out_of_burn_in_tolerance"
  end

  test "active runner process never triggers a file rewrite" do
    active_runner = FakeRunner.new(active: true, fresh_payload: fresh_payload)
    dashboard, runner = build(stale: true, runner: active_runner)
    report = dashboard.report

    assert_equal 0, runner.refresh_calls
    assert_equal "runner status file (read-only)", report[:status_source]
  end

  test "failed live refresh fails closed with historical labeling and keeps stale blockers visible" do
    failing = FakeRunner.new(fail_refresh: true, fresh_payload: fresh_payload)
    dashboard, runner = build(stale: true, runner: failing)
    report = dashboard.report

    assert_equal 1, runner.refresh_calls
    assert_match(/STALE — live refresh failed/, report[:status_source])
    assert_match(/historical, not current/, report[:status_source])
    assert_includes report[:current_blockers].join(" "), "READY_FOR_RANDOM"
  end

  test "fresh file is used as-is without any refresh" do
    dashboard, runner = build(stale: false)
    report = dashboard.report

    assert_equal 0, runner.refresh_calls
    assert_equal "runner status file (read-only)", report[:status_source]
    assert_equal "ethereal", report[:current_production_venue]
  end

  test "runner refresh_status_file! refuses while a runner process is active" do
    position = guard_position
    runner = MigrationRandomProductionRunner.new(position: position, trap_signals: false)
    runner.define_singleton_method(:process_active?) { true }
    result = runner.refresh_status_file!

    assert_equal false, result[:refreshed]
    assert_equal "runner_process_active", result[:reason]
  end

  def guard_position
    @guard_position ||= begin
      position = Position.create!(
        user: users(:one), wallet: wallets(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        asset0: "WETH", asset1: "USDC", asset0_amount: "1", asset1_amount: "500",
        asset0_price_usd: "2000", asset1_price_usd: "1",
        external_id: SecureRandom.hex(6), pool_address: "0x#{SecureRandom.hex(20)}", active: true
      )
      position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
      position
    end
  end
end
