require "test_helper"

class WalletSyncJobTest < ActiveSupport::TestCase
  include ServiceStubs

  setup do
    ENV["UNISWAP_SUBGRAPH_URL"] ||= "https://api.thegraph.com/subgraphs/test"
    ENV["THEGRAPH_API_KEY"] ||= "test-key"
  end

  test "creates new positions from subgraph" do
    wallet = wallets(:one)

    stub_uniswap_positions(wallet.address, [
      {
        external_id: "99999",
        pool_address: "0xnewpool",
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: "2.0",
        asset1_amount: "4000.0"
      }
    ])

    assert_difference "Position.count", 1 do
      WalletSyncJob.perform_now(wallet.id)
    end

    new_pos = Position.find_by(external_id: "99999")
    assert_equal "WETH", new_pos.asset0
    assert_equal "USDC", new_pos.asset1
    assert new_pos.active?
  end

  test "marks missing positions as inactive" do
    wallet = wallets(:one)
    position = positions(:eth_usdc)
    assert position.active?

    stub_uniswap_positions(wallet.address, [])

    WalletSyncJob.perform_now(wallet.id)

    position.reload
    assert_not position.active?
  end

  test "Aerodrome read-only disabled leaves Aerodrome path inactive" do
    wallet = base_wallet
    stub_uniswap_positions(wallet.address, [])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "false",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, -> { raise "Aerodrome service should not be called" }) do
        assert_no_difference "Position.count" do
          WalletSyncJob.perform_now(wallet.id)
        end
      end
    end
  end

  test "Aerodrome read-only with token ids creates position from mocked service" do
    wallet = base_wallet
    aerodrome_dex = aerodrome_dex_record
    stub_uniswap_positions(wallet.address, [])
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(wallet), [ "5016" ])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, service) do
        assert_difference "Position.where(dex: aerodrome_dex).count", 1 do
          WalletSyncJob.perform_now(wallet.id)
        end
      end
    end

    service.verify
    position = wallet.positions.find_by!(dex: aerodrome_dex, external_id: "5016")
    assert_equal "WETH", position.asset0
    assert_equal "USDC", position.asset1
    assert_equal BigDecimal("0.5"), position.asset0_amount
    assert_equal BigDecimal("1200.0"), position.asset1_amount
    assert_equal BigDecimal("2000.0"), position.asset0_price_usd
    assert_equal BigDecimal("1.0"), position.asset1_price_usd
    assert_equal "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", position.pool_address
    assert position.active?
  end

  test "Aerodrome read-only with token ids updates existing position from mocked service" do
    wallet = base_wallet
    aerodrome_dex = aerodrome_dex_record
    position = wallet.positions.create!(
      user: wallet.user,
      dex: aerodrome_dex,
      external_id: "5016",
      asset0: "OLD",
      asset1: "OLD",
      asset0_amount: 0,
      asset1_amount: 0,
      asset0_price_usd: 1,
      asset1_price_usd: 1,
      pool_address: "0xold",
      active: false
    )
    stub_uniswap_positions(wallet.address, [])
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(wallet), [ "5016" ])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, service) do
        assert_no_difference "Position.count" do
          WalletSyncJob.perform_now(wallet.id)
        end
      end
    end

    service.verify
    position.reload
    assert_equal "WETH", position.asset0
    assert_equal "USDC", position.asset1
    assert_equal BigDecimal("0.5"), position.asset0_amount
    assert_equal BigDecimal("1200.0"), position.asset1_amount
    assert_equal BigDecimal("2000.0"), position.asset0_price_usd
    assert_equal BigDecimal("1.0"), position.asset1_price_usd
    assert position.active?
  end

  test "Aerodrome unsupported valuation leaves prices nil" do
    wallet = base_wallet
    aerodrome_dex = aerodrome_dex_record
    stub_uniswap_positions(wallet.address, [])
    service = Minitest::Mock.new
    service.expect(:fetch_position, unsupported_valuation_position_data(wallet), [ "5016" ])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, service) do
        WalletSyncJob.perform_now(wallet.id)
      end
    end

    service.verify
    position = wallet.positions.find_by!(dex: aerodrome_dex, external_id: "5016")
    assert_nil position.asset0_price_usd
    assert_nil position.asset1_price_usd
  end

  test "Aerodrome owner mismatch skips position" do
    wallet = base_wallet
    stub_uniswap_positions(wallet.address, [])
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(wallet).with(owner_address: "0x0000000000000000000000000000000000000001"), [ "5016" ])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, service) do
        assert_no_difference "Position.count" do
          WalletSyncJob.perform_now(wallet.id)
        end
      end
    end

    service.verify
  end

  test "Aerodrome non-Base wallet skips without service call" do
    wallet = wallets(:one)
    stub_uniswap_positions(wallet.address, [])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      AerodromeSlipstreamService.stub(:new, -> { raise "Aerodrome service should not be called" }) do
        assert_no_difference "Position.count" do
          WalletSyncJob.perform_now(wallet.id)
        end
      end
    end
  end

  test "Aerodrome missing config fails safely only when enabled" do
    wallet = base_wallet
    stub_uniswap_positions(wallet.address, [])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016",
      "BASE_RPC_URL" => nil,
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => nil,
      "AERODROME_SLIPSTREAM_FACTORY" => nil
    ) do
      assert_nothing_raised do
        WalletSyncJob.perform_now(wallet.id)
      end
    end
  end

  test "Aerodrome wallet sync does not call HyperliquidService" do
    wallet = base_wallet
    stub_uniswap_positions(wallet.address, [])
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(wallet), [ "5016" ])

    with_env(
      "AERODROME_READ_ONLY_ENABLED" => "true",
      "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016"
    ) do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, service) do
          assert_difference "Position.count", 1 do
            WalletSyncJob.perform_now(wallet.id)
          end
        end
      end
    end

    service.verify
  end

  private

  def base_wallet
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
  end

  def aerodrome_dex_record
    Dex.find_or_create_by!(name: "aerodrome_slipstream")
  end

  def aerodrome_position_data(wallet)
    AerodromeSlipstreamService::PositionData.new(
      token_id: "5016",
      owner_address: wallet.address,
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token0_address: "0x4200000000000000000000000000000000000006",
      token1_address: "0x0000000000000000000000000000000000000001",
      token0_decimals: 18,
      token1_decimals: 6,
      token0_symbol: "WETH",
      token1_symbol: "USDC",
      tick_spacing: 200,
      tick_lower: -201000,
      tick_upper: -197700,
      liquidity: 123,
      sqrt_price_x96: 456,
      current_tick: -198995,
      tokens_owed0_raw: 7,
      tokens_owed1_raw: 11,
      amount0_raw: 500_000_000_000_000_000,
      amount1_raw: 1_200_000_000,
      verification_status: AerodromeSlipstreamService::VERIFIED_AMOUNT_MATH_SOURCE,
      token0_price_usd: BigDecimal("2000.0"),
      token1_price_usd: BigDecimal("1.0"),
      total_value_usd: BigDecimal("2200.0"),
      valuation_status: "supported",
      valuation_source: AerodromeSlipstreamValuation::VALUATION_SOURCE,
      valuation_reason: nil
    )
  end

  def unsupported_valuation_position_data(wallet)
    aerodrome_position_data(wallet).with(
      token0_price_usd: nil,
      token1_price_usd: nil,
      total_value_usd: nil,
      valuation_status: "unsupported",
      valuation_source: nil,
      valuation_reason: "pool does not include configured USDC quote token"
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
