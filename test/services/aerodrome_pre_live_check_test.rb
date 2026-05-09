require "test_helper"

class AerodromePreLiveCheckTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true",
      "AERODROME_MAX_LEVERAGE" => "1",
      "AERODROME_MAX_SHORT_ETH" => "1",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2000",
      "BASE_RPC_URL" => "https://base.example/rpc",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "315985",
      "AERODROME_USDC_ADDRESS" => "0xusdc",
      "AERODROME_WETH_ADDRESS" => "0xweth"
    }
    users(:one).setting.update!(hyperliquid_leverage: 1)
  end

  test "missing env values produce blockers" do
    with_env(@env.merge("BASE_RPC_URL" => nil, "AERODROME_MAX_SHORT_ETH" => nil)) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "BASE_RPC_URL present"
      assert_includes report.fetch(:blockers), "AERODROME_MAX_SHORT_ETH present"
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:orders_enabled)
      assert_equal false, report.fetch(:hyperliquid_execution)
    end
  end

  test "missing Aerodrome position produces blocker" do
    with_env(@env) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "Aerodrome dex exists"
    end
  end

  test "complete env db risk limits and rehearsal evidence pass" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)

    with_env(@env) do
      assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
        report = AerodromePreLiveCheck.new.report

        assert_equal "PASS", report.fetch(:status)
        assert_empty report.fetch(:blockers)
        assert_empty report.fetch(:warnings)
      end
    end
  ensure
    position&.destroy
  end

  test "successful WETH open rebalance and close history are detected" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)

    with_env(@env) do
      checks = AerodromePreLiveCheck.new.report.dig(:checks, :rehearsal_evidence)
      passed_names = checks.select { |check| check.fetch(:status) == "pass" }.map { |check| check.fetch(:name) }

      assert_includes passed_names, "Hedge #{hedge.id} WETH success open exists"
      assert_includes passed_names, "Hedge #{hedge.id} WETH success rebalance up/down exists"
      assert_includes passed_names, "Hedge #{hedge.id} WETH success close-to-zero exists"
    end
  ensure
    position&.destroy
  end

  test "successful USDC rebalance is blocker" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)
    create_rebalance!(hedge, asset: "USDC", old_short_size: "0", new_short_size: "10", status: ShortRebalance::STATUS_SUCCESS)

    with_env(@env) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "Hedge #{hedge.id} has no successful USDC rebalance"
    end
  ensure
    position&.destroy
  end

  test "failed WETH rebalance after close is warning" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)
    create_rebalance!(
      hedge,
      asset: "WETH",
      old_short_size: "0.1",
      new_short_size: "0.1",
      status: ShortRebalance::STATUS_FAILED,
      rebalanced_at: 1.minute.from_now
    )

    with_env(@env) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "WARN", report.fetch(:status)
      assert_includes report.fetch(:warnings), "Hedge #{hedge.id} no failed WETH rebalances after last close"
      assert_includes report.fetch(:warnings), "Hedge #{hedge.id} historical failed WETH rebalances"
    end
  ensure
    position&.destroy
  end

  test "optional Hyperliquid readback uses mocked get_position only" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)
    service = ReadOnlyHyperliquidMock.new({ asset: "ETH", size: BigDecimal("-0.1") })

    with_env(@env) do
      report = AerodromePreLiveCheck.new(check_hyperliquid: true, hyperliquid_service: service).report

      assert_equal [ "ETH" ], service.reads
      assert_empty service.order_calls
      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "No open ETH short while Aerodrome hedge disabled and paused: 0.1"
    end
  ensure
    position&.destroy
  end

  test "pre live check reports live approval status" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)

    with_env(@env.merge("AERODROME_LIVE_APPROVED" => "true")) do
      checks = AerodromePreLiveCheck.new.report.dig(:checks, :env)
      live_check = checks.find { |check| check.fetch(:name) == "AERODROME_LIVE_APPROVED status" }

      assert_equal "pass", live_check.fetch(:status)
      assert_equal "true", live_check.fetch(:value)
    end
  ensure
    position&.destroy
  end

  test "pre live check blocks mainnet without live approval" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)

    with_env(@env.merge("HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "false")) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "Hyperliquid mainnet requires AERODROME_LIVE_APPROVED=true: HYPERLIQUID_TESTNET=\"false\", AERODROME_LIVE_APPROVED=false"
    end
  ensure
    position&.destroy
  end

  test "pre live check warns mainnet live approval is not execution permission" do
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_successful_rehearsal!(hedge)

    with_env(@env.merge("HYPERLIQUID_TESTNET" => "false", "AERODROME_LIVE_APPROVED" => "true")) do
      report = AerodromePreLiveCheck.new.report

      assert_equal "WARN", report.fetch(:status)
      assert_includes report.fetch(:warnings), "Live approval requires separate operator procedure: pre-live PASS is not execution permission"
    end
  ensure
    position&.destroy
  end

  private

  class ReadOnlyHyperliquidMock
    attr_reader :reads, :order_calls

    def initialize(position)
      @position = position
      @reads = []
      @order_calls = []
    end

    def get_position(asset)
      @reads << asset
      @position
    end

    def open_short(*)
      @order_calls << :open_short
      raise "order method should not be called"
    end

    def close_short(*)
      @order_calls << :close_short
      raise "order method should not be called"
    end

    def set_leverage(*)
      @order_calls << :set_leverage
      raise "order method should not be called"
    end
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
      asset0_amount: "1.0",
      asset1_amount: "500.0",
      asset0_price_usd: "2000.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def create_successful_rehearsal!(hedge)
    create_rebalance!(hedge, asset: "WETH", old_short_size: "0", new_short_size: "0.5")
    create_rebalance!(hedge, asset: "WETH", old_short_size: "0.5", new_short_size: "0.75")
    create_rebalance!(hedge, asset: "WETH", old_short_size: "0.75", new_short_size: "0")
  end

  def create_rebalance!(hedge, attributes)
    ShortRebalance.create!(
      {
        hedge: hedge,
        realized_pnl: "0",
        status: ShortRebalance::STATUS_SUCCESS,
        rebalanced_at: Time.current
      }.merge(attributes)
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
