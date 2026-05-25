require "test_helper"

class AerodromeFeesCheckTest < ActiveSupport::TestCase
  test "missing active Aerodrome position is blocked" do
    Dex.find_or_create_by!(name: "aerodrome_slipstream")

    report = AerodromeFeesCheck.new.report

    assert_equal "BLOCKED", report.fetch(:status)
    assert_includes report.fetch(:blockers), "No active Aerodrome Slipstream position found"
    assert_equal false, report.fetch(:database_write)
    assert_equal false, report.fetch(:transactions_enabled)
    assert_equal false, report.fetch(:collect_enabled)
  end

  test "mocked verified fee read returns fee amounts and USD values" do
    position = create_aerodrome_position
    expected_fee_data = fee_data(position)
    fees_service = Object.new
    fees_service.define_singleton_method(:fees_for_position) do |received_position|
      raise "unexpected position" unless received_position == position

      expected_fee_data
    end

    with_env("AERODROME_VOTER_ADDRESS" => nil) do
      report = AerodromeFeesCheck.new(fees_service: fees_service).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal AerodromeFeesService::SOURCE, report.fetch(:fee_source)
      assert_equal "WETH", report.fetch(:fee0_symbol)
      assert_equal "0.01", report.fetch(:fee0_amount)
      assert_equal "20.0", report.fetch(:fee0_usd)
      assert_equal "USDC", report.fetch(:fee1_symbol)
      assert_equal "3.5", report.fetch(:fee1_amount)
      assert_equal "3.5", report.fetch(:fee1_usd)
      assert_equal "23.5", report.fetch(:total_fees_usd)
      assert_equal "estimated", report.fetch(:value_state)
    end
  end

  test "staked NFT fee read is unavailable instead of fake zero" do
    position = create_aerodrome_position
    rewards_service = Object.new
    rewards_service.define_singleton_method(:gauge_for_pool) do |pool_address|
      raise "unexpected pool" unless pool_address == position.pool_address

      "0x1111111111111111111111111111111111111111"
    end
    rewards_service.define_singleton_method(:staked_contains) do |gauge_address, depositor, token_id|
      raise "unexpected gauge" unless gauge_address == "0x1111111111111111111111111111111111111111"
      raise "unexpected depositor" unless depositor == position.wallet.address
      raise "unexpected token" unless token_id == position.external_id

      true
    end
    fees_service = Object.new
    fees_service.define_singleton_method(:fees_for_position) { |_position| raise "fees should not be read for staked NFT" }

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5") do
      report = AerodromeFeesCheck.new(fees_service: fees_service, rewards_service: rewards_service).report

      assert_equal "WARN", report.fetch(:status)
      assert_equal "unavailable", report.fetch(:fee_source)
      assert_nil report.fetch(:total_fees_usd)
      assert_equal "unavailable", report.fetch(:value_state)
      assert_includes report.fetch(:warnings), "fee read for staked Slipstream NFT is not verified; CL gauge staking receives emissions instead of LP fees"
    end
  end

  test "verified zero fee read is explicit" do
    position = create_aerodrome_position
    fees_service = Object.new
    fees_service.define_singleton_method(:fees_for_position) do |_position|
      AerodromeFeesService::FeeData.new(
        status: "detected",
        fee_source: AerodromeFeesService::SOURCE,
        token_id: position.external_id,
        pool_address: position.pool_address,
        fee0_symbol: "WETH",
        fee0_amount: BigDecimal("0"),
        fee0_usd: BigDecimal("0"),
        fee1_symbol: "USDC",
        fee1_amount: BigDecimal("0"),
        fee1_usd: BigDecimal("0"),
        total_fees_usd: BigDecimal("0"),
        warnings: [],
        blockers: []
      )
    end

    report = AerodromeFeesCheck.new(fees_service: fees_service).report

    assert_equal "verified_zero", report.fetch(:value_state)
    assert_equal "0.0", report.fetch(:total_fees_usd)
  end

  private

  def fee_data(position)
    AerodromeFeesService::FeeData.new(
      status: "detected",
      fee_source: AerodromeFeesService::SOURCE,
      token_id: position.external_id,
      pool_address: position.pool_address,
      fee0_symbol: "WETH",
      fee0_amount: BigDecimal("0.01"),
      fee0_usd: BigDecimal("20"),
      fee1_symbol: "USDC",
      fee1_amount: BigDecimal("3.5"),
      fee1_usd: BigDecimal("3.5"),
      total_fees_usd: BigDecimal("23.5"),
      warnings: [],
      blockers: []
    )
  end

  def create_aerodrome_position
    Position.create!(
      user: users(:one),
      wallet: Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "315985",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
