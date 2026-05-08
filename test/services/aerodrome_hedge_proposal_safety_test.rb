require "test_helper"

class AerodromeHedgeProposalSafetyTest < ActiveSupport::TestCase
  test "proposal under configured limits passes safety check" do
    result = safety(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ).evaluate(proposal)

    assert result.passed
    assert_not result.blocked
    assert_empty result.failures
    assert_empty result.warnings
    assert_equal "PASSED", result.status
    assert_equal false, result.execution_enabled
    assert_equal false, result.hyperliquid_called
  end

  test "proposal above max short ETH is blocked" do
    result = safety(
      "AERODROME_MAX_SHORT_ETH" => "1",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ).evaluate(proposal)

    assert_not result.passed
    assert result.blocked
    assert_equal "BLOCKED", result.status
    assert_includes result.failures.first, "suggested short amount exceeds configured maximum"
  end

  test "proposal above max notional is blocked" do
    result = safety(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "2000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ).evaluate(proposal)

    assert result.blocked
    assert_includes result.failures.first, "suggested short notional exceeds configured maximum"
  end

  test "proposal above max LP value is blocked" do
    result = safety(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "2500",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ).evaluate(proposal)

    assert result.blocked
    assert_includes result.failures.first, "LP value exceeds configured maximum"
  end

  test "missing limits produce warnings but not failures" do
    result = safety({}).evaluate(proposal)

    assert result.passed
    assert_not result.blocked
    assert_empty result.failures
    assert_equal 4, result.warnings.size
    assert_equal "WARNINGS", result.status
    assert_equal "not configured", result.checked_limits.fetch(:max_short_eth).fetch(:status)
  end

  test "proposal stale percent over configured limit is blocked" do
    current_position = proposal.position
    current_position.update!(asset0_amount: BigDecimal("1.30"))

    result = safety(
      "AERODROME_MAX_SHORT_ETH" => "2",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "5000",
      "AERODROME_MAX_LP_VALUE_USD" => "10000",
      "AERODROME_MAX_PROPOSAL_STALE_PERCENT" => "0.5"
    ).evaluate(proposal, current_position: current_position)

    assert result.blocked
    assert_includes result.failures.first, "proposal stale percent exceeds configured maximum"
  end

  test "does not call HyperliquidService or RPC services" do
    HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
      AerodromeSlipstreamService.stub(:new, ->(*) { raise "RPC service should not be called" }) do
        assert_nothing_raised do
          safety({}).evaluate(proposal)
        end
      end
    end
  end

  private

  def safety(env)
    AerodromeHedgeProposalSafety.new(env: env)
  end

  def proposal
    @proposal ||= positions(:eth_usdc).aerodrome_hedge_proposals.create!(
      hedge_asset: "ETH",
      hedge_side: "short",
      suggested_short_amount: BigDecimal("1.5"),
      suggested_short_notional_usd: BigDecimal("3000"),
      lp_total_value_usd: BigDecimal("6000"),
      weth_price_usd: BigDecimal("2000"),
      source: "test",
      generated_at: Time.current
    )
  end
end
