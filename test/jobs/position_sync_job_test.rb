require "test_helper"

class PositionSyncJobTest < ActiveSupport::TestCase
  setup do
    ENV["UNISWAP_SUBGRAPH_URL"] ||= "https://api.thegraph.com/subgraphs/test"
    ENV["THEGRAPH_API_KEY"] ||= "test-key"
    ENV["HYPERLIQUID_PRIVATE_KEY"] ||= "0xtest"
    ENV["HYPERLIQUID_WALLET_ADDRESS"] ||= "0xwallet"
    ENV["HYPERLIQUID_TESTNET"] ||= "true"
    ENV["ETHEREUM_RPC_URL"] ||= "https://eth.example.com/rpc"
    ENV["ARBITRUM_RPC_URL"] ||= "https://arb.example.com/rpc"
    ENV["BASE_RPC_URL"] ||= "https://base.example.com/rpc"
  end

  test "creates pnl snapshot for position" do
    position = positions(:eth_usdc)
    position.hedge&.destroy

    pool_response = {
      data: {
        pool: {
          "id" => position.pool_address,
          "token0Price" => "1",
          "token1Price" => "2100",
          "liquidity" => "5000000",
          "token0" => { "id" => "0xweth", "symbol" => "WETH", "decimals" => "18", "derivedETH" => "1.0" },
          "token1" => { "id" => "0xusdc", "symbol" => "USDC", "decimals" => "6", "derivedETH" => "0.000476" }
        },
        bundle: { "ethPriceUSD" => "2100" }
      }
    }.to_json

    position_fees_response = {
      data: {
        position: {
          "id" => position.external_id,
          "collectedFeesToken0" => "0",
          "collectedFeesToken1" => "0"
        }
      }
    }.to_json

    stub_request(:post, ENV["UNISWAP_SUBGRAPH_URL"])
      .to_return(
        { status: 200, body: pool_response, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: position_fees_response, headers: { "Content-Type" => "application/json" } }
      )

    stub_request(:post, /api\.hyperliquid/)
      .to_return(status: 200, body: { "assetPositions" => [], "marginSummary" => { "accountValue" => "0" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    # Stub Ethereum RPC for uncollected fees (raw on-chain values)
    # amount0 = 500000000000000 (0.0005 WETH with 18 decimals)
    # amount1 = 50000000 (50.0 USDC with 6 decimals)
    amount0_hex = "0000000000000000000000000000000000000000000000000001c6bf52634000"
    amount1_hex = "0000000000000000000000000000000000000000000000000000000002faf080"
    rpc_result = "0x" + amount0_hex + amount1_hex
    stub_request(:post, ENV["ETHEREUM_RPC_URL"])
      .to_return(status: 200, body: { jsonrpc: "2.0", id: 1, result: rpc_result }.to_json,
                 headers: { "Content-Type" => "application/json" })

    assert_difference "PnlSnapshot.count", 1 do
      PositionSyncJob.perform_now(position.id)
    end

    snapshot = PnlSnapshot.last
    assert_equal BigDecimal("0"), snapshot.collected_fees0
    assert_equal BigDecimal("0"), snapshot.collected_fees1
    assert_in_delta 0.0005, snapshot.uncollected_fees0.to_f, 0.00001
    assert_in_delta 50.0, snapshot.uncollected_fees1.to_f, 0.01
  end

  test "collected fees accumulate when uncollected fees drop" do
    position = positions(:eth_usdc)
    position.hedge&.destroy
    position.pnl_snapshots.destroy_all

    # Create a previous snapshot with uncollected fees
    PnlSnapshot.create!(
      position: position,
      captured_at: 1.hour.ago,
      asset0_amount: position.asset0_amount,
      asset1_amount: position.asset1_amount,
      asset0_price_usd: position.asset0_price_usd,
      asset1_price_usd: position.asset1_price_usd,
      hedge_unrealized: 0,
      hedge_realized: 0,
      pool_unrealized: 0,
      collected_fees0: BigDecimal("0.01"),
      collected_fees1: BigDecimal("10"),
      uncollected_fees0: BigDecimal("0.0005"),
      uncollected_fees1: BigDecimal("50")
    )

    pool_response = {
      data: {
        pool: {
          "id" => position.pool_address,
          "token0Price" => "1",
          "token1Price" => "2100",
          "liquidity" => "5000000",
          "token0" => { "id" => "0xweth", "symbol" => "WETH", "decimals" => "18", "derivedETH" => "1.0" },
          "token1" => { "id" => "0xusdc", "symbol" => "USDC", "decimals" => "6", "derivedETH" => "0.000476" }
        },
        bundle: { "ethPriceUSD" => "2100" }
      }
    }.to_json

    # Subgraph reports collected fees (may lag, but eventually correct)
    position_fees_response = {
      data: {
        position: {
          "id" => position.external_id,
          "collectedFeesToken0" => "0.0105",
          "collectedFeesToken1" => "60.0"
        }
      }
    }.to_json

    stub_request(:post, ENV["UNISWAP_SUBGRAPH_URL"])
      .to_return(
        { status: 200, body: pool_response, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: position_fees_response, headers: { "Content-Type" => "application/json" } }
      )

    stub_request(:post, /api\.hyperliquid/)
      .to_return(status: 200, body: { "assetPositions" => [], "marginSummary" => { "accountValue" => "0" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    # After collection: uncollected drops to ~0
    zero_hex = "0".rjust(64, "0")
    rpc_result = "0x" + zero_hex + zero_hex
    stub_request(:post, ENV["ETHEREUM_RPC_URL"])
      .to_return(status: 200, body: { jsonrpc: "2.0", id: 1, result: rpc_result }.to_json,
                 headers: { "Content-Type" => "application/json" })

    PositionSyncJob.perform_now(position.id)

    snapshot = PnlSnapshot.order(captured_at: :desc).first
    # max(subgraph=0.0105, diff=0.01+0.0005=0.0105) — both sources agree
    assert_in_delta 0.0105, snapshot.collected_fees0.to_f, 0.00001
    # max(subgraph=60, diff=10+50=60)
    assert_in_delta 60.0, snapshot.collected_fees1.to_f, 0.01
    assert_equal BigDecimal("0"), snapshot.uncollected_fees0
    assert_equal BigDecimal("0"), snapshot.uncollected_fees1
  end

  test "subgraph collected fees fill state gaps from diff tracking" do
    position = positions(:eth_usdc)
    position.hedge&.destroy
    position.pnl_snapshots.destroy_all

    # Previous snapshot has no uncollected (gap — collection happened before diff tracking)
    PnlSnapshot.create!(
      position: position,
      captured_at: 1.hour.ago,
      asset0_amount: position.asset0_amount,
      asset1_amount: position.asset1_amount,
      asset0_price_usd: position.asset0_price_usd,
      asset1_price_usd: position.asset1_price_usd,
      hedge_unrealized: 0,
      hedge_realized: 0,
      pool_unrealized: 0,
      collected_fees0: BigDecimal("0"),
      collected_fees1: BigDecimal("0"),
      uncollected_fees0: BigDecimal("0"),
      uncollected_fees1: BigDecimal("0")
    )

    pool_response = {
      data: {
        pool: {
          "id" => position.pool_address,
          "token0Price" => "1",
          "token1Price" => "2100",
          "liquidity" => "5000000",
          "token0" => { "id" => "0xweth", "symbol" => "WETH", "decimals" => "18", "derivedETH" => "1.0" },
          "token1" => { "id" => "0xusdc", "symbol" => "USDC", "decimals" => "6", "derivedETH" => "0.000476" }
        },
        bundle: { "ethPriceUSD" => "2100" }
      }
    }.to_json

    # Subgraph has indexed the collection — reports correct cumulative fees
    position_fees_response = {
      data: {
        position: {
          "id" => position.external_id,
          "collectedFeesToken0" => "0.0005",
          "collectedFeesToken1" => "50.0"
        }
      }
    }.to_json

    stub_request(:post, ENV["UNISWAP_SUBGRAPH_URL"])
      .to_return(
        { status: 200, body: pool_response, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: position_fees_response, headers: { "Content-Type" => "application/json" } }
      )

    stub_request(:post, /api\.hyperliquid/)
      .to_return(status: 200, body: { "assetPositions" => [], "marginSummary" => { "accountValue" => "0" } }.to_json,
                 headers: { "Content-Type" => "application/json" })

    zero_hex = "0".rjust(64, "0")
    rpc_result = "0x" + zero_hex + zero_hex
    stub_request(:post, ENV["ETHEREUM_RPC_URL"])
      .to_return(status: 200, body: { jsonrpc: "2.0", id: 1, result: rpc_result }.to_json,
                 headers: { "Content-Type" => "application/json" })

    PositionSyncJob.perform_now(position.id)

    snapshot = PnlSnapshot.order(captured_at: :desc).first
    # Diff sees no drop (0→0), but subgraph fills the gap
    assert_in_delta 0.0005, snapshot.collected_fees0.to_f, 0.00001
    assert_in_delta 50.0, snapshot.collected_fees1.to_f, 0.01
  end

  test "Aerodrome position sync is skipped when read-only mode is disabled" do
    position = aerodrome_position

    with_env("AERODROME_READ_ONLY_ENABLED" => "false") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, -> { raise "Aerodrome service should not be called" }) do
          assert_no_difference "PnlSnapshot.count" do
            PositionSyncJob.perform_now(position.id)
          end
        end
      end
    end
  end

  test "Aerodrome read-only position sync creates pnl snapshot without Hyperliquid" do
    position = aerodrome_position
    position.update!(entry_value_usd: nil)
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(position.wallet), [ position.external_id ])

    with_env("AERODROME_READ_ONLY_ENABLED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, service) do
          assert_difference "PnlSnapshot.count", 1 do
            PositionSyncJob.perform_now(position.id)
          end
        end
      end
    end

    service.verify
    position.reload
    assert_equal "AERO", position.asset0
    assert_equal "WETH", position.asset1
    assert_equal BigDecimal("1.25"), position.asset0_amount
    assert_equal BigDecimal("0.5"), position.asset1_amount
    assert_equal BigDecimal("2000"), position.asset0_price_usd
    assert_equal BigDecimal("1"), position.asset1_price_usd
    assert_equal "0x90757bd1595ca6e6a011e900e7a22d1a991856a5", position.pool_address
    assert_equal BigDecimal("2500.5"), position.entry_value_usd

    snapshot = position.pnl_snapshots.order(captured_at: :desc).first
    assert_equal BigDecimal("1.25"), snapshot.asset0_amount
    assert_equal BigDecimal("0.5"), snapshot.asset1_amount
    assert_equal BigDecimal("2000"), snapshot.asset0_price_usd
    assert_equal BigDecimal("1"), snapshot.asset1_price_usd
    assert_equal BigDecimal("0"), snapshot.pool_unrealized
    assert_equal BigDecimal("0"), snapshot.hedge_unrealized
    assert_equal BigDecimal("0"), snapshot.hedge_realized
    assert_equal BigDecimal("0"), snapshot.collected_fees0
    assert_equal BigDecimal("0"), snapshot.collected_fees1
    assert_equal BigDecimal("0"), snapshot.uncollected_fees0
    assert_equal BigDecimal("0"), snapshot.uncollected_fees1
  end

  test "Aerodrome pnl snapshot uses existing entry value for pool unrealized pnl" do
    position = aerodrome_position
    position.update!(entry_value_usd: BigDecimal("2000"))
    service = Minitest::Mock.new
    service.expect(:fetch_position, aerodrome_position_data(position.wallet), [ position.external_id ])

    with_env("AERODROME_READ_ONLY_ENABLED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, service) do
          assert_difference "PnlSnapshot.count", 1 do
            PositionSyncJob.perform_now(position.id)
          end
        end
      end
    end

    service.verify
    position.reload
    snapshot = position.pnl_snapshots.order(captured_at: :desc).first
    assert_equal BigDecimal("2000"), position.entry_value_usd
    assert_equal BigDecimal("500.5"), snapshot.pool_unrealized
    assert_equal BigDecimal("0"), snapshot.total_fees_usd
  end

  test "Aerodrome read-only position sync leaves amounts nil when amount math is partial" do
    position = aerodrome_position
    service = Minitest::Mock.new
    service.expect(:fetch_position, partial_aerodrome_position_data(position.wallet), [ position.external_id ])

    with_env("AERODROME_READ_ONLY_ENABLED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, service) do
          assert_no_difference "PnlSnapshot.count" do
            PositionSyncJob.perform_now(position.id)
          end
        end
      end
    end

    service.verify
    position.reload
    assert_nil position.asset0_amount
    assert_nil position.asset1_amount
    assert_nil position.asset0_price_usd
    assert_nil position.asset1_price_usd
  end

  test "Aerodrome read-only position sync leaves prices nil when valuation is unsupported" do
    position = aerodrome_position
    service = Minitest::Mock.new
    service.expect(:fetch_position, unsupported_valuation_position_data(position.wallet), [ position.external_id ])

    with_env("AERODROME_READ_ONLY_ENABLED" => "true") do
      HyperliquidService.stub(:new, -> { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, service) do
          assert_no_difference "PnlSnapshot.count" do
            PositionSyncJob.perform_now(position.id)
          end
        end
      end
    end

    service.verify
    position.reload
    assert_equal BigDecimal("1.25"), position.asset0_amount
    assert_equal BigDecimal("0.5"), position.asset1_amount
    assert_nil position.asset0_price_usd
    assert_nil position.asset1_price_usd
  end

  private

  def aerodrome_position
    Position.find_or_create_by!(
      user: users(:one),
      wallet: base_wallet,
      dex: aerodrome_dex,
      external_id: "5016"
    ) do |position|
      position.asset0 = "OLD0"
      position.asset1 = "OLD1"
      position.pool_address = "0xoldpool"
      position.active = true
    end
  end

  def base_wallet
    Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701")
  end

  def aerodrome_dex
    Dex.find_or_create_by!(name: "aerodrome_slipstream")
  end

  def aerodrome_position_data(wallet)
    AerodromeSlipstreamService::PositionData.new(
      token_id: "5016",
      owner_address: wallet.address,
      position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token0_address: "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b",
      token1_address: "0x4200000000000000000000000000000000000006",
      token0_decimals: 18,
      token1_decimals: 18,
      token0_symbol: "AERO",
      token1_symbol: "WETH",
      tick_spacing: 200,
      tick_lower: -151400,
      tick_upper: -147400,
      liquidity: 123,
      sqrt_price_x96: 456,
      current_tick: -155876,
      tokens_owed0_raw: 7,
      tokens_owed1_raw: 11,
      amount0_raw: 1_250_000_000_000_000_000,
      amount1_raw: 500_000_000_000_000_000,
      partial_data_reason: nil,
      verification_status: "verified_math",
      token0_price_usd: BigDecimal("2000"),
      token1_price_usd: BigDecimal("1"),
      total_value_usd: BigDecimal("2500"),
      valuation_status: "supported",
      valuation_source: AerodromeSlipstreamValuation::VALUATION_SOURCE,
      valuation_reason: nil
    )
  end

  def partial_aerodrome_position_data(wallet)
    aerodrome_position_data(wallet).with(
      amount0_raw: nil,
      amount1_raw: nil,
      partial_data_reason: AerodromeSlipstreamService::PARTIAL_AMOUNT_MATH_DEFERRED,
      verification_status: "partial",
      token0_price_usd: nil,
      token1_price_usd: nil,
      total_value_usd: nil,
      valuation_status: "unsupported",
      valuation_source: nil,
      valuation_reason: "amount math unavailable"
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
