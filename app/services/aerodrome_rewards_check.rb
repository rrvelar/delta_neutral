class AerodromeRewardsCheck
  BANNER = "AERODROME REWARDS CHECK — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"

  def initialize(rewards_service: nil)
    @rewards_service = rewards_service
    @blockers = []
    @warnings = []
    @checks = []
  end

  def report
    position = active_aerodrome_position
    context = position_context(position)
    reward_data = position ? read_rewards(position) : nil
    merge_reward_messages(reward_data)

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      transactions_enabled: false,
      claims_enabled: false,
      pool_address: context[:pool_address],
      token_id: context[:token_id],
      wallet_address: context[:wallet_address],
      depositor_address: context[:wallet_address],
      asset0: context[:asset0],
      asset1: context[:asset1],
      asset0_amount: decimal_string(context[:asset0_amount]),
      asset1_amount: decimal_string(context[:asset1_amount]),
      current_pooled_value_usd: decimal_string(context[:current_pooled_value_usd]),
      gauge_status: reward_data&.status || "unavailable",
      gauge_address: reward_data&.gauge_address,
      staked: reward_data&.staked,
      staked_token_ids: reward_data&.staked_token_ids,
      reward_rate_raw: reward_data&.reward_rate_raw,
      claimable_aero: decimal_string(reward_data&.claimable_aero),
      claimable_aero_raw: reward_data&.claimable_aero_raw,
      claimable_aero_usd: nil,
      checks: @checks,
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  private

  def active_aerodrome_position
    dex = Dex.find_by(name: DEX_NAME)
    unless dex
      @blockers << "Aerodrome Slipstream dex record is missing"
      return nil
    end

    position = Position.includes(:wallet).where(dex: dex, active: true).order(:id).first
    @blockers << "No active Aerodrome Slipstream position found" unless position
    position
  end

  def position_context(position)
    return {} unless position

    {
      pool_address: position.pool_address,
      token_id: position.external_id,
      wallet_address: position.wallet.address,
      asset0: position.asset0,
      asset1: position.asset1,
      asset0_amount: position.asset0_amount,
      asset1_amount: position.asset1_amount,
      current_pooled_value_usd: position.total_value_usd
    }
  end

  def read_rewards(position)
    unless rewards_enabled?
      @warnings << "AERODROME_REWARDS_ENABLED is not true; reward discovery is disabled by default"
      @checks << { name: "AERODROME_REWARDS_ENABLED", status: "warn", value: ENV["AERODROME_REWARDS_ENABLED"].inspect }
    end

    if ENV["AERODROME_VOTER_ADDRESS"].blank?
      @warnings << "AERODROME_VOTER_ADDRESS is not configured; CL gauge cannot be discovered"
      @checks << { name: "AERODROME_VOTER_ADDRESS configured", status: "warn" }
      return nil
    end

    if position.wallet.address.blank?
      @blockers << "Position #{position.id} wallet address is missing; refusing to query rewards with gauge or fallback address"
      return nil
    end

    reward_data = rewards_service.reward_state(
      pool_address: position.pool_address,
      depositor_address: position.wallet.address,
      token_id: position.external_id
    )
    @checks << { name: "CL gauge reward read", status: reward_data.status, value: reward_data.gauge_address }
    reward_data
  rescue AerodromeRewardsService::ConfigError, AerodromeRewardsService::DecodeError => e
    @blockers << e.message
    nil
  rescue AerodromeRewardsService::Error => e
    @warnings << e.message
    nil
  end

  def merge_reward_messages(reward_data)
    return unless reward_data

    @warnings.concat(reward_data.warnings)
    @blockers.concat(reward_data.blockers)
  end

  def rewards_service
    @rewards_service ||= AerodromeRewardsService.new(
      aero_token_address: ENV["AERODROME_AERO_TOKEN_ADDRESS"].presence
    )
  end

  def rewards_enabled?
    ENV["AERODROME_REWARDS_ENABLED"].to_s.downcase == "true"
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def decimal_string(value)
    return nil if value.nil?

    BigDecimal(value.to_s).to_s("F")
  end

  def next_steps
    return [ "Resolve blockers before using reward discovery output." ] if @blockers.any?
    return [ "Review warnings. Rewards are not included in Total PnL and claiming is not implemented." ] if @warnings.any?

    [ "Rewards are read-only discovery only. Do not treat this as claim or live-trading approval." ]
  end
end
