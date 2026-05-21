require "test_helper"

class AerodromeProductionDashboardStatusTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => "1.5",
      "AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH" => "1.6",
      "AERODROME_MAX_SHORT_ETH" => "1.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "1.6"
    }
  end

  test "reports production cap state and drift within caps" do
    with_position_and_hedge do |position|
      with_env(@env) do
        report = build_service(position: position, eth_position: eth_position("-1.0")).report

        assert_equal false, report.fetch(:database_write)
        assert_equal false, report.fetch(:orders_enabled)
        assert_equal false, report.fetch(:hyperliquid_execution)
        assert_equal "1.5", report.fetch(:current_configured_hedge_cap_eth)
        assert_equal "1.5", report.fetch(:hard_ceiling).fetch(:hard_max_short_eth)
        assert_equal "1.25", report.fetch(:current_aerodrome_lp_weth_amount)
        assert_equal "1.25", report.fetch(:target_hedge_eth)
        assert_equal "0.25", report.fetch(:drift_eth)
        assert_equal true, report.fetch(:within_caps)
        assert_empty report.fetch(:blockers)
      end
    end
  end

  test "reports blocker when runtime cap exceeds hard ceiling" do
    with_position_and_hedge do |position|
      with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "1.6")) do
        report = build_service(position: position, eth_position: eth_position("-1.0")).report

        assert_equal false, report.fetch(:within_caps)
        assert_includes report.fetch(:blockers), "AERODROME_MAX_SHORT_ETH must be configured and <= AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH (1.5)"
      end
    end
  end

  test "fails closed when hard ceiling is missing" do
    with_position_and_hedge do |position|
      with_env(@env.merge("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH" => nil)) do
        report = build_service(position: position, eth_position: eth_position("-1.0")).report

        assert_equal false, report.fetch(:within_caps)
        assert_includes report.fetch(:blockers), "AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH must be configured and positive"
      end
    end
  end

  private

  class HyperliquidReadMock
    def initialize(position)
      @position = position
    end

    def get_position(asset)
      raise "unexpected asset" unless asset == "ETH"

      @position
    end
  end

  def build_service(position:, eth_position:)
    AerodromeProductionDashboardStatus.new(
      position: position,
      hyperliquid_service: HyperliquidReadMock.new(eth_position)
    )
  end

  def with_position_and_hedge
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)
    yield position
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
      asset0_amount: "1.25",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: "70184676",
      pool_address: "0xpool",
      active: true
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size), mark_price: BigDecimal("2300") }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
