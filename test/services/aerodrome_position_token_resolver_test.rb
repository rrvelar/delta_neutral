require "test_helper"

class AerodromePositionTokenResolverTest < ActiveSupport::TestCase
  test "direct Slipstream position resolves numeric token id unchanged" do
    position = create_position(external_id: "315985")

    result = AerodromePositionTokenResolver.resolve(position)

    assert_equal "ok", result.status
    assert_equal "315985", result.token_id
    assert_equal "315985", result.display_token_id
    assert_equal "direct_slipstream_nft", result.source
    assert_equal BigDecimal("1"), result.pro_rata_share
    refute result.strategy_level
  end

  test "Mellow synthetic id resolves observed strategy token and share fraction" do
    position = create_position(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      mellow_metadata: JSON.generate("user_share_percent" => "1.25")
    )

    result = AerodromePositionTokenResolver.resolve(position)

    assert_equal "ok", result.status
    assert_equal "71261528", result.token_id
    assert_equal "mellow:71261528", result.display_token_id
    assert_equal "mellow_strategy_observed_token", result.source
    assert_equal BigDecimal("0.0125"), result.pro_rata_share
    assert result.strategy_level
  end

  test "Mellow metadata strategy token id is preferred over synthetic id" do
    position = create_position(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:old",
      mellow_metadata: JSON.generate("strategy_token_id" => "71261528", "user_share_percent" => "0.5")
    )

    result = AerodromePositionTokenResolver.resolve(position)

    assert_equal "ok", result.status
    assert_equal "71261528", result.token_id
    assert_equal BigDecimal("0.5"), result.pro_rata_share
  end

  test "Mellow missing observed strategy token returns unavailable" do
    position = create_position(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:missing",
      mellow_metadata: JSON.generate("user_share_percent" => "1.25")
    )

    result = AerodromePositionTokenResolver.resolve(position)

    assert_equal "unavailable", result.status
    assert_nil result.token_id
    assert_includes result.warnings, "Mellow observed strategy token id is unavailable."
  end

  private

  def create_position(attributes = {})
    Position.create!(
      {
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
      }.merge(attributes)
    )
  end
end
