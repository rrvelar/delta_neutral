require "test_helper"

class AerodromeAeroUsdPriceTest < ActiveSupport::TestCase
  RPC_URL = "https://base.example.com/rpc"
  AERO = "0x940181a94a35a4569e4529a3cdfb74e38fd98631"
  USDC = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  AERO_USDC_POOL = "0xbe00ff35af70e8415d0eb605a286d8a45466a4c1"

  test "reads verified Slipstream AERO USDC pool price with mocked eth_call" do
    service = AerodromeAeroUsdPrice.new(
      rpc_url: RPC_URL,
      pool_address: AERO_USDC_POOL,
      aero_token_address: AERO,
      usdc_token_address: USDC,
      valuation_enabled: true
    )
    sqrt_price_x96 = AerodromeSlipstreamMath::Q96 * 1_000_000
    stub_rpc_results(
      "0x#{word(USDC)}",
      "0x#{word(AERO)}",
      "0x#{uint_word(6)}",
      "0x#{uint_word(18)}",
      slot0_result(sqrt_price_x96)
    )

    result = service.price

    assert_equal BigDecimal("1"), result.price
    assert_equal "aerodrome_pool", result.source
    assert_empty result.warnings
  end

  test "manual price still takes precedence over on-chain config" do
    service = AerodromeAeroUsdPrice.new(
      rpc_url: RPC_URL,
      pool_address: AERO_USDC_POOL,
      aero_token_address: AERO,
      usdc_token_address: USDC,
      manual_price: "0.75",
      valuation_enabled: true
    )

    result = service.price

    assert_equal BigDecimal("0.75"), result.price
    assert_equal "manual", result.source
    assert_empty result.warnings
    assert_not_requested :post, RPC_URL
  end

  test "missing price source remains unavailable" do
    result = AerodromeAeroUsdPrice.new.price

    assert_nil result.price
    assert_equal "unavailable", result.source
    assert_includes result.warnings, "AERO USD price source is not configured"
  end

  private

  def stub_rpc_results(*results)
    stub_request(:post, RPC_URL).to_return(
      *results.map { |result| { status: 200, body: { jsonrpc: "2.0", id: 1, result: result }.to_json, headers: { "Content-Type" => "application/json" } } }
    )
  end

  def slot0_result(sqrt_price_x96)
    "0x#{uint_word(sqrt_price_x96)}#{uint_word(0)}#{uint_word(0)}#{uint_word(100)}#{uint_word(100)}#{uint_word(1)}"
  end

  def word(address)
    address.downcase.delete_prefix("0x").rjust(64, "0")
  end

  def uint_word(value)
    Integer(value).to_s(16).rjust(64, "0")
  end
end
