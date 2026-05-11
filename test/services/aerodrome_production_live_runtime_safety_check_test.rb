require "test_helper"

class AerodromeProductionLiveRuntimeSafetyCheckTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_ENABLED" => "true",
      "AERODROME_HEDGE_PAUSED" => "false",
      "AERODROME_PRODUCTION_LIVE_ENABLED" => "true",
      "AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN" => "true",
      "AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR" => "true",
      "AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL" => "true",
      "AERODROME_PRODUCTION_LIVE_CONFIRM" => AerodromeProductionLiveRuntimeSafetyCheck::CONFIRMATION,
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => AerodromeLiveEmergencyClose::CONFIRMATION,
      "AERODROME_MAX_SHORT_ETH" => "0.55",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "1300"
    }
  end

  test "allows supervised production cap tier within hard ceiling" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.40")).report

        assert_equal "PASS", report.fetch(:status)
        assert_empty report.fetch(:blockers)
      end
    end
  end

  test "blocks configured max ETH over production hard ceiling" do
    with_position_and_hedge do |hedge|
      with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "0.751")) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.40")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "Configured max ETH <= production hard ceiling: 0.751"
      end
    end
  end

  test "blocks configured max notional over production hard ceiling" do
    with_position_and_hedge do |hedge|
      with_env(@env.merge("AERODROME_MAX_SHORT_NOTIONAL_USD" => "2001")) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.40")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "Configured max notional <= production hard ceiling: 2001.0"
      end
    end
  end

  test "blocks actual ETH over env max" do
    with_position_and_hedge do |hedge|
      with_env(@env) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.56")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "ETH short <= max ETH: 0.56"
      end
    end
  end

  test "blocks actual notional over env max" do
    with_position_and_hedge do |hedge|
      with_env(@env.merge("AERODROME_MAX_SHORT_NOTIONAL_USD" => "900")) do
        report = build_service(hedge: hedge, eth_position: eth_position("-0.40")).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "ETH notional <= max notional: 920.0"
      end
    end
  end

  private

  def build_service(hedge:, eth_position:)
    AerodromeProductionLiveRuntimeSafetyCheck.new(
      hedge: hedge,
      eth_position: eth_position,
      log_dirs: [ Rails.root.join("tmp", "aerodrome_runtime_safety_test", SecureRandom.hex(4)) ]
    )
  end

  def with_position_and_hedge
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.01", tolerance: "0.05", active: true)
    yield hedge
  ensure
    position&.destroy
  end

  def create_aerodrome_position
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
    Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.1",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
