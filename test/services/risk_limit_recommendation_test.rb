require "test_helper"

class RiskLimitRecommendationTest < ActiveSupport::TestCase
  setup do
    RiskSetting.delete_all
    RiskSettingAudit.delete_all
  end

  test "detects target above hard max and includes runtime and emergency requirements" do
    position = aerodrome_position
    with_env(
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD" => "3000",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "3000"
    ) do
      report = RiskLimitRecommendation.new(position: position, venue: "ethereal").report

      assert_equal true, report.fetch(:hard_ceiling_raise_required)
      keys = report.fetch(:required_changes).map { |change| change.fetch(:key) }
      assert_includes keys, "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH"
      assert_includes keys, "ETHEREAL_MAX_SHORT_ETH"
      assert_includes keys, "ETHEREAL_MAX_ORDER_SIZE_ETH"
      assert_includes keys, "ETHEREAL_MAX_NOTIONAL_USD"
      assert_includes keys, "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      assert_equal RiskSettings::HARD_INCREASE_CONFIRMATION, report.fetch(:confirmation_required)
      assert_equal 0, report.fetch(:orders_submitted)
      assert_equal 0, report.fetch(:signatures_created)
    end
  end

  test "apply recommended refuses weak confirmation and succeeds with hard confirmation" do
    position = aerodrome_position
    recommendation = RiskLimitRecommendation.new(position: position, venue: "ethereal")
    weak = recommendation.apply!(confirmation: RiskSettings::INCREASE_CONFIRMATION)
    strong = recommendation.apply!(updated_by: users(:one), confirmation: RiskSettings::HARD_INCREASE_CONFIRMATION)

    assert_equal false, weak.ok
    assert_includes weak.errors, "confirmation must equal #{RiskSettings::HARD_INCREASE_CONFIRMATION}"
    assert_equal true, strong.ok
    assert RiskSetting.find_by(key: "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH")
    assert RiskSetting.find_by(key: "ETHEREAL_MAX_SHORT_ETH")
    assert RiskSetting.find_by(key: "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
    assert_operator RiskSettingAudit.count, :>=, strong.applied.size
  end

  private

  def aerodrome_position
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.8"),
      asset1_amount: BigDecimal("1000"),
      asset0_price_usd: BigDecimal("2500"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "71674988",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: BigDecimal("1.8"),
      combined_short_eth: BigDecimal("0"),
      drift_eth: BigDecimal("1.8"),
      inside_tolerance: false
    )
    position
  end

  def with_env(overrides)
    old = overrides.to_h { |key, _value| [ key, ENV.fetch(key, nil) ] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
