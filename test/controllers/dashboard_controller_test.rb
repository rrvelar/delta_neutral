require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "should get index" do
    get root_path
    assert_response :success
    assert_select "h1", /Dashboard/i
  end

  test "dashboard displays Aerodrome positions as monitor-only" do
    Position.create!(
      user: users(:one),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      ),
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

    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      get root_path
    end

    assert_response :success
    assert_match "Aerodrome Slipstream", response.body
    assert_select "span", text: "Monitor-only"
    assert_select "span", text: "No orders"
    assert_select "span", text: "Hedge disabled"
  end

  test "dashboard includes active Mellow Extended position owned through current user's wallet" do
    create_mellow_extended_position(user: users(:two), wallet_user: users(:one))

    get root_path

    assert_response :success
    assert_match "WETH/USDC", response.body
    assert_match "Mellow", response.body
    assert_match "Extended", response.body
    assert_match "In tolerance", response.body
    assert_match %r{Active Positions.*?>[1-9]\d*<}m, response.body
    assert_match %r{Active Hedges.*?>[1-9]\d*<}m, response.body
    assert_no_match "No active positions.", response.body
  end

  test "dashboard with inactive positions prompts activation instead of only add wallet" do
    users(:one).positions.update_all(active: false, updated_at: Time.current)
    Position.create!(
      user: users(:one),
      wallet: Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355702"
      ),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "71674988",
      pool_address: "0xpool",
      active: false
    )

    get root_path

    assert_response :success
    assert_match "No active production position selected", response.body
    assert_match "Activate one from Positions", response.body
    assert_match "Activate", response.body
    assert_no_match "Add a wallet</a> to get started", response.body
  end

  test "redirects to login when not authenticated" do
    sign_out
    get root_path
    assert_redirected_to new_session_path
  end

  private

  def create_mellow_extended_position(user:, wallet_user:)
    wallet = Wallet.create!(
      user: wallet_user,
      network: networks(:base),
      address: "0x#{SecureRandom.hex(20)}"
    )
    position = Position.create!(
      user: user,
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("0.727"),
      asset1_amount: BigDecimal("1500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "mellow:71261528",
      pool_address: "0xpool",
      active: true
    )
    position.create_hedge!(target: BigDecimal("1.0"), tolerance: BigDecimal("0.03"), active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: BigDecimal("0.727"),
      extended_status: "active",
      ethereal_short_eth: BigDecimal("0"),
      ethereal_status: "flat",
      nado_short_eth: BigDecimal("0"),
      nado_status: "flat",
      combined_short_eth: BigDecimal("0.727"),
      target_short_eth: BigDecimal("0.727"),
      tolerance_abs_eth: BigDecimal("0.02181"),
      drift_eth: BigDecimal("0"),
      inside_tolerance: true,
      signer_status: "ok"
    )
    position
  end
end
