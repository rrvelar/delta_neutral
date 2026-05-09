require "test_helper"

class AerodromeRewardsServiceTest < ActiveSupport::TestCase
  RPC_URL = "https://base.example.com/rpc"
  VOTER = "0x16613524e02ad97edfeF371bc883f2f5d6c480a5".downcase
  AERO = "0x940181a94a35a4569e4529a3cdfb74e38fd98631"
  POOL = "0x90757bd1595ca6e6a011e900e7a22d1a991856a5"
  GAUGE = "0x1111111111111111111111111111111111111111"
  ACCOUNT = "0x23cb5f48fa3f4502232f3442637f90e8e3355701"

  test "discovers gauge and reads claimable AERO" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_results(
      "0x#{word(GAUGE)}",
      "0x#{word(AERO)}",
      "0x#{uint_word(1)}",
      "0x#{uint_word(12_500_000_000_000_000_000)}",
      "0x#{uint_word(18)}"
    )

    result = service.reward_state(pool_address: POOL, account_address: ACCOUNT, token_id: 5016)

    assert_equal "detected", result.status
    assert_equal GAUGE, result.gauge_address
    assert_equal true, result.staked
    assert_equal AERO, result.reward_token_address
    assert_equal 12_500_000_000_000_000_000, result.claimable_aero_raw
    assert_equal BigDecimal("12.5"), result.claimable_aero
    assert_nil result.claimable_aero_usd
    assert_empty result.blockers
  end

  test "zero gauge is handled without crashing" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER)
    stub_rpc_results("0x#{word(AerodromeRewardsService::ZERO_ADDRESS)}")

    result = service.reward_state(pool_address: POOL, account_address: ACCOUNT, token_id: 5016)

    assert_equal "not_configured", result.status
    assert_nil result.gauge_address
    assert_includes result.warnings, "no CL gauge discovered for pool"
  end

  test "not staked position returns zero claimable AERO" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_results(
      "0x#{word(GAUGE)}",
      "0x#{word(AERO)}",
      "0x#{uint_word(0)}"
    )

    result = service.reward_state(pool_address: POOL, account_address: ACCOUNT, token_id: 5016)

    assert_equal "not_staked", result.status
    assert_equal false, result.staked
    assert_equal BigDecimal("0"), result.claimable_aero
  end

  test "unsupported gauge API is handled safely" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_sequence(
      { result: "0x#{word(GAUGE)}" },
      { result: "0x#{word(AERO)}" },
      { error: { code: -32000, message: "execution reverted" } }
    )

    result = service.reward_state(pool_address: POOL, account_address: ACCOUNT, token_id: 5016)

    assert_equal "unavailable", result.status
    assert_match "stakedContains unsupported", result.warnings.first
  end

  test "missing voter config fails clearly" do
    error = assert_raises(AerodromeRewardsService::ConfigError) do
      AerodromeRewardsService.new(rpc_url: RPC_URL)
    end

    assert_match "AERODROME_VOTER_ADDRESS", error.message
  end

  private

  def stub_rpc_results(*results)
    stub_request(:post, RPC_URL).to_return(
      *results.map { |result| { status: 200, body: { jsonrpc: "2.0", id: 1, result: result }.to_json, headers: { "Content-Type" => "application/json" } } }
    )
  end

  def stub_rpc_sequence(*responses)
    stub_request(:post, RPC_URL).to_return(
      *responses.map { |payload| { status: 200, body: { jsonrpc: "2.0", id: 1 }.merge(payload).to_json, headers: { "Content-Type" => "application/json" } } }
    )
  end

  def word(address)
    address.downcase.delete_prefix("0x").rjust(64, "0")
  end

  def uint_word(value)
    Integer(value).to_s(16).rjust(64, "0")
  end
end
