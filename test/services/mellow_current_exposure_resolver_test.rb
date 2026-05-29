require "test_helper"

class MellowCurrentExposureResolverTest < ActiveSupport::TestCase
  SHARE = "0xcd975e6a5f55137755487f0918b8ca74acce7925"
  USER = "0xe8a204e487a026c353cb1438c8d43aaf1e47d644"
  VAULT = "0x4444444444444444444444444444444444444444"
  POOL = "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59"

  test "resolver succeeds when share token exposes previewMint" do
    position = mellow_position
    calls = base_calls.merge(
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:preview_mint) + uint_word(raw_user_shares) ] => two_words(raw_weth("1.01675"), raw_usdc("532.91")),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:preview_mint) + uint_word(raw_total_supply) ] => two_words(raw_weth("616.629150428444549772"), raw_usdc("323204.389919"))
    )

    result = resolver(position, calls).resolve

    assert_equal "ok", result.fetch(:status)
    assert_equal "current_share_token_resolver", result.fetch(:exposure_source)
    assert_equal "previewMint(uint256)", result.fetch(:successful_method)
    assert_in_delta BigDecimal("1.01675"), BigDecimal(result.fetch(:user_weth_exposure)), BigDecimal("0.000001")
    assert_in_delta BigDecimal("532.91"), BigDecimal(result.fetch(:user_usdc_exposure)), BigDecimal("0.01")
    assert_equal 0, result.fetch(:orders_submitted)
    assert_equal 0, result.fetch(:signatures_created)
  end

  test "resolver succeeds when vault exposes totalAmounts" do
    position = mellow_position
    calls = base_calls.merge(
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:vault) ] => address_word(VAULT),
      [ VAULT, MellowCurrentExposureResolver::SELECTORS.fetch(:total_amounts) ] => two_words(raw_weth("616.629150428444549772"), raw_usdc("323204.389919"))
    )

    result = resolver(position, calls).resolve

    assert_equal "ok", result.fetch(:status)
    assert_equal "totalAmounts()", result.fetch(:successful_method)
    assert_in_delta BigDecimal("1.01675"), BigDecimal(result.fetch(:user_weth_exposure)), BigDecimal("0.0001")
    assert result.fetch(:attempted_methods).any? { |attempt| attempt[:method] == "previewMint(uint256)" && attempt[:status] == "unavailable" }
  end

  test "resolver blocks with attempted method diagnostics when totals unavailable" do
    position = mellow_position

    result = resolver(position, base_calls).resolve

    assert_equal "blocked", result.fetch(:status)
    assert_includes result.fetch(:blockers), "current share-token total WETH/USDC unavailable"
    assert result.fetch(:attempted_methods).present?
    assert result.fetch(:attempted_methods).all? { |attempt| attempt[:status] == "unavailable" }
  end

  test "resolver does not use historical deposit amounts" do
    position = mellow_position
    position.update!(mellow_metadata: position.mellow_metadata_hash.merge("deposit_weth" => "99", "deposit_usdc" => "123").to_json)

    result = resolver(position, base_calls).resolve

    assert_equal "blocked", result.fetch(:status)
    assert_nil result[:user_weth_exposure]
    assert_nil result[:user_usdc_exposure]
  end

  private

  def resolver(position, calls)
    MellowCurrentExposureResolver.new(position: position, eth_call_results: calls)
  end

  def mellow_position
    wallet = Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: USER)
    position = Position.create!(
      user: users(:one),
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.28366857878458",
      asset1_amount: "0",
      asset0_price_usd: "2500",
      asset1_price_usd: "1",
      active: true,
      mellow_metadata: JSON.generate(
        "share_token" => SHARE,
        "submitted_wallet" => USER,
        "strategy_token_id" => "71261528",
        "strategy_pool_address" => POOL
      )
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    position
  end

  def base_calls
    {
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:decimals) ] => word(18),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:balance_of) + USER.delete_prefix("0x").rjust(64, "0") ] => word(raw_user_shares),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:total_supply) ] => word(raw_total_supply),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:token0) ] => address_word(MellowCurrentExposureResolver::WETH_ADDRESS),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:token1) ] => address_word(MellowCurrentExposureResolver::USDC_ADDRESS),
      [ SHARE, MellowCurrentExposureResolver::SELECTORS.fetch(:pool) ] => address_word(POOL)
    }
  end

  def raw_user_shares = (BigDecimal("0.001072847820176313") * 10**18).to_i
  def raw_total_supply = (BigDecimal("0.650660374341310525") * 10**18).to_i
  def raw_weth(value) = (BigDecimal(value) * 10**18).to_i
  def raw_usdc(value) = (BigDecimal(value) * 10**6).to_i

  def two_words(value0, value1)
    "0x#{value0.to_i.to_s(16).rjust(64, '0')}#{value1.to_i.to_s(16).rjust(64, '0')}"
  end

  def word(value)
    "0x#{value.to_i.to_s(16).rjust(64, '0')}"
  end

  def uint_word(value)
    value.to_i.to_s(16).rjust(64, "0")
  end

  def address_word(address)
    "0x#{address.delete_prefix('0x').rjust(64, '0')}"
  end
end
