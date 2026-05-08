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

  test "current proposal is not stale when values match" do
    proposal = proposal_for(positions(:eth_usdc))

    assert_not proposal.stale?
    assert_equal "Current", proposal.freshness_label
    assert_empty proposal.stale_reasons
  end

  test "stale detection catches amount change" do
    position = positions(:eth_usdc)
    proposal = proposal_for(position)
    position.update!(asset0_amount: BigDecimal("1.508"))

    assert proposal.stale?
    assert_includes proposal.stale_reasons, "amount changed"
  end

  test "stale detection catches notional change" do
    position = positions(:eth_usdc)
    proposal = proposal_for(position)
    position.update!(asset0_price_usd: BigDecimal("2011"))

    assert proposal.stale?
    assert_includes proposal.stale_reasons, "notional changed"
  end

  test "stale detection catches inactive and rejected proposals" do
    position = positions(:eth_usdc)
    proposal = proposal_for(position, status: "rejected")
    position.update!(active: false)

    assert_equal "Stale", proposal.freshness_label
    assert_includes proposal.stale_reasons, "position inactive"
    assert_includes proposal.stale_reasons, "proposal rejected/expired"
  end

  private

  def proposal_for(position, status: "draft")
    position.aerodrome_hedge_proposals.create!(
      status: status,
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: position.asset0_amount,
      suggested_short_notional_usd: position.asset0_amount * position.asset0_price_usd,
      lp_total_value_usd: position.total_value_usd,
      weth_price_usd: position.asset0_price_usd,
      source: "test",
      generated_at: Time.current
    )
  end
end
