require "test_helper"

class AerodromeLiveEmergencyCloseTest < ActiveSupport::TestCase
  setup do
    @env = {
      "HYPERLIQUID_TESTNET" => "false",
      "AERODROME_LIVE_APPROVED" => "true",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => "true",
      "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => AerodromeLiveEmergencyClose::CONFIRMATION,
      "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.5",
      "AERODROME_LIVE_CLOSE_RETRY_ATTEMPTS" => "2",
      "AERODROME_LIVE_CLOSE_RETRY_SLEEP_SECONDS" => "0"
    }
  end

  test "blocks by default" do
    with_env(@env.keys.to_h { |key| [ key, nil ] }) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "HYPERLIQUID_TESTNET must be false"
      assert_empty report.fetch(:attempts)
    end
  end

  test "blocks on testnet" do
    with_env(@env.merge("HYPERLIQUID_TESTNET" => "true")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "HYPERLIQUID_TESTNET must be false"
    end
  end

  test "blocks if live approved false" do
    with_env(@env.merge("AERODROME_LIVE_APPROVED" => "false")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_LIVE_APPROVED must be true"
    end
  end

  test "blocks if not paused" do
    with_env(@env.merge("AERODROME_HEDGE_PAUSED" => "false")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_HEDGE_PAUSED must be true"
    end
  end

  test "blocks if emergency close enabled is missing or false" do
    with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED" => nil)) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true"
    end
  end

  test "blocks if confirmation phrase is wrong" do
    with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM" => "wrong")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{AerodromeLiveEmergencyClose::CONFIRMATION}"
    end
  end

  test "blocks if requested asset is not ETH" do
    with_env(@env) do
      report = AerodromeLiveEmergencyClose.new(asset: "USDC", hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "asset must be ETH"
    end
  end

  test "blocks if no Aerodrome hedge exists" do
    with_env(@env) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: EmergencyCloseMock.new).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "No Aerodrome hedge/position found"
    end
  end

  test "blocks if current ETH short exceeds max" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.75") ])

    with_env(@env.merge("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" => "0.5")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "blocked", report.fetch(:status)
      assert_includes report.fetch(:errors), "current ETH short exceeds AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      assert_empty service.closes
    end
  ensure
    position&.destroy
  end

  test "noop when no ETH short exists" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ nil ])

    with_env(@env) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "noop", report.fetch(:status)
      assert_empty report.fetch(:attempts)
      assert_empty service.closes
    end
  ensure
    position&.destroy
  end

  test "closes ETH with explicit size when all gates pass" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), nil ])

    with_env(@env) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "success", report.fetch(:status)
      assert_equal [ { asset: "ETH", size: BigDecimal("0.25") } ], service.closes
      assert_equal "-0.25", report.fetch(:before_position).fetch(:size)
      assert_nil report.fetch(:after_position)
    end
  ensure
    position&.destroy
  end

  test "retries network failure and succeeds" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(
      positions: [ eth_position("-0.25"), eth_position("-0.25"), nil ],
      close_errors: [ RuntimeError.new("network unavailable") ]
    )

    with_env(@env.merge("AERODROME_LIVE_CLOSE_RETRY_ATTEMPTS" => "3")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "success", report.fetch(:status)
      assert_equal 2, service.closes.size
      assert_equal [ "error", "submitted" ], report.fetch(:attempts).map { |attempt| attempt.fetch(:status) }
      assert_match "network unavailable", report.fetch(:errors).first
    end
  ensure
    position&.destroy
  end

  test "fails after retries if position remains" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), eth_position("-0.25"), eth_position("-0.25") ])

    with_env(@env.merge("AERODROME_LIVE_CLOSE_RETRY_ATTEMPTS" => "2")) do
      report = AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report

      assert_equal "failed", report.fetch(:status)
      assert_equal 2, service.closes.size
      assert_equal "-0.25", report.fetch(:after_position).fetch(:size)
    end
  ensure
    position&.destroy
  end

  test "never touches USDC and never opens or sets leverage" do
    position = create_aerodrome_position
    Hedge.create!(position: position, target: "0.5", tolerance: "0.05", active: true)
    service = EmergencyCloseMock.new(positions: [ eth_position("-0.25"), nil ])

    with_env(@env) do
      AerodromeLiveEmergencyClose.new(hyperliquid_service: service).report
    end

    assert_equal [ "ETH", "ETH" ], service.reads
    assert_equal [ "ETH" ], service.closes.map { |close| close.fetch(:asset) }
    assert_equal false, service.open_short_called
    assert_equal false, service.set_leverage_called
  ensure
    position&.destroy
  end

  private

  class EmergencyCloseMock
    attr_reader :reads, :closes, :open_short_called, :set_leverage_called

    def initialize(positions: [], close_errors: [])
      @positions = positions
      @close_errors = close_errors
      @reads = []
      @closes = []
      @open_short_called = false
      @set_leverage_called = false
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

    def open_short(*)
      @open_short_called = true
      raise "open_short must not be called"
    end

    def set_leverage(*)
      @set_leverage_called = true
      raise "set_leverage must not be called"
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
