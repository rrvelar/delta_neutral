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
      "0x#{uint_word(77)}",
      "0x#{uint_word(12_500_000_000_000_000_000)}",
      "0x#{uint_word(18)}"
    )

    result = service.reward_state(pool_address: POOL, depositor_address: ACCOUNT, token_id: 5016)

    assert_equal "detected", result.status
    assert_equal GAUGE, result.gauge_address
    assert_equal ACCOUNT, result.depositor_address
    assert_equal ACCOUNT, result.account_address
    assert_equal true, result.staked
    assert_equal 77, result.reward_rate_raw
    assert_equal AERO, result.reward_token_address
    assert_equal 12_500_000_000_000_000_000, result.claimable_aero_raw
    assert_equal BigDecimal("12.5"), result.claimable_aero
    assert_nil result.claimable_aero_usd
    assert_empty result.blockers
  end

  test "zero gauge is handled without crashing" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER)
    stub_rpc_results("0x#{word(AerodromeRewardsService::ZERO_ADDRESS)}")

    result = service.reward_state(pool_address: POOL, depositor_address: ACCOUNT, token_id: 5016)

    assert_equal "not_configured", result.status
    assert_nil result.gauge_address
    assert_equal ACCOUNT, result.depositor_address
    assert_includes result.warnings, "no CL gauge discovered for pool"
  end

  test "not staked position returns zero claimable AERO" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_results(
      "0x#{word(GAUGE)}",
      "0x#{word(AERO)}",
      "0x#{uint_word(0)}",
      encoded_uint_array([ 123, 456 ])
    )

    result = service.reward_state(pool_address: POOL, depositor_address: ACCOUNT, token_id: 5016)

    assert_equal "not_staked", result.status
    assert_equal false, result.staked
    assert_equal [ 123, 456 ], result.staked_token_ids
    assert_equal BigDecimal("0"), result.claimable_aero
    assert_includes result.warnings, "position NFT 5016 is not staked in discovered CL gauge for depositor #{ACCOUNT}"
  end

  test "stakedContains and earned are called with depositor address, not gauge address" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_results(
      "0x#{word(GAUGE)}",
      "0x#{word(AERO)}",
      "0x#{uint_word(1)}",
      "0x#{uint_word(77)}",
      "0x#{uint_word(12_500_000_000_000_000_000)}",
      "0x#{uint_word(18)}"
    )

    service.reward_state(pool_address: POOL, depositor_address: ACCOUNT, token_id: 5016)

    bodies = WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map(&:body)
    staked_call = bodies.find { |body| JSON.parse(body).dig("params", 0, "data").start_with?(AerodromeRewardsService::SELECTORS.fetch(:staked_contains)) }
    earned_call = bodies.find { |body| JSON.parse(body).dig("params", 0, "data").start_with?(AerodromeRewardsService::SELECTORS.fetch(:earned)) }
    assert_includes JSON.parse(staked_call).dig("params", 0, "data"), ACCOUNT.delete_prefix("0x").rjust(64, "0")
    assert_includes JSON.parse(earned_call).dig("params", 0, "data"), ACCOUNT.delete_prefix("0x").rjust(64, "0")
    refute_includes JSON.parse(staked_call).dig("params", 0, "data"), GAUGE.delete_prefix("0x").rjust(64, "0")
    refute_includes JSON.parse(earned_call).dig("params", 0, "data"), GAUGE.delete_prefix("0x").rjust(64, "0")
  end

  test "unsupported gauge API is handled safely" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_sequence(
      { result: "0x#{word(GAUGE)}" },
      { result: "0x#{word(AERO)}" },
      { error: { code: -32000, message: "execution reverted" } }
    )

    result = service.reward_state(pool_address: POOL, depositor_address: ACCOUNT, token_id: 5016)

    assert_equal "unavailable", result.status
    assert_match "stakedContains unsupported", result.warnings.first
  end

  test "discovers staking account from CLGauge Deposit event for token id" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    staker = "0x5555555555555555555555555555555555555555"
    stub_rpc_sequence(
      {
        result: [
          {
            "address" => GAUGE,
            "topics" => [
              AerodromeRewardsService::DEPOSIT_EVENT_TOPIC,
              "0x#{word(staker)}",
              "0x#{uint_word(5016)}"
            ],
            "data" => "0x#{uint_word(123)}"
          }
        ]
      }
    )

    assert_equal staker, service.deposited_account_for_token(GAUGE, 5016)
  end

  test "claimable fallback tries rewards mapping when earned fails" do
    service = AerodromeRewardsService.new(rpc_url: RPC_URL, voter_address: VOTER, aero_token_address: AERO)
    stub_rpc_sequence(
      { error: { code: -32000, message: "execution reverted: NA" } },
      { result: "0x#{uint_word(42)}" }
    )

    result = service.claimable_for_staked_token(gauge_address: GAUGE, token_id: 5016, account_address: ACCOUNT)

    assert_equal "CLGauge.rewards(uint256)", result.fetch(:method)
    assert_equal 42, result.fetch(:raw)
    assert_nil result.fetch(:error)
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

  def encoded_uint_array(values)
    "0x#{uint_word(32)}#{uint_word(values.length)}#{values.map { |value| uint_word(value) }.join}"
  end
end
