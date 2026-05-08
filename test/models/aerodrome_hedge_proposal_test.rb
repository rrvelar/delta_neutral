require "test_helper"

class AerodromeHedgeProposalTest < ActiveSupport::TestCase
  test "defaults keep manual proposals non-executing" do
    proposal = AerodromeHedgeProposal.create!(
      position: positions(:eth_usdc),
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: "test",
      generated_at: Time.current
    )

    assert_equal "draft", proposal.status
    assert_equal false, proposal.execution_enabled
    assert_equal false, proposal.hyperliquid_called
  end

  test "execution flags cannot be enabled" do
    proposal = AerodromeHedgeProposal.new(
      position: positions(:eth_usdc),
      status: "draft",
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.25"),
      suggested_short_notional_usd: BigDecimal("2500"),
      lp_total_value_usd: BigDecimal("3000"),
      weth_price_usd: BigDecimal("2000"),
      source: "test",
      execution_enabled: true,
      hyperliquid_called: true,
      generated_at: Time.current
    )

    assert_not proposal.valid?
    assert_includes proposal.errors[:execution_enabled], "must remain false for manual proposals"
    assert_includes proposal.errors[:hyperliquid_called], "must remain false for manual proposals"
  end
end
