require "test_helper"

class MigrationRandomProductionDashboardTest < ActiveSupport::TestCase
  Hedge = Struct.new(:execution_venue, :tolerance)
  FakePosition = Struct.new(:id, :hedge, :position_dashboard_snapshot)

  setup do
    @dir = Dir.mktmpdir
    @position = FakePosition.new(424_242, Hedge.new("ethereal", "0.03"), nil)
  end

  teardown do
    FileUtils.remove_entry(@dir) if @dir && Dir.exist?(@dir)
  end

  def write(name, payload)
    File.write(File.join(@dir, name), JSON.pretty_generate(payload))
  end

  def write_latest(event)
    File.write(File.join(@dir, "latest_position_#{@position.id}.jsonl"), "#{JSON.generate(event)}\n")
  end

  def report
    MigrationRandomProductionDashboard.new(position: @position, log_dir: @dir).report
  end

  test "current blockers come from the authoritative status, not the stale event" do
    write("status_position_#{@position.id}.json", {
      "status" => "running",
      "current_direct_market_safe" => true,
      "updated_at" => Time.current.utc.iso8601,
      "blockers" => [],
      "direct_preflight_blockers" => [],
      "direct_venue_shorts" => { "extended" => "0", "ethereal" => "2.4027", "nado" => "0" }
    })
    write("heartbeat_position_#{@position.id}.json", {
      "status" => "running",
      "started_at" => Time.current.utc.iso8601,
      "updated_at" => Time.current.utc.iso8601
    })
    write_latest({
      "event" => "cycle", "cycle" => 18,
      "timestamp" => 1.hour.ago.utc.iso8601,
      "blockers" => [ "active venue one-shot rebalance status is blocked_before_submit" ]
    })

    result = report

    assert_equal true, result[:current_direct_market_safe]
    assert_empty result[:current_blockers]
    assert_equal "active venue one-shot rebalance status is blocked_before_submit", result[:historical_blocker]
    assert_equal true, result[:latest_event_stale]
    assert_equal "2.4027", result[:active_venue_short_eth].to_s
  end

  test "an unsafe authoritative blocker is reported as a current blocker" do
    write("status_position_#{@position.id}.json", {
      "status" => "blocked",
      "current_direct_market_safe" => false,
      "updated_at" => Time.current.utc.iso8601,
      "blockers" => [ "direct preflight open orders are nonzero or unknown" ],
      "direct_preflight_blockers" => []
    })

    result = report

    assert_includes result[:current_blockers], "direct preflight open orders are nonzero or unknown"
    assert_equal false, result[:current_direct_market_safe]
  end

  test "an event from the current run is not flagged stale" do
    started = 10.minutes.ago.utc.iso8601
    write("status_position_#{@position.id}.json", { "status" => "running", "updated_at" => Time.current.utc.iso8601 })
    write("heartbeat_position_#{@position.id}.json", { "status" => "running", "started_at" => started, "updated_at" => Time.current.utc.iso8601 })
    write_latest({ "event" => "cycle", "cycle" => 2, "timestamp" => 1.minute.ago.utc.iso8601, "blockers" => [] })

    assert_equal false, report[:latest_event_stale]
  end
end
