require "test_helper"

class PositionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "should get index" do
    get positions_path
    assert_response :success
  end

  test "should get show" do
    position = positions(:eth_usdc)
    get position_path(position)
    assert_response :success
  end

  test "index displays Aerodrome monitor-only position safely" do
    position = create_aerodrome_position

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get positions_path
    end

    assert_response :success
    assert_select "td", text: /Aerodrome Slipstream/
    assert_select "span", text: "Monitor-only"
    assert_select "span", text: "No orders"
    assert_select "span", text: "Hyperliquid not called"
    assert_match position.external_id, response.body
    assert_match "1.250000", response.body
    assert_match "$3,000.00", response.body
  end

  test "show displays Aerodrome monitor-only details and hedge preview" do
    position = create_aerodrome_position

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        get position_path(position)
      end
    end

    assert_response :success
    assert_select "span", text: "MONITOR ONLY"
    assert_select "span", text: "NO ORDERS"
    assert_select "span", text: "HEDGE DISABLED"
    assert_select "span", text: "HYPERLIQUID NOT CALLED"
    assert_select "span", text: "NOT LIVE HEDGE-READY"
    assert_match "Aerodrome Slipstream", response.body
    assert_match "Token ID 315985", response.body
    assert_match "Refresh Read-only Data", response.body
    assert_match "Updates on-chain LP data only", response.body
    assert_match "No Hyperliquid", response.body
    assert_match "No hedge execution", response.body
    assert_match "PREVIEW ONLY", response.body
    assert_match "short", response.body
    assert_match "ETH", response.body
    assert_match "1.250000", response.body
    assert_match "$2,500.00", response.body
    assert_match "AERODROME_HEDGE_ENABLED must remain false", response.body
    assert_no_match "Sync Now", response.body
    assert_no_match "Create Hedge", response.body
    assert_no_match "Rebalance", response.body
    assert_no_match "Execute", response.body
    assert_no_match "Trade", response.body
    assert_no_match "Approve", response.body
  end

  test "show keeps Uniswap sync and hedge actions unchanged" do
    position = positions(:eth_usdc)

    get position_path(position)

    assert_response :success
    assert_match "Sync Now", response.body
    assert_match "View Hedge", response.body
    assert_no_match "Refresh Read-only Data", response.body
  end

  test "show displays unavailable hedge preview when Aerodrome price data is missing" do
    position = create_aerodrome_position(asset0_price_usd: nil)

    with_env(
      "AERODROME_WETH_ADDRESS" => "0x4200000000000000000000000000000000000006",
      "AERODROME_USDC_ADDRESS" => "0x0000000000000000000000000000000000000001"
    ) do
      get position_path(position)
    end

    assert_response :success
    assert_match "Hedge preview unavailable", response.body
    assert_match "amount or USD price is missing", response.body
    assert_match "Unavailable", response.body
  end

  test "should queue sync_now" do
    position = positions(:eth_usdc)
    post sync_now_position_path(position)
    assert_redirected_to position_path(position)
  end

  private

  def create_aerodrome_position(asset0_price_usd: BigDecimal("2000"), asset1_price_usd: BigDecimal("1"))
    Position.create!(
      user: users(:one),
      wallet: base_wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: asset0_price_usd,
      asset1_price_usd: asset1_price_usd,
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
  end

  def base_wallet
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
