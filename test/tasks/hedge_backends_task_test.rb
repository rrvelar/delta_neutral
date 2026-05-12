require "test_helper"
require "rake"

class HedgeBackendsTaskTest < ActiveSupport::TestCase
  def setup
    Rails.application.load_tasks unless Rake::Task.task_defined?("hedge_backends:ethereal_probe")
    Rake::Task["hedge_backends:ethereal_probe"].reenable
    @old_env = ENV.to_h.slice(
      "FORMAT",
      "ETHEREAL_READ_ONLY_ENABLED",
      "ETHEREAL_API_BASE_URL",
      "ETHEREAL_MARKET_SYMBOL",
      "ETHEREAL_SUBACCOUNT_ID"
    )
  end

  def teardown
    %w[FORMAT ETHEREAL_READ_ONLY_ENABLED ETHEREAL_API_BASE_URL ETHEREAL_MARKET_SYMBOL ETHEREAL_SUBACCOUNT_ID].each { |key| ENV.delete(key) }
    @old_env.each { |key, value| ENV[key] = value }
  end

  test "human output includes safety banner when disabled" do
    ENV["ETHEREAL_READ_ONLY_ENABLED"] = "false"

    out, = capture_io { Rake::Task["hedge_backends:ethereal_probe"].invoke }

    assert_includes out, "ETHEREAL READ-ONLY PROBE - NO ORDERS"
    assert_includes out, "READ ONLY"
    assert_includes out, "NO HYPERLIQUID EXECUTION"
    assert_includes out, "final status: BLOCKED"
  end

  test "json output includes inert safety fields" do
    ENV["FORMAT"] = "json"
    ENV["ETHEREAL_READ_ONLY_ENABLED"] = "false"

    out, = capture_io { Rake::Task["hedge_backends:ethereal_probe"].invoke }
    parsed = JSON.parse(out)

    assert_equal true, parsed.fetch("read_only")
    assert_equal false, parsed.fetch("orders_enabled")
    assert_equal false, parsed.fetch("close_enabled")
    assert_equal false, parsed.fetch("hyperliquid_execution")
    assert_equal false, parsed.fetch("production_wiring")
  end
end
