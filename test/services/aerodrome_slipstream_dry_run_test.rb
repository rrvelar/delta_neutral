require "test_helper"

class AerodromeSlipstreamDryRunTest < ActiveSupport::TestCase
  test "returns structured partial report for mocked position" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    report = AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report

    service.verify
    result = report.fetch(:results).first
    assert_equal AerodromeSlipstreamDryRun::SAFETY_BANNER, report.fetch(:safety_banner)
    assert_equal false, report.fetch(:database_write)
    assert_equal false, report.fetch(:hedge_enabled)
    assert_equal "5016", result.fetch(:token_id)
    assert_equal "partial", result.fetch(:status)
    assert_equal "0x23cb5f48fa3f4502232f3442637f90e8e3355701", result.fetch(:owner_address)
    assert_equal "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", result.fetch(:pool_address)
    assert_equal false, result.fetch(:database_write)
    assert_equal false, result.fetch(:hedge_enabled)
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
    assert_equal "partial", ok_result.fetch(:status)
    assert_equal "5016", ok_result.fetch(:token_id)
  end

  test "marks amount fields as deferred partial data" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    result = AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report.fetch(:results).first

    service.verify
    assert_nil result.fetch(:amount0_raw)
    assert_nil result.fetch(:amount1_raw)
    assert_equal AerodromeSlipstreamService::PARTIAL_AMOUNT_MATH_DEFERRED, result.fetch(:partial_data_reason)
    assert_equal "partial", result.fetch(:status)
  end

  test "does not call HyperliquidService" do
    service = Minitest::Mock.new
    service.expect(:fetch_position, position_data("5016"), [ "5016" ])

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      assert_equal "partial", AerodromeSlipstreamDryRun.new(token_ids: [ "5016" ], slipstream_service: service).report.fetch(:results).first.fetch(:status)
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
      amount0_raw: nil,
      amount1_raw: nil,
      partial_data_reason: AerodromeSlipstreamService::PARTIAL_AMOUNT_MATH_DEFERRED,
      verification_status: "partial"
    )
  end
end
