require "test_helper"

class SettingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
    RiskSetting.delete_all
    RiskSettingAudit.delete_all
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
    assert_match "Legacy Hyperliquid settings", response.body
    assert_match "Hyperliquid is not a supported current production venue", response.body
  end

  test "edit shows risk settings and updates supported cap with confirmation" do
    get edit_settings_path

    assert_response :success
    assert_match "Risk Limits", response.body
    assert_match "Ethereal max short size, ETH", response.body
    assert_match "ETHEREAL_MAX_SHORT_ETH", response.body
    assert_match "Global max short size, ETH", response.body
    assert_match "(AERODROME_MAX_SHORT_ETH)", response.body
    assert_match "Production hard ceilings", response.body
    assert_match "Production hard max short size", response.body
    assert_match "Runtime max short caps cannot exceed this value", response.body
    assert_match "Not configured. Live hedge is blocked until this cap or an applicable fallback is set.", response.body
    assert_no_match "Hyperliquid max short size", response.body
    assert_select "input[name='confirmation']", count: 1
    assert_select "input[name^='risk_values']", minimum: 1
    assert_select "button", text: "Save", count: 0
    assert_select "button", text: "Apply recommended hard + runtime limits", minimum: 0
    assert_select "button", text: "Save changed settings", count: 1

    assert_difference "RiskSetting.count", 1 do
      patch risk_settings_path, params: {
        key: "ETHEREAL_MAX_SHORT_ETH",
        value: "2.0",
        reason: "new LP size",
        confirmation: RiskSettings::INCREASE_CONFIRMATION
      }
    end

    assert_redirected_to edit_settings_path(anchor: "risk-settings")
    setting = RiskSetting.find_by!(key: "ETHEREAL_MAX_SHORT_ETH")
    assert_equal "2.0", setting.value
    assert_equal users(:one), setting.updated_by
  end

  test "edit shows fallback explanation and current position cap recommendation" do
    position = create_extended_position
    position.update!(source: Position::SOURCE_AERODROME_DIRECT, external_id: "71674988")
    position.hedge.update!(execution_venue: "ethereal")
    position.position_dashboard_snapshot.update!(
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: BigDecimal("1.7"),
      inside_tolerance: false
    )
    RiskSetting.create!(key: "AERODROME_MAX_SHORT_ETH", value: "1.5", updated_by: users(:one), reason: "test fallback")

    get edit_settings_path

    assert_response :success
    assert_match "Current active position", response.body
    assert_match "Position ##{position.id}", response.body
    assert_match "Required hedge: 1.700000 ETH", response.body
    assert_match "Risk blockers:", response.body
    assert_match "Apply recommended hard + runtime limits", response.body
    assert_match "Not configured. Currently using fallback AERODROME_MAX_SHORT_ETH=1.5 ETH.", response.body
    assert_match "ETHEREAL_MAX_SHORT_ETH", response.body
  end

  test "risk setting update uses shared confirmation and rejects invalid confirmation" do
    assert_difference "RiskSetting.count", 1 do
      patch risk_settings_path, params: {
        save_changed: "1",
        risk_values: { "ETHEREAL_MAX_SHORT_ETH" => "2.0" },
        risk_reasons: { "ETHEREAL_MAX_SHORT_ETH" => "shared confirmation test" },
        confirmation: RiskSettings::INCREASE_CONFIRMATION
      }
    end

    assert_redirected_to edit_settings_path(anchor: "risk-settings")

    patch risk_settings_path, params: {
      save_changed: "1",
      risk_values: { "NADO_MAX_SHORT_ETH" => "2.0" },
      confirmation: "wrong"
    }

    assert_response :unprocessable_entity
    assert_match "confirmation must equal #{RiskSettings::INCREASE_CONFIRMATION}", response.body
  end

  test "risk setting update rejects invalid key and value without server error" do
    patch risk_settings_path, params: {
      key: "HYPERLIQUID_MAX_SHORT_ETH",
      value: "2.0",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    }

    assert_response :unprocessable_entity
    assert_match "invalid risk setting key", response.body

    patch risk_settings_path, params: {
      key: "ETHEREAL_MAX_SHORT_ETH",
      value: "0",
      confirmation: RiskSettings::INCREASE_CONFIRMATION
    }

    assert_response :unprocessable_entity
    assert_match "invalid risk setting value", response.body
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
    position
  end
end
