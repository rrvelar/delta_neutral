require "test_helper"

class AerodromeFeesServiceTest < ActiveSupport::TestCase
  test "reads tokens owed from mocked position manager data" do
    position = create_aerodrome_position
    slipstream = Object.new
    raw_position = AerodromeSlipstreamService::RawPosition.new(
      nonce: 0,
      operator: "0x0000000000000000000000000000000000000000",
      token0_address: "0x4200000000000000000000000000000000000006",
      token1_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      tick_spacing: 100,
      tick_lower: -1000,
      tick_upper: 1000,
      liquidity: 1,
      fee_growth_inside0_last_x128: 0,
      fee_growth_inside1_last_x128: 0,
      tokens_owed0_raw: 10_000_000_000_000_000,
      tokens_owed1_raw: 3_500_000
    )
    slipstream.define_singleton_method(:position) do |token_id|
      raise "unexpected token id" unless token_id == position.external_id

      raw_position
    end
    slipstream.define_singleton_method(:token_data) do |address|
      case address
      when "0x4200000000000000000000000000000000000006"
        AerodromeSlipstreamService::TokenData.new(address: address, decimals: 18, symbol: "WETH", name: "Wrapped Ether")
      when "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        AerodromeSlipstreamService::TokenData.new(address: address, decimals: 6, symbol: "USDC", name: "USD Coin")
      else
        raise "unexpected token"
      end
    end

    result = AerodromeFeesService.new(slipstream_service: slipstream).fees_for_position(position)

    assert_equal "detected", result.status
    assert_equal AerodromeFeesService::SOURCE, result.fee_source
    assert_equal BigDecimal("0.01"), result.fee0_amount
    assert_equal BigDecimal("20"), result.fee0_usd
    assert_equal BigDecimal("3.5"), result.fee1_amount
    assert_equal BigDecimal("3.5"), result.fee1_usd
    assert_equal BigDecimal("23.5"), result.total_fees_usd
  end

  test "Mellow fees use observed strategy token and pro-rate by user share" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      mellow_metadata: JSON.generate("strategy_token_id" => "71261528", "user_share_percent" => "2")
    )
    slipstream = Object.new
    raw_position = AerodromeSlipstreamService::RawPosition.new(
      nonce: 0,
      operator: "0x0000000000000000000000000000000000000000",
      token0_address: "0x4200000000000000000000000000000000000006",
      token1_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      tick_spacing: 100,
      tick_lower: -1000,
      tick_upper: 1000,
      liquidity: 1,
      fee_growth_inside0_last_x128: 0,
      fee_growth_inside1_last_x128: 0,
      tokens_owed0_raw: 10_000_000_000_000_000_000,
      tokens_owed1_raw: 100_000_000
    )
    slipstream.define_singleton_method(:position) do |token_id|
      raise "unexpected token id #{token_id.inspect}" unless token_id == "71261528"

      raw_position
    end
    slipstream.define_singleton_method(:token_data) do |address|
      case address
      when "0x4200000000000000000000000000000000000006"
        AerodromeSlipstreamService::TokenData.new(address: address, decimals: 18, symbol: "WETH", name: "Wrapped Ether")
      when "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
        AerodromeSlipstreamService::TokenData.new(address: address, decimals: 6, symbol: "USDC", name: "USD Coin")
      else
        raise "unexpected token"
      end
    end

    result = AerodromeFeesService.new(slipstream_service: slipstream).fees_for_position(position)

    assert_equal "detected", result.status
    assert_equal AerodromeFeesService::MELLOW_SOURCE, result.fee_source
    assert_equal "mellow:71261528", result.token_id
    assert_equal BigDecimal("0.2"), result.fee0_amount
    assert_equal BigDecimal("400"), result.fee0_usd
    assert_equal BigDecimal("2"), result.fee1_amount
    assert_equal BigDecimal("2"), result.fee1_usd
    assert_equal BigDecimal("402"), result.total_fees_usd
    assert_includes result.warnings, "Mellow rewards/fees are read-only pro-rata estimates from the observed strategy token; claiming/collecting is not implemented."
  end

  test "Mellow fees missing observed strategy token are unavailable without exception" do
    position = create_aerodrome_position
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:missing",
      mellow_metadata: JSON.generate("user_share_percent" => "2")
    )
    slipstream = Object.new
    slipstream.define_singleton_method(:position) { |_token_id| raise "position should not be read without token id" }

    result = AerodromeFeesService.new(slipstream_service: slipstream).fees_for_position(position)

    assert_equal "unavailable", result.status
    assert_nil result.total_fees_usd
    assert_includes result.warnings, "Mellow observed strategy token id is unavailable."
  end

  private

  def create_aerodrome_position
    Position.create!(
      user: users(:one),
      wallet: Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
  end
end
