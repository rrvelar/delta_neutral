require "test_helper"

class AerodromeHedgeProposalBuilderTest < ActiveSupport::TestCase
  WETH = "0x4200000000000000000000000000000000000006"
  USDC = "0x0000000000000000000000000000000000000001"

  test "creates draft proposal for Aerodrome WETH USDC position from persisted values" do
    position = aerodrome_position

    with_env("AERODROME_WETH_ADDRESS" => WETH, "AERODROME_USDC_ADDRESS" => USDC) do
      assert_difference "AerodromeHedgeProposal.count", 1 do
        result = AerodromeHedgeProposalBuilder.new.call(position)
        assert result.created
      end
    end

    proposal = position.aerodrome_hedge_proposals.first
    assert_equal "draft", proposal.status
    assert_equal "ETH", proposal.hedge_asset
    assert_equal "short", proposal.hedge_side
    assert_equal BigDecimal("1.25"), proposal.suggested_short_amount
    assert_equal BigDecimal("2500"), proposal.suggested_short_notional_usd
    assert_equal BigDecimal("3000"), proposal.lp_total_value_usd
    assert_equal BigDecimal("2000"), proposal.weth_price_usd
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "updates existing draft proposal instead of creating executable hedge" do
    position = aerodrome_position

    with_env("AERODROME_WETH_ADDRESS" => WETH, "AERODROME_USDC_ADDRESS" => USDC) do
      AerodromeHedgeProposalBuilder.new.call(position)
      position.update!(asset0_amount: BigDecimal("1.5"))

      assert_no_difference "AerodromeHedgeProposal.count" do
        AerodromeHedgeProposalBuilder.new.call(position)
      end
    end

    assert_equal BigDecimal("1.5"), position.aerodrome_hedge_proposals.first.suggested_short_amount
    assert_equal 0, Hedge.where(position: position).count
  end

  test "unsupported non Aerodrome position does not create proposal" do
    with_env("AERODROME_WETH_ADDRESS" => WETH, "AERODROME_USDC_ADDRESS" => USDC) do
      assert_no_difference "AerodromeHedgeProposal.count" do
        result = AerodromeHedgeProposalBuilder.new.call(positions(:eth_usdc))
        assert_not result.created
        assert_match "not Aerodrome", result.reason
      end
    end
  end

  test "missing amount or price does not create proposal" do
    position = aerodrome_position(asset0_price_usd: nil)

    with_env("AERODROME_WETH_ADDRESS" => WETH, "AERODROME_USDC_ADDRESS" => USDC) do
      assert_no_difference "AerodromeHedgeProposal.count" do
        result = AerodromeHedgeProposalBuilder.new.call(position)
        assert_not result.created
        assert_match "missing", result.reason
      end
    end
  end

  test "does not call HyperliquidService or RPC services" do
    position = aerodrome_position

    with_env("AERODROME_WETH_ADDRESS" => WETH, "AERODROME_USDC_ADDRESS" => USDC) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        AerodromeSlipstreamService.stub(:new, ->(*) { raise "RPC service should not be called" }) do
          assert_difference "AerodromeHedgeProposal.count", 1 do
            AerodromeHedgeProposalBuilder.new.call(position)
          end
        end
      end
    end
  end

  private

  def aerodrome_position(asset0_price_usd: BigDecimal("2000"), asset1_price_usd: BigDecimal("1"))
    Position.create!(
      user: users(:one),
      wallet: base_wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: asset0_price_usd,
      asset1_price_usd: asset1_price_usd,
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
