require "test_helper"

class AerodromeRewardsCheckTest < ActiveSupport::TestCase
  test "missing voter config produces warning without crashing" do
    create_aerodrome_position

    with_env("AERODROME_VOTER_ADDRESS" => nil, "AERODROME_REWARDS_ENABLED" => "false") do
      report = AerodromeRewardsCheck.new.report

      assert_equal "WARN", report.fetch(:status)
      assert_nil report.fetch(:gauge_address)
      assert_includes report.fetch(:warnings), "AERODROME_VOTER_ADDRESS is not configured; CL gauge cannot be discovered"
      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:claims_enabled)
    end
  end

  test "mocked reward discovery reports claimable AERO" do
    position = create_aerodrome_position
    reward_data = AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: "0x1111111111111111111111111111111111111111",
      account_address: position.wallet.address,
      token_id: position.external_id,
      staked: true,
      reward_token_address: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      claimable_aero_raw: 12_500_000_000_000_000_000,
      claimable_aero: BigDecimal("12.5"),
      claimable_aero_usd: nil,
      warnings: [],
      blockers: []
    )
    service = reward_service_stub(position, reward_data)

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5", "AERODROME_REWARDS_ENABLED" => "true") do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal "detected", report.fetch(:gauge_status)
      assert_equal "12.5", report.fetch(:claimable_aero)
      assert_nil report.fetch(:claimable_aero_usd)
    end
  end

  test "unsupported reward API is reported as warning" do
    position = create_aerodrome_position
    reward_data = AerodromeRewardsService::RewardData.new(
      status: "unavailable",
      pool_address: position.pool_address,
      gauge_address: nil,
      account_address: position.wallet.address,
      token_id: position.external_id,
      staked: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: [ "reward read unavailable: CLGauge earned unsupported" ],
      blockers: []
    )
    service = reward_service_stub(position, reward_data)

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5", "AERODROME_REWARDS_ENABLED" => "true") do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "WARN", report.fetch(:status)
      assert_includes report.fetch(:warnings), "reward read unavailable: CLGauge earned unsupported"
    end
  end

  test "missing active Aerodrome position is blocked" do
    Dex.find_or_create_by!(name: "aerodrome_slipstream")

    report = AerodromeRewardsCheck.new.report

    assert_equal "BLOCKED", report.fetch(:status)
    assert_includes report.fetch(:blockers), "No active Aerodrome Slipstream position found"
  end

  private

  def reward_service_stub(position, reward_data)
    Object.new.tap do |object|
      object.define_singleton_method(:reward_state) do |pool_address:, account_address:, token_id:|
        raise "unexpected pool" unless pool_address == position.pool_address
        raise "unexpected account" unless account_address == position.wallet.address
        raise "unexpected token" unless token_id == position.external_id

        reward_data
      end
    end
  end

  def create_aerodrome_position
    Position.create!(
      user: users(:one),
      wallet: base_wallet,
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

  def base_wallet
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
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
