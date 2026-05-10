require "test_helper"

class AerodromeLiveObservationSummaryTest < ActiveSupport::TestCase
  test "parses latest JSONL observation log" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("20260510060157-63f690ea.jsonl")
      path.write([
        JSON.generate(type: "start"),
        JSON.generate(
          type: "iteration",
          timestamp: "2026-05-10T06:01:57Z",
          actual_eth_position: { size: "-0.011" },
          new_short_rebalances: [ { id: 188 } ],
          errors: []
        ),
        JSON.generate(
          type: "iteration",
          timestamp: "2026-05-10T09:01:57Z",
          actual_eth_position: { size: "-0.0109" },
          new_short_rebalances: [],
          errors: []
        ),
        JSON.generate(
          type: "final",
          final_close: { status: "success" },
          final_position: nil,
          final_position_confirmed: true,
          final_readback_attempts: [ { attempt: 1, status: "success", position: nil } ],
          manual_action_required: false,
          errors: []
        )
      ].join("\n"))

      report = AerodromeLiveObservationSummary.new(log_dir: dir).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal path.to_s, report.fetch(:log_path)
      assert_equal 2, report.fetch(:iterations)
      assert_equal 10_800, report.fetch(:duration_seconds)
      assert_equal "0.011", report.fetch(:max_observed_eth_short)
      assert_equal 1, report.fetch(:rebalances_count)
      assert_equal 0, report.fetch(:errors_count)
      assert_equal "success", report.fetch(:final_close_status)
      assert_nil report.fetch(:final_position)
      assert_equal false, report.fetch(:manual_action_required)
    end
  end

  test "missing log file is handled safely" do
    Dir.mktmpdir do |dir|
      report = AerodromeLiveObservationSummary.new(log_dir: dir).report

      assert_equal "WARN", report.fetch(:status)
      assert_nil report.fetch(:log_path)
      assert_includes report.fetch(:warnings), "No Aerodrome live observation JSONL log found"
    end
  end
end
