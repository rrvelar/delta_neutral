require "test_helper"

class MellowRewardsRouteDiscoveryTest < ActiveSupport::TestCase
  test "reports unavailable direct gauge route when strategy token is not staked" do
    position = create_mellow_position
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |token_id| token_id == "71261528" ? "0xowner" : raise("unexpected token") }
    rewards = Object.new
    rewards.define_singleton_method(:gauge_for_pool) { |_pool| "0x1111111111111111111111111111111111111111" }
    rewards.define_singleton_method(:staked_contains) { |_gauge, _depositor, token_id| token_id == "71261528" ? false : raise("unexpected token") }

    report = MellowRewardsRouteDiscovery.new(position: position, slipstream_service: slipstream, rewards_service: rewards).report

    assert_equal "71261528", report.resolved_strategy_token_id
    assert_equal "0xowner", report.owner_address
    assert_equal "0x1111111111111111111111111111111111111111", report.gauge_address
    assert_equal false, report.gauge_staked
    assert_equal "unavailable", report.reward_route_status
    assert_match "No direct gauge stake detected", report.stop_reason
  end

  test "reports estimated direct gauge route when strategy token is staked" do
    position = create_mellow_position
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| nil }
    rewards = Object.new
    rewards.define_singleton_method(:gauge_for_pool) { |_pool| "0x1111111111111111111111111111111111111111" }
    rewards.define_singleton_method(:staked_contains) { |_gauge, _depositor, _token_id| true }
    rewards.define_singleton_method(:reward_token) { |_gauge| "0x940181a94a35a4569e4529a3cdfb74e38fd98631" }
    rewards.define_singleton_method(:claimable_for_staked_token) do |gauge_address:, token_id:, account_address:|
      { method: "CLGauge.earned(address,uint256)", raw: 100, error: nil, account_address: account_address }
    end

    report = MellowRewardsRouteDiscovery.new(position: position, slipstream_service: slipstream, rewards_service: rewards).report

    assert_equal true, report.gauge_staked
    assert_equal "estimated", report.reward_route_status
    assert_nil report.stop_reason
  end

  test "ownerOf equal to gauge marks strategy token staked even when direct depositor is not staked" do
    position = create_mellow_position
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| gauge }
    rewards = Object.new
    rewards.define_singleton_method(:gauge_for_pool) { |_pool| gauge }
    rewards.define_singleton_method(:staked_contains) { |_gauge, _depositor, _token_id| false }
    rewards.define_singleton_method(:deposited_account_for_token) { |_gauge, _token_id| "0x5555555555555555555555555555555555555555" }
    rewards.define_singleton_method(:reward_token) { |_gauge| "0x940181a94a35a4569e4529a3cdfb74e38fd98631" }
    rewards.define_singleton_method(:claimable_for_staked_token) do |gauge_address:, token_id:, account_address:|
      raise "unexpected gauge" unless gauge_address == gauge
      raise "unexpected token" unless token_id == "71261528"
      raise "unexpected account" unless account_address == "0x5555555555555555555555555555555555555555"

      { method: "CLGauge.earned(address,uint256)", raw: 100, error: nil, account_address: account_address }
    end

    report = MellowRewardsRouteDiscovery.new(position: position, slipstream_service: slipstream, rewards_service: rewards).report

    assert_equal true, report.strategy_token_staked_in_gauge
    assert_equal false, report.direct_depositor_staked
    assert_equal "estimated", report.reward_route_status
    assert_nil report.stop_reason
  end

  test "ownerOf equal to gauge with zero reward read is verified zero" do
    position = create_mellow_position
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| gauge }
    rewards = Object.new
    rewards.define_singleton_method(:gauge_for_pool) { |_pool| gauge }
    rewards.define_singleton_method(:staked_contains) { |_gauge, _depositor, _token_id| false }
    rewards.define_singleton_method(:deposited_account_for_token) { |_gauge, _token_id| "0x5555555555555555555555555555555555555555" }
    rewards.define_singleton_method(:reward_token) { |_gauge| "0x940181a94a35a4569e4529a3cdfb74e38fd98631" }
    rewards.define_singleton_method(:claimable_for_staked_token) do |gauge_address:, token_id:, account_address:|
      { method: "CLGauge.earned(address,uint256)", raw: 0, error: nil, account_address: account_address }
    end

    report = MellowRewardsRouteDiscovery.new(position: position, slipstream_service: slipstream, rewards_service: rewards).report

    assert_equal true, report.strategy_token_staked_in_gauge
    assert_equal "verified_zero", report.reward_route_status
  end

  test "ownerOf equal to gauge with reward read failure is unavailable with precise reason" do
    position = create_mellow_position
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| gauge }
    rewards = Object.new
    rewards.define_singleton_method(:gauge_for_pool) { |_pool| gauge }
    rewards.define_singleton_method(:staked_contains) { |_gauge, _depositor, _token_id| false }
    rewards.define_singleton_method(:deposited_account_for_token) { |_gauge, _token_id| "0x5555555555555555555555555555555555555555" }
    rewards.define_singleton_method(:reward_token) { |_gauge| "0x940181a94a35a4569e4529a3cdfb74e38fd98631" }
    rewards.define_singleton_method(:claimable_for_staked_token) do |gauge_address:, token_id:, account_address:|
      { method: "CLGauge.rewards(uint256)", raw: nil, error: "earned reverted; rewards reverted", account_address: account_address }
    end

    report = MellowRewardsRouteDiscovery.new(position: position, slipstream_service: slipstream, rewards_service: rewards).report

    assert_equal true, report.strategy_token_staked_in_gauge
    assert_equal "unavailable", report.reward_route_status
    assert_match "Strategy token is staked in gauge, but no supported reward read method succeeded", report.stop_reason
  end

  private

  def create_mellow_position
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
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      mellow_metadata: JSON.generate("strategy_token_id" => "71261528", "user_share_percent" => "1.25"),
      active: true
    )
  end
end
