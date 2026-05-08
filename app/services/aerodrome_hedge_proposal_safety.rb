# Local safety-limit evaluation for manual Aerodrome hedge proposals.
#
# This service only compares persisted proposal and position values against
# optional environment limits. It never calls Hyperliquid, never calls RPC, and
# never enables execution.
class AerodromeHedgeProposalSafety
  LIMITS = {
    max_short_eth: "AERODROME_MAX_SHORT_ETH",
    max_short_notional_usd: "AERODROME_MAX_SHORT_NOTIONAL_USD",
    max_lp_value_usd: "AERODROME_MAX_LP_VALUE_USD",
    max_proposal_stale_percent: "AERODROME_MAX_PROPOSAL_STALE_PERCENT"
  }.freeze

  Result = Data.define(:passed, :blocked, :warnings, :failures, :checked_limits, :execution_enabled, :hyperliquid_called) do
    def status
      return "BLOCKED" if blocked
      return "WARNINGS" if warnings.any?

      "PASSED"
    end
  end

  def initialize(env: ENV)
    @env = env
  end

  def evaluate(proposal, current_position: proposal.position)
    warnings = []
    failures = []
    checked_limits = {}

    check_limit(
      checked_limits: checked_limits,
      warnings: warnings,
      failures: failures,
      key: :max_short_eth,
      actual: proposal.suggested_short_amount,
      failure_message: "suggested short amount exceeds configured maximum"
    )
    check_limit(
      checked_limits: checked_limits,
      warnings: warnings,
      failures: failures,
      key: :max_short_notional_usd,
      actual: proposal.suggested_short_notional_usd,
      failure_message: "suggested short notional exceeds configured maximum"
    )
    check_limit(
      checked_limits: checked_limits,
      warnings: warnings,
      failures: failures,
      key: :max_lp_value_usd,
      actual: proposal.lp_total_value_usd,
      failure_message: "LP value exceeds configured maximum"
    )
    check_limit(
      checked_limits: checked_limits,
      warnings: warnings,
      failures: failures,
      key: :max_proposal_stale_percent,
      actual: stale_percent(proposal, current_position),
      failure_message: "proposal stale percent exceeds configured maximum"
    )

    Result.new(
      passed: failures.empty?,
      blocked: failures.any?,
      warnings: warnings,
      failures: failures,
      checked_limits: checked_limits,
      execution_enabled: false,
      hyperliquid_called: false
    )
  end

  private

  def check_limit(checked_limits:, warnings:, failures:, key:, actual:, failure_message:)
    env_key = LIMITS.fetch(key)
    configured_value = @env[env_key].presence
    limit = parse_decimal(configured_value)

    checked_limits[key] = {
      env_key: env_key,
      configured: configured_value.present?,
      limit: limit,
      actual: actual,
      status: "not configured"
    }

    if configured_value.blank?
      warnings << "#{env_key} is not configured"
      return
    end

    if limit.nil?
      checked_limits[key][:status] = "invalid"
      warnings << "#{env_key} is invalid"
      return
    end

    if actual.nil?
      checked_limits[key][:status] = "unavailable"
      failures << "#{failure_message}: current value is unavailable"
      return
    end

    if actual > limit
      checked_limits[key][:status] = "failed"
      failures << "#{failure_message}: #{actual.to_s("F")} > #{limit.to_s("F")}"
    else
      checked_limits[key][:status] = "passed"
    end
  end

  def parse_decimal(value)
    return nil if value.blank?

    decimal = BigDecimal(value.to_s)
    return nil if decimal.negative?

    decimal
  rescue ArgumentError
    nil
  end

  def stale_percent(proposal, current_position)
    [
      percent_difference(current_weth_amount(current_position), proposal.suggested_short_amount),
      percent_difference(current_short_notional(current_position), proposal.suggested_short_notional_usd)
    ].compact.max
  end

  def percent_difference(current_value, proposed_value)
    return nil if current_value.nil? || proposed_value.nil?
    return current_value.zero? ? BigDecimal("0") : BigDecimal("100") if proposed_value.zero?

    ((current_value - proposed_value).abs / proposed_value.abs) * 100
  end

  def current_weth_amount(current_position)
    if current_position.asset0.to_s.upcase == "WETH"
      current_position.asset0_amount
    elsif current_position.asset1.to_s.upcase == "WETH"
      current_position.asset1_amount
    end
  end

  def current_weth_price(current_position)
    if current_position.asset0.to_s.upcase == "WETH"
      current_position.asset0_price_usd
    elsif current_position.asset1.to_s.upcase == "WETH"
      current_position.asset1_price_usd
    end
  end

  def current_short_notional(current_position)
    amount = current_weth_amount(current_position)
    price = current_weth_price(current_position)
    return nil if amount.nil? || price.nil?

    amount * price
  end
end
