require "test_helper"

class AerodromeLivePreflightCheckTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "false",
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_MAX_LEVERAGE" => "1",
      "AERODROME_MAX_SHORT_ETH" => "1",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2000",
      "AERODROME_MIN_ORDER_NOTIONAL_USD" => "10",
      "BASE_RPC_URL" => "https://base.example/rpc",
      "HYPERLIQUID_WALLET_ADDRESS" => "0x5eC8Cd4881eba87279f5F243Eb89EA9383E677c6",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "315985",
      "AERODROME_USDC_ADDRESS" => "0xusdc",
      "AERODROME_WETH_ADDRESS" => "0xweth"
    }
    users(:one).setting.update!(hyperliquid_leverage: 1)
  end

  test "blocks if Hyperliquid testnet is true" do
    with_env(@env.merge("HYPERLIQUID_TESTNET" => "true")) do
      report = AerodromeLivePreflightCheck.new.report

      assert_equal "BLOCKED", report.fetch(:status)
      assert_includes report.fetch(:blockers), "HYPERLIQUID_TESTNET is false: \"true\""
    end
  end

  test "blocks if hedge enabled" do
    with_complete_state do
      with_env(@env.merge("AERODROME_HEDGE_ENABLED" => "true")) do
        report = AerodromeLivePreflightCheck.new.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "AERODROME_HEDGE_ENABLED is false: \"true\""
      end
    end
  end

  test "blocks if hedge unpaused" do
    with_complete_state do
      with_env(@env.merge("AERODROME_HEDGE_PAUSED" => "false")) do
        report = AerodromeLivePreflightCheck.new.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "AERODROME_HEDGE_PAUSED is true: \"false\""
      end
    end
  end

  test "blocks if live approved already true during preflight" do
    with_complete_state do
      with_env(@env.merge("AERODROME_LIVE_APPROVED" => "true")) do
        report = AerodromeLivePreflightCheck.new.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "AERODROME_LIVE_APPROVED is false: \"true\""
      end
    end
  end

  test "blocks if target exceeds limits" do
    with_complete_state(asset0_amount: "2.0") do
      with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "0.5")) do
        report = AerodromeLivePreflightCheck.new.report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "Target ETH short <= max: 1.0"
      end
    end
  end

  test "passes with complete safe env db and evidence" do
    with_complete_state do
      with_env(@env) do
        assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
          report = AerodromeLivePreflightCheck.new.report

          assert_equal "PASS", report.fetch(:status)
          assert_empty report.fetch(:blockers)
        end
      end
    end
  end

  test "Hyperliquid readback uses mocked read-only calls only" do
    service = ReadOnlyHyperliquidMock.new(position: nil)

    with_complete_state do
      with_env(@env.merge("CHECK_HYPERLIQUID" => "true")) do
        report = AerodromeLivePreflightCheck.new(check_hyperliquid: true, hyperliquid_service: service).report

        assert_equal "PASS", report.fetch(:status)
        assert_equal [ "ETH" ], service.reads
        assert_equal [ "0x5eC8Cd4881eba87279f5F243Eb89EA9383E677c6" ], service.balance_reads
        assert_empty service.order_calls
        balance_check = report.dig(:checks, :hyperliquid_readback).find { |check| check[:name] == "Hyperliquid account balance read-only" }
        assert_equal "pass", balance_check.fetch(:status)
        assert_equal "1000.0", balance_check.fetch(:account_value)
        assert_equal "1000.0", balance_check.fetch(:withdrawable)
        assert_equal "0x5eC8Cd4881eba87279f5F243Eb89EA9383E677c6", balance_check.fetch(:wallet_address)
      end
    end
  end

  test "Hyperliquid balance read failure is clear warning when ETH readback succeeds" do
    service = ReadOnlyHyperliquidMock.new(position: nil, balance_error: RuntimeError.new("Unexpected response status: 422"))

    with_complete_state do
      with_env(@env) do
        report = AerodromeLivePreflightCheck.new(check_hyperliquid: true, hyperliquid_service: service).report

        assert_equal "WARN", report.fetch(:status)
        assert_includes report.fetch(:warnings), "Hyperliquid account balance read-only: Unexpected response status: 422"
        refute report.fetch(:warnings).any? { |warning| warning.include?("Hyperliquid read-only checks") }
        assert_equal [ "ETH" ], service.reads
        assert_empty service.order_calls
      end
    end
  end

  test "Hyperliquid readback blocks if open ETH short exists" do
    service = ReadOnlyHyperliquidMock.new(position: { asset: "ETH", size: BigDecimal("-0.1") })

    with_complete_state do
      with_env(@env) do
        report = AerodromeLivePreflightCheck.new(check_hyperliquid: true, hyperliquid_service: service).report

        assert_equal "BLOCKED", report.fetch(:status)
        assert_includes report.fetch(:blockers), "No open ETH short before first live micro-run: 0.1"
      end
    end
  end

  private

  class ReadOnlyHyperliquidMock
    attr_reader :reads, :balance_reads, :order_calls

    def initialize(position:, balance_error: nil)
      @position = position
      @balance_error = balance_error
      @reads = []
      @balance_reads = []
      @order_calls = []
    end

    def get_position(asset)
      @reads << asset
      @position
    end

    def account_balance(address)
      @balance_reads << address
      raise @balance_error if @balance_error

      { account_value: BigDecimal("1000"), withdrawable: BigDecimal("1000") }
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

  def with_complete_state(asset0_amount: "1.0")
    position = create_aerodrome_position(asset0_amount: asset0_amount)
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    create_rebalance!(hedge, old_short_size: "0", new_short_size: "0.5")
    create_rebalance!(hedge, old_short_size: "0.5", new_short_size: "0.75")
    create_rebalance!(hedge, old_short_size: "0.75", new_short_size: "0")
    yield
  ensure
    position&.destroy
  end

  def create_aerodrome_position(asset0_amount:)
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
      asset0_amount: asset0_amount,
      asset1_amount: "500.0",
      asset0_price_usd: "2000.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def create_rebalance!(hedge, old_short_size:, new_short_size:)
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short_size,
      new_short_size: new_short_size,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.current
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
