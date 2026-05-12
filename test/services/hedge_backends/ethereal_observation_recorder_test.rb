require "test_helper"
require "tmpdir"

class HedgeBackendsEtherealObservationRecorderTest < ActiveSupport::TestCase
  test "recorder creates directory and parseable sanitized file" do
    Dir.mktmpdir do |dir|
      recorder = HedgeBackends::EtherealObservationRecorder.new(
        root: Pathname(dir).join("nested", "observations"),
        clock: -> { Time.zone.parse("2026-05-12 12:00:00 UTC") },
        id_generator: -> { "abcd1234" }
      )

      path = recorder.record(sample_probe_result, env: sample_env)
      parsed = JSON.parse(path.read)

      assert path.file?
      assert_equal "ethereal", parsed.dig("metadata", "backend")
      assert_equal "api.etherealtest.net", parsed.dig("metadata", "api_base_host")
      assert_equal true, parsed.dig("metadata", "read_only")
      assert_equal false, parsed.dig("metadata", "orders_enabled")
      assert_equal "ok", parsed.dig("probe_result", "market_metadata", "status")
    end
  end

  test "recorder strips sensitive keys case-insensitively and nested" do
    recorder = HedgeBackends::EtherealObservationRecorder.new
    sanitized = recorder.sanitize(
      "private_key" => "secret",
      "Api_Key" => "secret",
      "nested" => {
        "authorization" => "Bearer secret",
        "safe" => "kept",
        "tokenAddress" => "0x0000000000000000000000000000000000000000",
        "signature" => "0xsig",
        "password" => "secret",
        "bearer" => "secret",
        "cookie" => "secret"
      },
      "array" => [ { "SECRET" => "secret", "status" => "ok" } ]
    )

    assert_nil sanitized["private_key"]
    assert_nil sanitized["Api_Key"]
    assert_nil sanitized.dig("nested", "authorization")
    assert_nil sanitized.dig("nested", "tokenAddress")
    assert_nil sanitized.dig("nested", "signature")
    assert_nil sanitized.dig("nested", "password")
    assert_nil sanitized.dig("nested", "bearer")
    assert_nil sanitized.dig("nested", "cookie")
    assert_equal "kept", sanitized.dig("nested", "safe")
    assert_equal "ok", sanitized.dig("array", 0, "status")
  end

  test "recorder preserves endpoint statuses and metadata" do
    sanitized = HedgeBackends::EtherealObservationRecorder.new.sanitize(sample_probe_result)

    assert_equal "ok", sanitized.dig(:endpoint_results, 0, :status)
    assert_equal "GET /v1/product", sanitized.dig(:endpoint_results, 0, :endpoint)
    assert_equal "ETH-USD", sanitized.dig(:config, :market_symbol)
  end

  private

  def sample_env
    {
      "ETHEREAL_API_BASE_URL" => "https://api.etherealtest.net/v1?ignored=true",
      "ETHEREAL_MARKET_SYMBOL" => "ETH-USD",
      "ETHEREAL_ACCOUNT_ID" => "fake-account",
      "ETHEREAL_SUBACCOUNT_ID" => "fake-subaccount"
    }
  end

  def sample_probe_result
    {
      safety_banner: "ETHEREAL READ-ONLY PROBE - NO ORDERS",
      backend: "ethereal",
      read_only: true,
      orders_enabled: false,
      close_enabled: false,
      hyperliquid_execution: false,
      production_wiring: false,
      config: {
        enabled: true,
        api_base_url: "https://api.etherealtest.net",
        market_symbol: "ETH-USD",
        account_id_configured: true,
        subaccount_id_configured: true
      },
      market_metadata: { status: "ok", lot_size: "0.001", tick_size: "0.1", min_order_size: "0.01", max_leverage: "20", collateral: "USDe" },
      endpoint_results: [ { endpoint: "GET /v1/product", status: "ok", http_status: 200 } ],
      errors: [],
      warnings: [],
      status: "WARN"
    }
  end
end
