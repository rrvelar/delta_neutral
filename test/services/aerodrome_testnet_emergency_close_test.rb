require "test_helper"

class AerodromeTestnetEmergencyCloseTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "AERODROME_CLOSE_RETRY_ATTEMPTS" => "2",
      "AERODROME_CLOSE_RETRY_SLEEP_SECONDS" => "0"
    }
  end

  test "refuses when Hyperliquid testnet is false" do
    with_env(@env.merge("HYPERLIQUID_TESTNET" => "false")) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "failed", report.fetch(:status)
      assert_includes report.fetch(:errors), "HYPERLIQUID_TESTNET must be true"
    end
  end

  test "refuses when Aerodrome live approved is true" do
    with_env(@env.merge("AERODROME_LIVE_APPROVED" => "true")) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "failed", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_LIVE_APPROVED must be false"
    end
  end

  test "noop when ETH position is nil" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ nil ])

    with_env(@env) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "noop", report.fetch(:status)
      assert_empty report.fetch(:attempts)
      assert_empty service.closes
    end
  ensure
    position&.destroy
  end

  test "closes existing ETH short with explicit size" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), nil ])

    with_env(@env) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "success", report.fetch(:status)
      assert_equal [ { asset: "ETH", size: BigDecimal("0.25") } ], service.closes
      assert_equal "-0.25", report.fetch(:before_position).fetch(:size)
      assert_nil report.fetch(:after_position)
    end
  ensure
    position&.destroy
  end

  test "retries when first attempt raises network error and second succeeds" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(
      positions: [ eth_position("-0.25"), eth_position("-0.25"), nil ],
      close_errors: [ Hyperliquid::NetworkError.new("getaddrinfo api.hyperliquid-testnet.xyz") ]
    )

    with_env(@env.merge("AERODROME_CLOSE_RETRY_ATTEMPTS" => "3")) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "success", report.fetch(:status)
      assert_equal 2, service.closes.size
      assert_equal [ "error", "submitted" ], report.fetch(:attempts).map { |attempt| attempt.fetch(:status) }
      assert_match "getaddrinfo", report.fetch(:errors).first
    end
  ensure
    position&.destroy
  end

  test "fails after max retries if position remains" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), eth_position("-0.25"), eth_position("-0.25") ])

    with_env(@env.merge("AERODROME_CLOSE_RETRY_ATTEMPTS" => "2")) do
      report = AerodromeTestnetEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "failed", report.fetch(:status)
      assert_equal 2, service.closes.size
      assert_equal "-0.25", report.fetch(:after_position).fetch(:size)
    end
  ensure
    position&.destroy
  end

  test "never calls USDC close" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), nil ])

    with_env(@env) do
      AerodromeTestnetEmergencyClose.new(hyperliquid_service: service).report
    end

    assert_equal [ "ETH", "ETH" ], service.reads
    assert_equal [ "ETH" ], service.closes.map { |close| close.fetch(:asset) }
  ensure
    position&.destroy
  end

  private

  class EmergencyCloseMock
    attr_reader :reads, :closes

    def initialize(positions: [], close_errors: [])
      @positions = positions
      @close_errors = close_errors
      @reads = []
      @closes = []
    end

    def get_position(asset)
      raise "USDC must not be read" if asset == "USDC"

      @reads << asset
      @positions.empty? ? nil : @positions.shift
    end

    def close_short(asset:, size:)
      raise "USDC must not be closed" if asset == "USDC"

      @closes << { asset: asset, size: size }
      error = @close_errors.shift
      raise error if error

      { "status" => "ok" }
    end
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
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

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
