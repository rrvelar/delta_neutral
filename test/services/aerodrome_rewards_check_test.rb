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

      assert_equal "WARN", report.fetch(:status)
      assert_equal "detected", report.fetch(:gauge_status)
      assert_equal position.wallet.address, report.fetch(:position_wallet_address)
      assert_equal position.wallet.address, report.fetch(:wallet_address)
      assert_equal position.wallet.address, report.fetch(:depositor_address)
      assert_equal "position_wallet", report.fetch(:depositor_source)
      refute_equal report.fetch(:gauge_address), report.fetch(:depositor_address)
      assert_equal true, report.fetch(:staked)
      assert_equal "12.5", report.fetch(:claimable_aero)
      assert_equal 12_500_000_000_000_000_000, report.fetch(:claimable_aero_raw)
      assert_equal "unavailable", report.fetch(:aero_usd_price_source)
      assert_nil report.fetch(:claimable_aero_usd)
    end
  end

  test "manual AERO USD price produces claimable AERO USD" do
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

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.75"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "0.75", report.fetch(:aero_usd_price)
      assert_equal "manual", report.fetch(:aero_usd_price_source)
      assert_equal "9.375", report.fetch(:claimable_aero_usd)
    end
  end

  test "Mellow rewards use observed strategy token and pro-rate by user share" do
    position = create_mellow_position(user_share_percent: "1.25")
    strategy_reward_data = AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: "0x1111111111111111111111111111111111111111",
      depositor_address: position.wallet.address,
      account_address: position.wallet.address,
      token_id: "71261528",
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: 77,
      reward_token_address: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      claimable_aero_raw: 100_000_000_000_000_000_000,
      claimable_aero: BigDecimal("100"),
      claimable_aero_usd: nil,
      warnings: [],
      blockers: []
    )
    service = reward_service_stub(position, strategy_reward_data, expected_token_id: "71261528")

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5"
    ) do
      report = AerodromeRewardsCheck.new(
        rewards_service: service,
        slipstream_service: owner_reader(nil),
        position: position
      ).report

      assert_equal "WARN", report.fetch(:status)
      assert_equal "mellow:71261528", report.fetch(:token_id)
      assert_equal "mellow_strategy_observed_token", report.fetch(:token_source)
      assert_equal true, report.fetch(:strategy_level_estimate)
      assert_equal "0.0125", report.fetch(:pro_rata_share)
      assert_equal "Mellow pro-rata AERO rewards estimate", report.fetch(:reward_label)
      assert_equal "1.25", report.fetch(:claimable_aero)
      assert_equal 1_250_000_000_000_000_000, report.fetch(:claimable_aero_raw)
      assert_equal "0.625", report.fetch(:claimable_aero_usd)
      assert_equal "estimated", report.fetch(:value_state)
      assert_includes report.fetch(:warnings), "Mellow rewards/fees are read-only pro-rata estimates from the observed strategy token; claiming/collecting is not implemented."
    end
  end

  test "Mellow strategy token not staked in direct gauge is unavailable instead of verified zero" do
    position = create_mellow_position(user_share_percent: "1.25")
    strategy_reward_data = AerodromeRewardsService::RewardData.new(
      status: "not_staked",
      pool_address: position.pool_address,
      gauge_address: "0x1111111111111111111111111111111111111111",
      depositor_address: position.wallet.address,
      account_address: position.wallet.address,
      token_id: "71261528",
      staked: false,
      staked_token_ids: [],
      reward_rate_raw: nil,
      reward_token_address: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      claimable_aero_raw: 0,
      claimable_aero: BigDecimal("0"),
      claimable_aero_usd: nil,
      warnings: [ "position NFT 71261528 is not staked in discovered CL gauge" ],
      blockers: []
    )
    service = reward_service_stub(position, strategy_reward_data, expected_token_id: "71261528")

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5"
    ) do
      report = AerodromeRewardsCheck.new(
        rewards_service: service,
        slipstream_service: owner_reader(nil),
        position: position
      ).report

      assert_equal "WARN", report.fetch(:status)
      assert_equal "unavailable", report.fetch(:value_state)
      assert_nil report.fetch(:claimable_aero)
      assert_nil report.fetch(:claimable_aero_usd)
      assert_match "No direct gauge stake detected", report.fetch(:stop_reason)
    end
  end

  test "Mellow ownerOf equal to gauge reads strategy rewards and pro-rates nonzero amount" do
    position = create_mellow_position(user_share_percent: "1.25")
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    rewards = gauge_owner_rewards_service(position: position, gauge: gauge, raw_earned: 100_000_000_000_000_000_000)
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |token_id| token_id == "71261528" ? gauge : raise("unexpected token") }

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: rewards, slipstream_service: slipstream, position: position).report

      assert_equal "unverified_mismatch", report.fetch(:value_state)
      assert_equal "1.25", report.fetch(:claimable_aero)
      assert_equal "0.625", report.fetch(:claimable_aero_usd)
      assert_match "Reward scope is unverified", report.fetch(:stop_reason)
      assert_no_match "No direct gauge stake detected", report.fetch(:warnings).join(" ")
    end
  end

  test "Mellow ownerOf equal to gauge reads verified zero rewards" do
    position = create_mellow_position(user_share_percent: "1.25")
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    rewards = gauge_owner_rewards_service(position: position, gauge: gauge, raw_earned: 0)
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| gauge }

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5", "AERODROME_REWARDS_ENABLED" => "true") do
      report = AerodromeRewardsCheck.new(rewards_service: rewards, slipstream_service: slipstream, position: position).report

      assert_equal "verified_zero", report.fetch(:value_state)
      assert_equal "0.0", report.fetch(:claimable_aero)
    end
  end

  test "Mellow ownerOf equal to gauge reports reward read failure precisely" do
    position = create_mellow_position(user_share_percent: "1.25")
    gauge = "0xf33a96b5932d9e9b9a0eda447abd8c9d48d2e0c8"
    rewards = gauge_owner_rewards_service(position: position, gauge: gauge, raw_earned: AerodromeRewardsService::RpcError.new("earned reverted"))
    slipstream = Object.new
    slipstream.define_singleton_method(:owner_of) { |_token_id| gauge }

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5", "AERODROME_REWARDS_ENABLED" => "true") do
      report = AerodromeRewardsCheck.new(rewards_service: rewards, slipstream_service: slipstream, position: position).report

      assert_equal "unavailable", report.fetch(:value_state)
      assert_match "Strategy token is staked in gauge, but no supported reward read method succeeded", report.fetch(:stop_reason)
      assert_nil report.fetch(:claimable_aero)
    end
  end

  test "Mellow UI parity rewards become high confidence estimate when expected value matches" do
    position = create_mellow_position(user_share_percent: "0.156")
    add_share_token(position)
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) { |_pool| "0x1111111111111111111111111111111111111111" }
    stub_request(:post, "https://base.example.com/rpc").to_return(
      status: 200,
      body: { jsonrpc: "2.0", id: 1, result: "0x000000000000000000000000000000000000000000000001618d43063904a59c" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_AERO_TOKEN_ADDRESS" => "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5",
      "BASE_RPC_URL" => "https://base.example.com/rpc",
      "EXPECTED_AERO" => "25.25"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service, slipstream_service: owner_reader(nil), position: position).report

      assert_equal "estimated", report.fetch(:value_state)
      assert_equal "mellow_ui_parity_eth_call", report.fetch(:reward_source)
      assert_equal "high", report.fetch(:source_confidence)
      assert_equal "direct_deposit", report.fetch(:reward_scope)
      assert_equal "25.476092361110234524", report.fetch(:claimable_aero)
      assert_equal "12.738046180555117262", report.fetch(:claimable_aero_usd)
    end
  end

  test "Mellow UI parity expected mismatch remains included unless strict" do
    position = create_mellow_position(user_share_percent: "0.156")
    add_share_token(position)
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) { |_pool| "0x1111111111111111111111111111111111111111" }
    stub_request(:post, "https://base.example.com/rpc").to_return(
      status: 200,
      body: { jsonrpc: "2.0", id: 1, result: "0x000000000000000000000000000000000000000000000001618d43063904a59c" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5",
      "BASE_RPC_URL" => "https://base.example.com/rpc",
      "EXPECTED_AERO" => "1"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service, slipstream_service: owner_reader(nil), position: position).report

      assert_equal "estimated", report.fetch(:value_state)
      assert_equal "mellow_ui_parity_eth_call", report.fetch(:reward_source)
      assert_nil report.fetch(:stop_reason)
      assert report.fetch(:expected_aero_delta_percent).to_d.abs > 5
    end
  end

  test "Mellow UI parity expected mismatch is excluded when strict" do
    position = create_mellow_position(user_share_percent: "0.156")
    add_share_token(position)
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) { |_pool| "0x1111111111111111111111111111111111111111" }
    stub_request(:post, "https://base.example.com/rpc").to_return(
      status: 200,
      body: { jsonrpc: "2.0", id: 1, result: "0x000000000000000000000000000000000000000000000001618d43063904a59c" }.to_json,
      headers: { "Content-Type" => "application/json" }
    )

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "AERODROME_AERO_USD_MANUAL_PRICE" => "0.5",
      "BASE_RPC_URL" => "https://base.example.com/rpc",
      "EXPECTED_AERO" => "1",
      "STRICT_EXPECTED_AERO" => "true"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service, slipstream_service: owner_reader(nil), position: position).report

      assert_equal "unverified_mismatch", report.fetch(:value_state)
      assert_equal "mellow_ui_parity_eth_call", report.fetch(:reward_source)
      assert_match "Unverified", report.fetch(:stop_reason)
    end
  end

  test "verified zero reward read is explicit" do
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
      reward_rate_raw: 0,
      reward_token_address: "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      claimable_aero_raw: 0,
      claimable_aero: BigDecimal("0"),
      claimable_aero_usd: nil,
      warnings: [],
      blockers: []
    )
    service = reward_service_stub(position, reward_data)

    with_env("AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5", "AERODROME_REWARDS_ENABLED" => "true") do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "verified_zero", report.fetch(:value_state)
      assert_equal "0.0", report.fetch(:claimable_aero)
    end
  end

  test "Mellow rewards missing strategy token are unavailable without exception" do
    position = create_mellow_position(strategy_token_id: nil)
    service = Object.new
    service.define_singleton_method(:gauge_for_pool) { |_pool_address| raise "gauge should not be read without token id" }

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service, position: position).report

      assert_equal "WARN", report.fetch(:status)
      assert_equal "unavailable", report.fetch(:gauge_status)
      assert_nil report.fetch(:claimable_aero)
      assert_includes report.fetch(:warnings), "Mellow observed strategy token id is unavailable."
    end
  end

  test "configured on-chain AERO USDC pool price produces claimable AERO USD" do
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
    stub_aero_price_rpc

    with_env(
      "AERODROME_VOTER_ADDRESS" => "0x16613524e02ad97edfeF371bc883f2f5d6c480a5",
      "AERODROME_REWARDS_ENABLED" => "true",
      "BASE_RPC_URL" => "https://base.example.com/rpc",
      "AERODROME_AERO_TOKEN_ADDRESS" => "0x940181a94a35a4569e4529a3cdfb74e38fd98631",
      "AERODROME_USDC_ADDRESS" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "AERODROME_AERO_USD_VALUATION_ENABLED" => "true",
      "AERODROME_AERO_USDC_POOL_ADDRESS" => "0xbe00ff35af70e8415d0eb605a286d8a45466a4c1"
    ) do
      report = AerodromeRewardsCheck.new(rewards_service: service).report

      assert_equal "PASS", report.fetch(:status)
      assert_equal "1.0", report.fetch(:aero_usd_price)
      assert_equal "aerodrome_pool", report.fetch(:aero_usd_price_source)
      assert_equal "12.5", report.fetch(:claimable_aero_usd)
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

      assert_equal "WARN", report.fetch(:status)
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

  def reward_service_stub(position, reward_data, expected_token_id: position.external_id)
    Object.new.tap do |object|
      object.define_singleton_method(:gauge_for_pool) do |pool_address|
        raise "unexpected pool" unless pool_address == position.pool_address

        reward_data.gauge_address || "0x1111111111111111111111111111111111111111"
      end
      object.define_singleton_method(:reward_state_with_gauge) do |pool_address:, gauge_address:, depositor_address:, token_id:|
        raise "unexpected pool" unless pool_address == position.pool_address
        raise "unexpected gauge" unless gauge_address == (reward_data.gauge_address || "0x1111111111111111111111111111111111111111")
        raise "unexpected depositor" unless depositor_address == position.wallet.address
        raise "unexpected token #{token_id.inspect}" unless token_id == expected_token_id

        reward_data
      end
    end
  end

  def gauge_owner_rewards_service(position:, gauge:, raw_earned:)
    Object.new.tap do |object|
      object.define_singleton_method(:gauge_for_pool) do |pool_address|
        raise "unexpected pool" unless pool_address == position.pool_address

        gauge
      end
      object.define_singleton_method(:reward_token) { |_gauge| "0x940181a94a35a4569e4529a3cdfb74e38fd98631" }
      object.define_singleton_method(:reward_decimals) { |_reward_token| 18 }
      object.define_singleton_method(:deposited_account_for_token) do |received_gauge, token_id|
        raise "unexpected gauge" unless received_gauge == gauge
        raise "unexpected token #{token_id.inspect}" unless token_id == "71261528"

        "0x5555555555555555555555555555555555555555"
      end
      object.define_singleton_method(:claimable_for_staked_token) do |gauge_address:, token_id:, account_address:|
        raise "unexpected gauge" unless gauge_address == gauge
        raise "unexpected account" unless account_address == "0x5555555555555555555555555555555555555555"
        raise "unexpected token #{token_id.inspect}" unless token_id == "71261528"
        raise raw_earned if raw_earned.is_a?(Exception)

        { method: "CLGauge.earned(address,uint256)", raw: raw_earned, error: nil, account_address: account_address }
      end
    end
  end

  def owner_reader(owner)
    Object.new.tap do |object|
      object.define_singleton_method(:owner_of) { |_token_id| owner }
    end
  end

  def add_share_token(position)
    metadata = position.mellow_metadata_hash.merge("share_token" => MellowUiParityRewards::CONTRACT_ADDRESS)
    position.update!(mellow_metadata: JSON.generate(metadata))
  end

  def stub_aero_price_rpc
    sqrt_price_x96 = AerodromeSlipstreamMath::Q96 * 1_000_000
    stub_request(:post, "https://base.example.com/rpc").to_return(
      { status: 200, body: rpc_result(word("0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")) },
      { status: 200, body: rpc_result(word("0x940181a94a35a4569e4529a3cdfb74e38fd98631")) },
      { status: 200, body: rpc_result(uint_word(6)) },
      { status: 200, body: rpc_result(uint_word(18)) },
      { status: 200, body: rpc_result("#{uint_word(sqrt_price_x96)}#{uint_word(0)}#{uint_word(0)}#{uint_word(100)}#{uint_word(100)}#{uint_word(1)}") }
    )
  end

  def rpc_result(data)
    { jsonrpc: "2.0", id: 1, result: "0x#{data}" }.to_json
  end

  def word(address)
    address.downcase.delete_prefix("0x").rjust(64, "0")
  end

  def uint_word(value)
    Integer(value).to_s(16).rjust(64, "0")
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

  def create_mellow_position(strategy_token_id: "71261528", user_share_percent: "1.25")
    metadata = {
      "submitted_wallet" => "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      "strategy_pool_address" => "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      "user_share_percent" => user_share_percent,
      "hedge_ready" => true,
      "last_probe_confidence" => "high"
    }
    metadata["strategy_token_id"] = strategy_token_id if strategy_token_id

    create_aerodrome_position.tap do |position|
      position.update!(
        source: Position::SOURCE_MELLOW_AUTOPILOT,
        external_id: strategy_token_id ? "mellow:#{strategy_token_id}" : "mellow:missing",
        mellow_metadata: JSON.generate(metadata)
      )
    end
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
