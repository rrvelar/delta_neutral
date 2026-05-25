class AerodromeRewardsCheck
  BANNER = "AERODROME REWARDS CHECK — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"

  def initialize(rewards_service: nil, price_service: nil, position: nil, slipstream_service: nil)
    @rewards_service = rewards_service
    @price_service = price_service
    @position = position
    @slipstream_service = slipstream_service
    @blockers = []
    @warnings = []
    @checks = []
  end

  def report
    position = active_aerodrome_position
    context = position_context(position)
    reward_data = position ? read_rewards(position) : nil
    price_data = reward_data ? read_aero_usd_price : unavailable_price
    merge_reward_messages(reward_data)
    @warnings.concat(price_data.warnings)
    claimable_aero_usd = claimable_aero_usd(reward_data, price_data)
    value_state = reward_value_state(reward_data, price_data, context)
    stop_reason = reward_stop_reason(reward_data, context, claimable_aero_usd)

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      transactions_enabled: false,
      claims_enabled: false,
      pool_address: context[:pool_address],
      token_id: context[:token_id],
      token_source: context[:token_source],
      strategy_level_estimate: context[:strategy_level_estimate],
      pro_rata_share: decimal_string(context[:pro_rata_share]),
      reward_label: context[:reward_label],
      claimable_by_app: context[:claimable_by_app],
      position_wallet_address: context[:position_wallet_address],
      wallet_address: context[:position_wallet_address],
      depositor_address: selected_depositor_address(context),
      depositor_source: selected_depositor_source,
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
      aero_usd_price: decimal_string(price_data.price),
      aero_usd_price_source: price_data.source,
      claimable_aero_usd: decimal_string(claimable_aero_usd),
      value_state: value_state,
      stop_reason: stop_reason,
      checks: @checks,
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  private

  def active_aerodrome_position
    return @position if @position

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

    token = token_context(position)
    {
      pool_address: position.pool_address,
      token_id: token.display_token_id,
      resolved_token_id: token.token_id,
      token_source: token.source,
      strategy_level_estimate: token.strategy_level,
      pro_rata_share: token.pro_rata_share,
      token_unavailable_reason: token.unavailable_reason,
      reward_label: token.strategy_level ? "Mellow pro-rata AERO rewards estimate" : "Claimable AERO",
      claimable_by_app: false,
      position_wallet_address: position.wallet.address,
      asset0: position.asset0,
      asset1: position.asset1,
      asset0_amount: position.asset0_amount,
      asset1_amount: position.asset1_amount,
      current_pooled_value_usd: PositionValuation.current(position).current_value_usd
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

    token = token_context(position)
    if token.status != "ok"
      @checks << { name: "Aerodrome reward token id", status: "unavailable", value: token.display_token_id }
      return unavailable_reward_data(position, token)
    end

    depositor = depositor_address_for(position)
    if depositor.blank?
      @blockers << "Position #{position.id} has no rewards depositor address; set AERODROME_REWARDS_DEPOSITOR_ADDRESS or configure a wallet address"
      return nil
    end

    gauge_address = rewards_service.gauge_for_pool(position.pool_address)
    owner_address = token.strategy_level ? strategy_token_owner(token.token_id) : nil
    if token.strategy_level && same_address?(owner_address, gauge_address)
      reward_data = mellow_gauge_owner_reward_data(
        position: position,
        gauge_address: gauge_address,
        account_address: owner_address,
        token: token
      )
      @checks << { name: "CL gauge reward read", status: reward_data.status, value: reward_data.gauge_address }
      return reward_data
    end

    if same_address?(depositor, gauge_address)
      @warnings << "selected depositor is the gauge; set AERODROME_REWARDS_DEPOSITOR_ADDRESS to the staking wallet"
      return gauge_as_depositor_result(position, depositor, gauge_address)
    end

    reward_data = rewards_service.reward_state_with_gauge(
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: depositor,
      token_id: token.token_id
    )
    reward_data = pro_rate_mellow_rewards(reward_data, token) if token.strategy_level
    @checks << { name: "CL gauge reward read", status: reward_data.status, value: reward_data.gauge_address }
    reward_data
  rescue AerodromeRewardsService::ConfigError, AerodromeRewardsService::DecodeError => e
    @blockers << e.message
    nil
  rescue AerodromeRewardsService::Error => e
    @warnings << e.message
    nil
  end

  def token_context(position)
    @token_context ||= {}
    @token_context[position.id] ||= AerodromePositionTokenResolver.resolve(position)
  end

  def unavailable_reward_data(position, token)
    AerodromeRewardsService::RewardData.new(
      status: "unavailable",
      pool_address: position.pool_address,
      gauge_address: nil,
      depositor_address: depositor_address_for(position),
      account_address: depositor_address_for(position),
      token_id: token.display_token_id,
      staked: nil,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: token.warnings,
      blockers: []
    )
  end

  def pro_rate_mellow_rewards(reward_data, token)
    if reward_data.status == "not_staked"
      return AerodromeRewardsService::RewardData.new(
        status: "unavailable",
        pool_address: reward_data.pool_address,
        gauge_address: reward_data.gauge_address,
        depositor_address: reward_data.depositor_address,
        account_address: reward_data.account_address,
        token_id: token.display_token_id,
        staked: false,
        staked_token_ids: reward_data.staked_token_ids,
        reward_rate_raw: reward_data.reward_rate_raw,
        reward_token_address: reward_data.reward_token_address,
        claimable_aero_raw: nil,
        claimable_aero: nil,
        claimable_aero_usd: nil,
        warnings: reward_data.warnings + token.warnings + [ "No direct gauge stake detected for strategy token; rewards may be handled by Mellow strategy or unavailable to this app." ],
        blockers: reward_data.blockers
      )
    end

    AerodromeRewardsService::RewardData.new(
      status: reward_data.status,
      pool_address: reward_data.pool_address,
      gauge_address: reward_data.gauge_address,
      depositor_address: reward_data.depositor_address,
      account_address: reward_data.account_address,
      token_id: token.display_token_id,
      staked: reward_data.staked,
      staked_token_ids: reward_data.staked_token_ids,
      reward_rate_raw: reward_data.reward_rate_raw,
      reward_token_address: reward_data.reward_token_address,
      claimable_aero_raw: pro_rate_integer(reward_data.claimable_aero_raw, token.pro_rata_share),
      claimable_aero: pro_rate_decimal(reward_data.claimable_aero, token.pro_rata_share),
      claimable_aero_usd: pro_rate_decimal(reward_data.claimable_aero_usd, token.pro_rata_share),
      warnings: reward_data.warnings + token.warnings,
      blockers: reward_data.blockers
    )
  end

  def pro_rate_decimal(value, share)
    return nil if value.nil?

    BigDecimal(value.to_s) * share
  end

  def pro_rate_integer(value, share)
    return nil if value.nil?

    (BigDecimal(value.to_s) * share).to_i
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

  def slipstream_service
    @slipstream_service ||= AerodromeSlipstreamService.new
  end

  def strategy_token_owner(token_id)
    slipstream_service.owner_of(token_id)
  rescue AerodromeSlipstreamService::Error => e
    @warnings << "ownerOf read unavailable for Mellow strategy token: #{e.message}"
    nil
  end

  def mellow_gauge_owner_reward_data(position:, gauge_address:, account_address:, token:)
    reward_token = rewards_service.reward_token(gauge_address)
    raw = rewards_service.earned(gauge_address, account_address, token.token_id)
    decimals = rewards_service.reward_decimals(reward_token)
    amount = decimal_amount(raw, decimals)
    pro_rated_amount = pro_rate_decimal(amount, token.pro_rata_share)
    pro_rated_raw = pro_rate_integer(raw, token.pro_rata_share)

    AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: account_address,
      account_address: account_address,
      token_id: token.display_token_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: reward_token,
      claimable_aero_raw: pro_rated_raw,
      claimable_aero: pro_rated_amount,
      claimable_aero_usd: nil,
      warnings: token.warnings + [ "Mellow strategy token ownerOf equals discovered gauge; rewards are read as strategy-level gauge custody and pro-rated." ],
      blockers: []
    )
  rescue AerodromeRewardsService::Error => e
    AerodromeRewardsService::RewardData.new(
      status: "unavailable",
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: account_address,
      account_address: account_address,
      token_id: token.display_token_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: token.warnings + [ "Strategy token is staked in gauge, but reward read method is unavailable/failed: #{e.message}" ],
      blockers: []
    )
  end

  def decimal_amount(raw, decimals)
    BigDecimal(raw.to_s) / (BigDecimal("10")**Integer(decimals))
  end

  def price_service
    @price_service ||= AerodromeAeroUsdPrice.new
  end

  def read_aero_usd_price
    price_service.price
  rescue AerodromeAeroUsdPrice::Error => e
    AerodromeAeroUsdPrice::Result.new(price: nil, source: "unavailable", warnings: [ e.message ])
  end

  def unavailable_price
    AerodromeAeroUsdPrice::Result.new(price: nil, source: "unavailable", warnings: [])
  end

  def claimable_aero_usd(reward_data, price_data)
    return nil unless reward_data&.claimable_aero && price_data.price

    reward_data.claimable_aero * price_data.price
  end

  def reward_value_state(reward_data, price_data, context)
    return "unavailable" unless reward_data&.claimable_aero
    return "unavailable" if context[:strategy_level_estimate] && reward_data.status != "detected"

    claimable = BigDecimal(reward_data.claimable_aero.to_s)
    return "verified_zero" if claimable.zero?
    return "unavailable" unless price_data.price

    context[:strategy_level_estimate] ? "estimated" : "detected"
  rescue ArgumentError
    "unavailable"
  end

  def reward_stop_reason(reward_data, context, claimable_aero_usd)
    return context[:token_unavailable_reason] if context[:token_unavailable_reason].present?
    if reward_data&.claimable_aero && BigDecimal(reward_data.claimable_aero.to_s).positive? && claimable_aero_usd.nil?
      return "Missing AERO USD price; reward amount is available but USD estimate is unavailable."
    end
    if reward_data && reward_data.status != "detected"
      staked_mellow_reason = reward_data.warnings.find { |warning| warning.to_s.start_with?("Strategy token is staked in gauge") }
      return staked_mellow_reason if staked_mellow_reason

      direct_mellow_reason = reward_data.warnings.find { |warning| warning.to_s.start_with?("No direct gauge stake detected") }
      return direct_mellow_reason || reward_data.warnings.first
    end

    nil
  rescue ArgumentError
    "Reward amount could not be parsed."
  end

  def rewards_enabled?
    ENV["AERODROME_REWARDS_ENABLED"].to_s.downcase == "true"
  end

  def depositor_address_for(position)
    ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].presence || position.wallet.address
  end

  def selected_depositor_address(context)
    ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].presence || context[:position_wallet_address]
  end

  def selected_depositor_source
    ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].present? ? "env" : "position_wallet"
  end

  def same_address?(left, right)
    left.to_s.downcase == right.to_s.downcase
  end

  def gauge_as_depositor_result(position, depositor, gauge_address)
    token = token_context(position)
    AerodromeRewardsService::RewardData.new(
      status: "unavailable",
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: depositor,
      account_address: depositor,
      token_id: token.display_token_id,
      staked: nil,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: [],
      blockers: []
    )
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
