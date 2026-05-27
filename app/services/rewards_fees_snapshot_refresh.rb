require "timeout"

class RewardsFeesSnapshotRefresh
  DEFAULT_TIMEOUT_SECONDS = 8.0

  def initialize(position:, rewards_check: nil, fees_check: nil, timeout_seconds: nil)
    @position = position
    @rewards_check = rewards_check
    @fees_check = fees_check
    @timeout_seconds = timeout_seconds || ENV.fetch("DASHBOARD_SNAPSHOT_REWARDS_FEES_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS).to_f
  end

  def refresh
    previous = position.position_rewards_fees_snapshot
    rewards = read_section(:rewards) { rewards_check.report }
    fees = read_section(:fees) { fees_check.report }
    errors = {}
    errors[:rewards] = rewards[:error] if rewards[:error]
    errors[:fees] = fees[:error] if fees[:error]

    attrs = (previous ? preserved_attrs(previous) : {}).merge(
      refreshed_at: Time.current,
      refresh_status: refresh_status(rewards, fees),
      source_errors: JSON.generate(errors),
      warnings: JSON.generate(Array(rewards.dig(:data, :warnings)) + Array(fees.dig(:data, :warnings))),
      orders_submitted: 0,
      signatures_created: 0
    )
    attrs.merge!(reward_attrs(rewards[:data])) if rewards[:data]
    attrs.merge!(fee_attrs(fees[:data])) if fees[:data]

    position.create_position_rewards_fees_snapshot! unless previous
    position.position_rewards_fees_snapshot.update!(attrs)
    position.position_rewards_fees_snapshot.reload
  end

  private

  attr_reader :position, :timeout_seconds

  def rewards_check
    @rewards_check ||= AerodromeRewardsCheck.new(position: position)
  end

  def fees_check
    @fees_check ||= AerodromeFeesCheck.new(position: position)
  end

  def read_section(name)
    data = Timeout.timeout(timeout_seconds) { yield }
    { status: "ok", data: data.with_indifferent_access }
  rescue => e
    { status: "error", error: "#{e.class}: #{e.message}" }
  end

  def refresh_status(rewards, fees)
    return "ok" if rewards[:status] == "ok" && fees[:status] == "ok"
    return "error" if rewards[:status] == "error" && fees[:status] == "error"

    "partial"
  end

  def reward_attrs(report)
    state = reward_value_state(report)
    {
      aero_rewards_amount: decimal_or_nil(report[:claimable_aero]),
      aero_rewards_usd: decimal_or_nil(report[:claimable_aero_usd]),
      aero_usd_price: decimal_or_nil(report[:aero_usd_price]),
      aero_price_source: report[:aero_usd_price_source],
      rewards_source: report[:reward_source].presence || report[:token_source],
      rewards_value_state: state,
      rewards_confidence: report[:source_confidence].presence || report[:confidence],
      rewards_stop_reason: report[:stop_reason].presence || Array(report[:warnings]).first
    }
  end

  def fee_attrs(report)
    {
      lp_fee_weth_amount: decimal_or_nil(report[:fee0_amount]),
      lp_fee_weth_usd: decimal_or_nil(report[:fee0_usd]),
      lp_fee_usdc_amount: decimal_or_nil(report[:fee1_amount]),
      lp_fee_usdc_usd: decimal_or_nil(report[:fee1_usd]),
      lp_fee_total_usd: decimal_or_nil(report[:total_fees_usd]),
      fee_source: report[:fee_source],
      fee_value_state: fee_value_state(report),
      fee_stop_reason: report[:stop_reason].presence || Array(report[:warnings]).first
    }
  end

  def reward_value_state(report)
    report[:value_state].presence ||
      (report[:claimable_aero_usd].present? ? (report[:claimable_aero_usd].to_s == "0" ? "verified_zero" : "estimated") : "unavailable")
  end

  def fee_value_state(report)
    report[:value_state].presence ||
      (report[:total_fees_usd].present? ? (report[:total_fees_usd].to_s == "0" ? "verified_zero" : "estimated") : "unavailable")
  end

  def preserved_attrs(snapshot)
    {
      aero_rewards_amount: snapshot.aero_rewards_amount,
      aero_rewards_usd: snapshot.aero_rewards_usd,
      aero_usd_price: snapshot.aero_usd_price,
      aero_price_source: snapshot.aero_price_source,
      rewards_source: snapshot.rewards_source,
      rewards_value_state: snapshot.rewards_value_state,
      rewards_confidence: snapshot.rewards_confidence,
      rewards_stop_reason: snapshot.rewards_stop_reason,
      lp_fee_weth_amount: snapshot.lp_fee_weth_amount,
      lp_fee_weth_usd: snapshot.lp_fee_weth_usd,
      lp_fee_usdc_amount: snapshot.lp_fee_usdc_amount,
      lp_fee_usdc_usd: snapshot.lp_fee_usdc_usd,
      lp_fee_total_usd: snapshot.lp_fee_total_usd,
      fee_source: snapshot.fee_source,
      fee_value_state: snapshot.fee_value_state,
      fee_stop_reason: snapshot.fee_stop_reason
    }
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end
end
