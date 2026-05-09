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
      depositor_address: position.wallet.address,
      account_address: position.wallet.address,
      token_id: position.external_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: 77,
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
      assert_equal position.wallet.address, report.fetch(:position_wallet_address)
      assert_equal position.wallet.address, report.fetch(:wallet_address)
      assert_equal position.wallet.address, report.fetch(:depositor_address)
      assert_equal "position_wallet", report.fetch(:depositor_source)
      refute_equal report.fetch(:gauge_address), report.fetch(:depositor_address)
      assert_equal true, report.fetch(:staked)
      assert_equal "12.5", report.fetch(:claimable_aero)
      assert_equal 12_500_000_000_000_000_000, report.fetch(:claimable_aero_raw)
      assert_nil report.fetch(:claimable_aero_usd)
    end
  end

  test "env depositor override is used when position wallet is gauge" do
    gauge = "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28"
    depositor = "0x5ec8cd4881eba87279f5f243eb89ea9383e677c6"
    position = create_aerodrome_position(wallet_address: gauge)
    reward_data = AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: gauge,
      depositor_address: depositor,
      account_address: depositor,
      token_id: position.external_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: 77,
      reward_token_address: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      claimable_aero_raw: 12_500_000_000_000_000_000,
      claimable_aero: BigDecimal("12.5"),
      claimable_aero_usd: nil,
      warnings: [],
      blockers: []
    )
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) do |pool_address|
      raise "unexpected pool" unless pool_address == position.pool_address

      gauge
    end
    service.define_singleton_method(:reward_state_with_gauge) do |pool_address:, gauge_address:, depositor_address:, token_id:|
      raise "unexpected pool" unless pool_address == position.pool_address
      raise "unexpected gauge" unless gauge_address == gauge
      raise "unexpected depositor" unless depositor_address == depositor
      raise "unexpected token" unless token_id == position.external_id

      reward_data
    end

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_REWARDS_DEPOSITOR_ADDRESS" => depositor
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal gauge, report.fetch(:position_wallet_address)
      assert_equal gauge, report.fetch(:wallet_address)
      assert_equal gauge, report.fetch(:gauge_address)
      assert_equal depositor, report.fetch(:depositor_address)
      assert_equal "env", report.fetch(:depositor_source)
      assert_equal true, report.fetch(:staked)
      assert_equal "12.5", report.fetch(:claimable_aero)
    end
  end

  test "fallback depositor equal to gauge warns and does not call earned path" do
    gauge = "0xa0b61fdb9f1fb9b917fe38b49427fd4d87472d28"
    create_aerodrome_position(wallet_address: gauge)
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) { |_pool_address| gauge }
    service.define_singleton_method(:reward_state_with_gauge) do |**_kwargs|
      raise "earned path should not be called when selected depositor is gauge"
    end

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_REWARDS_DEPOSITOR_ADDRESS" => nil
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "WARN", report.fetch(:status)
      assert_equal gauge, report.fetch(:position_wallet_address)
      assert_equal gauge, report.fetch(:depositor_address)
      assert_equal "position_wallet", report.fetch(:depositor_source)
      assert_equal gauge, report.fetch(:gauge_address)
      assert_nil report.fetch(:claimable_aero)
      assert_includes report.fetch(:warnings), "selected depositor is the gauge; set AERODROME_REWARDS_DEPOSITOR_ADDRESS to the staking wallet"
    end
  end

  test "unsupported reward API is reported as warning" do
    position = create_aerodrome_position
    reward_data = AerodromeRewardsService::RewardData.new(
      status: "unavailable",
      pool_address: position.pool_address,
      gauge_address: nil,
      depositor_address: position.wallet.address,
      account_address: position.wallet.address,
      token_id: position.external_id,
      staked: nil,
      staked_token_ids: nil,
      reward_rate_raw: nil,
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
      object.define_singleton_method(:gauge_for_pool) do |pool_address|
        raise "unexpected pool" unless pool_address == position.pool_address

        reward_data.gauge_address || "0x1111111111111111111111111111111111111111"
      end
      object.define_singleton_method(:reward_state_with_gauge) do |pool_address:, gauge_address:, depositor_address:, token_id:|
        raise "unexpected pool" unless pool_address == position.pool_address
        raise "unexpected gauge" unless gauge_address == (reward_data.gauge_address || "0x1111111111111111111111111111111111111111")
        raise "unexpected depositor" unless depositor_address == position.wallet.address
        raise "unexpected token" unless token_id == position.external_id

        reward_data
      end
    end
  end

  def create_aerodrome_position(wallet_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701")
    Position.create!(
      user: users(:one),
      wallet: base_wallet(wallet_address),
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

  def base_wallet(address = "0x23cb5f48fa3f4502232f3442637f90e8e3355701")
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: address
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
