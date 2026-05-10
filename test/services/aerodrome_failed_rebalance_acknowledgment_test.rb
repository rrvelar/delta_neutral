require "test_helper"

class AerodromeFailedRebalanceAcknowledgmentTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_ACK_FAILED_REBALANCE_ID" => nil,
      "AERODROME_ACK_FAILED_REBALANCE_CONFIRM" => nil
    }
  end

  test "refuses without env id and confirm" do
    with_env(@env) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: ReadOnlyHyperliquidMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_ACK_FAILED_REBALANCE_ID must be set"
    end
  end

  test "refuses without confirmation" do
    rebalance = create_failed_rebalance

    with_env(
      "AERODROME_ACK_FAILED_REBALANCE_ID" => rebalance.id.to_s,
      "AERODROME_ACK_FAILED_REBALANCE_CONFIRM" => "wrong"
    ) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: ReadOnlyHyperliquidMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes(
        report.fetch(:errors),
        "AERODROME_ACK_FAILED_REBALANCE_CONFIRM must equal #{AerodromeFailedRebalanceAcknowledgment::CONFIRMATION}"
      )
    end
  ensure
    rebalance&.hedge&.position&.destroy
  end

  test "refuses failed row with nonzero old or new size" do
    rebalance = create_failed_rebalance(old_short_size: "0.01")

    with_ack_env(rebalance) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: ReadOnlyHyperliquidMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "old_short_size must be 0"
      refute_includes rebalance.reload.message, AerodromeFailedRebalanceAcknowledgment::MARKER
    end
  ensure
    rebalance&.hedge&.position&.destroy
  end

  test "refuses if mainnet ETH position exists" do
    rebalance = create_failed_rebalance
    service = ReadOnlyHyperliquidMock.new(position: { asset: "ETH", size: BigDecimal("-0.0111") })

    with_ack_env(rebalance) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: service).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "mainnet ETH position must be nil before acknowledgment"
      assert_equal [ "ETH" ], service.reads
      assert_empty service.order_calls
    end
  ensure
    rebalance&.hedge&.position&.destroy
  end

  test "appends marker for eligible row when mainnet ETH position nil" do
    rebalance = create_failed_rebalance
    service = ReadOnlyHyperliquidMock.new(position: nil)

    with_ack_env(rebalance) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: service).report

      assert_equal "success", report.fetch(:status)
      assert_equal true, report.fetch(:database_write)
      assert_equal rebalance.id, report.fetch(:rebalance_id)
      assert_includes rebalance.reload.message, AerodromeFailedRebalanceAcknowledgment::MARKER
      assert_equal ShortRebalance::STATUS_FAILED, rebalance.status
      assert_equal BigDecimal("0"), rebalance.old_short_size
      assert_equal BigDecimal("0"), rebalance.new_short_size
      assert_empty service.order_calls
    end
  ensure
    rebalance&.hedge&.position&.destroy
  end

  test "does not duplicate marker" do
    rebalance = create_failed_rebalance(message: "reviewed\n#{AerodromeFailedRebalanceAcknowledgment::MARKER}")

    with_ack_env(rebalance) do
      report = AerodromeFailedRebalanceAcknowledgment.new(hyperliquid_service: ReadOnlyHyperliquidMock.new).report

      assert_equal "success", report.fetch(:status)
      assert_equal 1, rebalance.reload.message.scan(AerodromeFailedRebalanceAcknowledgment::MARKER).size
    end
  ensure
    rebalance&.hedge&.position&.destroy
  end

  private

  class ReadOnlyHyperliquidMock
    attr_reader :reads, :order_calls

    def initialize(position: nil)
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
      raise "open_short must not be called"
    end

    def close_short(*)
      @order_calls << :close_short
      raise "close_short must not be called"
    end

    def set_leverage(*)
      @order_calls << :set_leverage
      raise "set_leverage must not be called"
    end
  end

  def create_failed_rebalance(old_short_size: "0", new_short_size: "0", message: "Attempted rebalance failed")
    position = create_aerodrome_position
    hedge = Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: old_short_size,
      new_short_size: new_short_size,
      realized_pnl: "0",
      status: ShortRebalance::STATUS_FAILED,
      message: message,
      rebalanced_at: Time.current
    )
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

  def with_ack_env(rebalance)
    with_env(
      "AERODROME_ACK_FAILED_REBALANCE_ID" => rebalance.id.to_s,
      "AERODROME_ACK_FAILED_REBALANCE_CONFIRM" => AerodromeFailedRebalanceAcknowledgment::CONFIRMATION
    ) { yield }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
