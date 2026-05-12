require "test_helper"
require "rake"
require "ostruct"
require "tmpdir"

class HedgeBackendsTaskTest < ActiveSupport::TestCase
  def setup
    Rails.application.load_tasks unless Rake::Task.task_defined?("hedge_backends:ethereal_probe")
    Rake::Task["hedge_backends:ethereal_probe"].reenable
    Rake::Task["hedge_backends:ethereal_probe_record"].reenable
    Rake::Task["hedge_backends:ethereal_observation_summary"].reenable
    Rake::Task["hedge_backends:ethereal_safety_check"].reenable
    @old_env = ENV.to_h.slice(
      "FORMAT",
      "PATH",
      "ETHEREAL_READ_ONLY_ENABLED",
      "ETHEREAL_API_BASE_URL",
      "ETHEREAL_MARKET_SYMBOL",
      "ETHEREAL_SUBACCOUNT_ID"
    )
  end

  def teardown
    %w[FORMAT PATH ETHEREAL_READ_ONLY_ENABLED ETHEREAL_API_BASE_URL ETHEREAL_MARKET_SYMBOL ETHEREAL_SUBACCOUNT_ID].each { |key| ENV.delete(key) }
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

  test "probe record disabled does not call network and returns blocked without writing" do
    ENV["FORMAT"] = "json"
    ENV["ETHEREAL_READ_ONLY_ENABLED"] = "false"

    out, = capture_io { Rake::Task["hedge_backends:ethereal_probe_record"].invoke }
    parsed = JSON.parse(out)

    assert_equal "BLOCKED", parsed.fetch("status")
    assert_nil parsed.fetch("observation_path")
    assert_equal false, parsed.fetch("orders_enabled")
    assert_empty WebMock::RequestRegistry.instance.requested_signatures.hash
  end

  test "probe record enabled with mocked probe saves sanitized observation" do
    Dir.mktmpdir do |dir|
      fake_probe = Struct.new(:result) do
        def run_probe = result
      end.new(OpenStruct.new(to_h: fake_probe_result))

      HedgeBackends::EtherealObservationRecorder.stub(:new, HedgeBackends::EtherealObservationRecorder.new(root: dir)) do
        HedgeBackends::EtherealReadOnlyProbe.stub(:new, fake_probe) do
          ENV["FORMAT"] = "json"
          out, = capture_io { Rake::Task["hedge_backends:ethereal_probe_record"].invoke }
          parsed = JSON.parse(out)
          observation = JSON.parse(Pathname(parsed.fetch("observation_path")).read)

          assert_equal "WARN", parsed.fetch("status")
          assert_equal false, parsed.fetch("orders_enabled")
          assert_nil observation.dig("probe_result", "raw", "private_key")
          assert_equal "ok", observation.dig("probe_result", "endpoint_results", 0, "status")
        end
      end
    end
  end

  test "observation summary reads fixture and classifies readiness" do
    ENV["FORMAT"] = "json"
    ENV["PATH"] = Rails.root.join("test/fixtures/files/hedge_backends/ethereal_probe_sample.json").to_s

    out, = capture_io { Rake::Task["hedge_backends:ethereal_observation_summary"].invoke }
    parsed = JSON.parse(out)

    assert_equal "WARN", parsed.fetch("status")
    assert_equal true, parsed.fetch("market_metadata_complete")
    assert_equal true, parsed.fetch("mark_price_present")
    assert_equal true, parsed.fetch("position_readback_proven")
    assert_equal true, parsed.fetch("account_health_proven")
    assert_equal true, parsed.fetch("market_metadata_ready")
    assert_equal true, parsed.fetch("mark_price_ready")
    assert_equal true, parsed.fetch("position_readback_ready")
    assert_equal true, parsed.fetch("account_health_ready")
    assert_equal false, parsed.fetch("fills_ready")
    assert_equal false, parsed.fetch("order_status_ready")
    assert_equal false, parsed.fetch("reduce_only_close_ready")
    assert_equal false, parsed.fetch("final_zero_readback_ready")
    assert_equal false, parsed.fetch("live_adapter_allowed")
    assert_includes parsed.fetch("missing_before_sandbox_order_proof"), "reduce-only close still not implemented"
  end

  test "observation summary rejects missing path" do
    ENV["FORMAT"] = "json"
    ENV["PATH"] = Rails.root.join("tmp/does-not-exist.json").to_s

    out, = capture_io { Rake::Task["hedge_backends:ethereal_observation_summary"].invoke }
    parsed = JSON.parse(out)

    assert_equal "BLOCKED", parsed.fetch("status")
    assert_match "does not exist", parsed.fetch("errors").first
  end

  test "observation summary rejects invalid JSON" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("bad.json")
      path.write("not json")
      ENV["FORMAT"] = "json"
      ENV["PATH"] = path.to_s

      out, = capture_io { Rake::Task["hedge_backends:ethereal_observation_summary"].invoke }
      parsed = JSON.parse(out)

      assert_equal "BLOCKED", parsed.fetch("status")
      assert_match "invalid JSON", parsed.fetch("errors").first
    end
  end

  test "safety check human output includes static safety banner" do
    out, = capture_io { Rake::Task["hedge_backends:ethereal_safety_check"].invoke }

    assert_includes out, "ETHEREAL READ-ONLY SAFETY CHECK - STATIC ONLY"
    assert_includes out, "NO NETWORK"
    assert_includes out, "NO ORDERS"
    assert_includes out, "NO CLOSE"
    assert_includes out, "NO SIGNING"
    assert_includes out, "NO PRODUCTION WIRING"
    assert_includes out, "final status: PASS"
  end

  test "safety check JSON output parses and includes inert safety fields" do
    ENV["FORMAT"] = "json"

    out, = capture_io { Rake::Task["hedge_backends:ethereal_safety_check"].invoke }
    parsed = JSON.parse(out)

    assert_equal "PASS", parsed.fetch("status")
    assert_equal false, parsed.fetch("network_calls")
    assert_equal false, parsed.fetch("orders_enabled")
    assert_equal false, parsed.fetch("close_enabled")
    assert_equal false, parsed.fetch("signing_enabled")
    assert_equal false, parsed.fetch("production_wiring")
    assert_empty parsed.fetch("blockers")
  end

  test "safety check reports blocked when dangerous method is present" do
    HedgeBackends::EtherealReadOnlyProbe.class_eval { def open_short; end }

    report = HedgeBackends::EtherealSafetyCheck.new.report

    assert_equal "BLOCKED", report.fetch(:status)
    assert_includes report.fetch(:blockers).join(" "), "dangerous methods absent"
  ensure
    HedgeBackends::EtherealReadOnlyProbe.remove_method(:open_short) if HedgeBackends::EtherealReadOnlyProbe.method_defined?(:open_short)
  end

  test "safety check performs no external network and no database writes" do
    before_requests = WebMock::RequestRegistry.instance.requested_signatures.hash.dup

    assert_no_difference -> { ShortRebalance.count } do
      capture_io { Rake::Task["hedge_backends:ethereal_safety_check"].invoke }
    end

    assert_equal before_requests, WebMock::RequestRegistry.instance.requested_signatures.hash
  end

  private

  def fake_probe_result
    {
      safety_banner: "ETHEREAL READ-ONLY PROBE - NO ORDERS",
      backend: "ethereal",
      read_only: true,
      orders_enabled: false,
      close_enabled: false,
      hyperliquid_execution: false,
      production_wiring: false,
      config: { market_symbol: "ETH-USD", api_base_url: "https://api.etherealtest.net" },
      endpoint_results: [ { endpoint: "GET /v1/product", status: "ok", http_status: 200 } ],
      raw: { private_key: "must-not-save" },
      warnings: [],
      errors: [],
      status: "WARN"
    }
  end
end
