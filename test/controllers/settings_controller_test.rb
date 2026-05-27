require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "should get edit" do
    get edit_settings_path
    assert_response :success
  end

  test "settings compatibility path renders edit page" do
    get "/settings"
    assert_response :success
    assert_match "Settings", response.body
  end

  test "edit shows current production venue summary without making Hyperliquid look current" do
    create_extended_position

    get edit_settings_path

    assert_response :success
    assert_match "Current Production Hedge", response.body
    assert_match "Extended", response.body
    assert_match "Signer", response.body
    assert_match "Hyperliquid Legacy Settings", response.body
    assert_match "These settings do not indicate the current production venue.", response.body
  end

  test "navbar settings link points to valid settings route" do
    get root_path

    assert_response :success
    assert_select "a[href='#{edit_settings_path}']", text: "Settings"
    get edit_settings_path
    assert_response :success
  end

  test "should get edit without existing setting" do
    settings(:one).destroy
    get edit_settings_path
    assert_response :success
  end

  test "should update setting" do
    patch settings_path, params: { setting: { hyperliquid_leverage: 5, hyperliquid_cross_margin: false } }
    assert_redirected_to edit_settings_path

    setting = users(:one).setting.reload
    assert_equal 5, setting.hyperliquid_leverage
    assert_equal false, setting.hyperliquid_cross_margin
  end

  test "should create setting if none exists" do
    settings(:one).destroy

    assert_difference "Setting.count", 1 do
      patch settings_path, params: { setting: { hyperliquid_leverage: 10, hyperliquid_cross_margin: true } }
    end
    assert_redirected_to edit_settings_path

    setting = users(:one).reload.setting
    assert_equal 10, setting.hyperliquid_leverage
    assert_equal true, setting.hyperliquid_cross_margin
  end

  test "should reject invalid leverage" do
    patch settings_path, params: { setting: { hyperliquid_leverage: 0 } }
    assert_response :unprocessable_entity
  end

  private

  def create_extended_position
    wallet = Wallet.create!(
      user: users(:one),
      network: networks(:base),
      address: "0x#{SecureRandom.hex(20)}"
    )
    position = Position.create!(
      user: users(:one),
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
  end
end
