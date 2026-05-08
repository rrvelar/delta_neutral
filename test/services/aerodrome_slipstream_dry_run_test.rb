require "test_helper"

class AerodromeSlipstreamDryRunTest < ActiveSupport::TestCase
  test "returns structured verified math report for mocked position" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    report = AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report

    service.verify
    result = report.fetch(:results).first
    assert_equal AerodromeSlipstreamDryRun::SAFETY_BANNER, report.fetch(:safety_banner)
    assert_equal false, report.fetch(:database_write)
    assert_equal false, report.fetch(:hedge_enabled)
    assert_equal "5016", result.fetch(:token_id)
    assert_equal false, report.fetch(:amount_math_deferred)
    assert_equal "ok", result.fetch(:status)
    assert_equal "0x23cb5f48fa3f4502232f3442637f90e8e3355701", result.fetch(:owner_address)
    assert_equal "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", result.fetch(:pool_address)
    assert_equal false, result.fetch(:database_write)
    assert_equal false, result.fetch(:hedge_enabled)
    assert_equal 1_290_590_456_994_170_212, result.fetch(:amount0_raw)
    assert_equal 4_594_633_482, result.fetch(:amount1_raw)
    assert_equal "1.290590456994170212", result.fetch(:amount0_decimal)
    assert_equal "0.000000004594633482", result.fetch(:amount1_decimal)
    assert_equal AerodromeSlipstreamService::VERIFIED_AMOUNT_MATH_SOURCE, result.fetch(:math_source)
    assert_equal "verified_math", result.fetch(:verification_status)
    assert_equal "2000.0", result.fetch(:token0_price_usd)
    assert_equal "1.0", result.fetch(:token1_price_usd)
    assert_equal "7081.180913988340424", result.fetch(:total_value_usd)
    assert_equal "supported", result.fetch(:valuation_status)
    assert_equal AerodromeSlipstreamValuation::VALUATION_SOURCE, result.fetch(:valuation_source)
    assert_nil result.fetch(:valuation_reason)
    assert_nil result.fetch(:error_class)
  end

  test "handles one token error and continues with other tokens" do
    ok_position = position_data("5016")
    service = Object.new
    service.define_singleton_method(:fetch_position) do |token_id|
      raise AerodromeSlipstreamService::RpcError, "RPC failed" if token_id == "bad"

      ok_position
    end

    report = AerodromeSlipstreamDryRun.new(token_ids: [ "bad", "5016" ], slipstream_service: service).report
    error_result, ok_result = report.fetch(:results)

    assert_equal "error", error_result.fetch(:status)
    assert_equal "AerodromeSlipstreamService::RpcError", error_result.fetch(:error_class)
    assert_match "RPC failed", error_result.fetch(:error_message)
    assert_equal "ok", ok_result.fetch(:status)
    assert_equal "5016", ok_result.fetch(:token_id)
  end

  test "marks computed amount fields as verified math" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    result = AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report.fetch(:results).first

    service.verify
    assert_equal 1_290_590_456_994_170_212, result.fetch(:amount0_raw)
    assert_equal 4_594_633_482, result.fetch(:amount1_raw)
    assert_nil result.fetch(:partial_data_reason)
    assert_equal "ok", result.fetch(:status)
  end

  test "does not call HyperliquidService" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      assert_equal "ok", AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report.fetch(:results).first.fetch(:status)
    end

    service.verify
  end

  test "does not write Position records" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    assert_no_difference "Position.count" do
      AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report
    end

    service.verify
  end

  test "does not write Hedge records" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    assert_no_difference "Hedge.count" do
      AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report
    end

    service.verify
  end

  test "normalizes duplicate and blank token ids" do
    normalized = AerodromeSlipstreamDryRun.normalize_token_ids([ " 5016 ", "", "5016", "999, 999" ])

    assert_equal [ "5016", "999" ], normalized.fetch(:token_ids)
    assert_includes normalized.fetch(:notes), "Duplicate token id 5016 ignored"
    assert_includes normalized.fetch(:notes), "Duplicate token id 999 ignored"
  end

  test "missing config error is shown safely in result" do
    service_class = Class.new do
      def initialize(**)
        raise AerodromeSlipstreamService::ConfigError, "Missing required Aerodrome config: BASE_RPC_URL"
      end
    end

    result = AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service_class: service_class).report.fetch(:results).first

    assert_equal "error", result.fetch(:status)
    assert_equal "AerodromeSlipstreamService::ConfigError", result.fetch(:error_class)
    assert_match "BASE_RPC_URL", result.fetch(:error_message)
    assert_equal false, result.fetch(:database_write)
    assert_equal false, result.fetch(:hedge_enabled)
  end

  test "verify config without CHECK_RPC does not call RPC" do
    report = AerodromeSlipstreamDryRun::ConfigVerification.new(
      rpc_url: "https://base.example/rpc",
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      check_rpc: false
    ).report

    assert_equal "ok", report.fetch(:status)
    assert_equal false, report.fetch(:check_rpc)
    assert_empty report.fetch(:rpc_checks)
    assert_not_requested :post, "https://base.example/rpc"
  end

  test "verify config with CHECK_RPC uses mocked read-only RPC only" do
    stub_request(:post, "https://base.example/rpc")
      .to_return(
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x2105" }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x60016001" }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x60026002" }.to_json, headers: { "Content-Type" => "application/json" } }
      )

    report = AerodromeSlipstreamDryRun::ConfigVerification.new(
      rpc_url: "https://base.example/rpc",
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      check_rpc: true
    ).report

    assert_equal "ok", report.fetch(:status)
    assert_equal [ "eth_chainId", "eth_getCode", "eth_getCode" ], report.fetch(:rpc_checks).map { |check| check.fetch(:method) }
    assert_requested :post, "https://base.example/rpc", times: 3
  end

  test "verify config invalid manager address fails safely" do
    report = AerodromeSlipstreamDryRun::ConfigVerification.new(
      rpc_url: "https://base.example/rpc",
      position_manager_address: "bad",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      check_rpc: true
    ).report

    assert_equal "error", report.fetch(:status)
    assert_includes report.fetch(:errors), "Invalid AERODROME_SLIPSTREAM_POSITION_MANAGER address"
    assert_empty report.fetch(:rpc_checks)
    assert_not_requested :post, "https://base.example/rpc"
  end

  test "verify config missing base rpc fails safely" do
    report = AerodromeSlipstreamDryRun::ConfigVerification.new(
      rpc_url: nil,
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      check_rpc: false
    ).report

    assert_equal "error", report.fetch(:status)
    assert_includes report.fetch(:errors), "Missing BASE_RPC_URL"
  end

  private

  def position_data(token_id)
    AerodromeSlipstreamService::PositionData.new(
      token_id: token_id,
      owner_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token0_address: "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b",
      token1_address: "0x4200000000000000000000000000000000000006",
      token0_decimals: 18,
      token1_decimals: 18,
      token0_symbol: "AERO",
      token1_symbol: "WETH",
      tick_spacing: 200,
      tick_lower: -151400,
      tick_upper: -147400,
      liquidity: 123,
      sqrt_price_x96: 456,
      current_tick: -155876,
      tokens_owed0_raw: 7,
      tokens_owed1_raw: 11,
      amount0_raw: 1_290_590_456_994_170_212,
      amount1_raw: 4_594_633_482,
      partial_data_reason: nil,
      verification_status: "verified_math",
      token0_price_usd: BigDecimal("2000"),
      token1_price_usd: BigDecimal("1"),
      total_value_usd: BigDecimal("7081.180913988340424"),
      valuation_status: "supported",
      valuation_source: AerodromeSlipstreamValuation::VALUATION_SOURCE,
      valuation_reason: nil
    )
  end
end
