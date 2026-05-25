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
    context = apply_mellow_reward_diagnostics(context)
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
      pro_rata_share_raw: decimal_string(context[:pro_rata_share_raw]),
      pro_rata_share_interpretation: context[:pro_rata_share_interpretation],
      exposure_derived_share: decimal_string(context[:exposure_derived_share]),
      pro_rata_fraction_used: decimal_string(context[:pro_rata_fraction_used]),
      reward_scope: context[:reward_scope],
      reward_source: @mellow_reward_source,
      source_confidence: context[:source_confidence],
      raw_gauge_earned: @mellow_reward_diagnostics&.fetch(:raw_gauge_earned, nil),
      raw_aero_amount_before_pro_rata: decimal_string(@mellow_reward_diagnostics&.fetch(:raw_aero_amount_before_pro_rata, nil)),
      final_computed_user_aero_amount: decimal_string(reward_data&.claimable_aero),
      reward_read_method: @mellow_reward_diagnostics&.fetch(:reward_read_method, nil),
      reward_account_address: @mellow_reward_diagnostics&.fetch(:reward_account_address, nil),
      reward_token_decimals: @mellow_reward_diagnostics&.fetch(:reward_token_decimals, nil),
      reward_read_attempts: @mellow_reward_diagnostics&.fetch(:reward_read_attempts, nil),
      ui_parity_contract_address: @mellow_reward_diagnostics&.fetch(:ui_parity_contract_address, nil) || @mellow_ui_parity_result&.contract_address,
      ui_parity_contract_role: @mellow_reward_diagnostics&.fetch(:ui_parity_contract_role, nil) || @mellow_ui_parity_result&.contract_role,
      ui_parity_selector: @mellow_reward_diagnostics&.fetch(:ui_parity_selector, nil) || @mellow_ui_parity_result&.selector,
      ui_parity_selector_name: @mellow_reward_diagnostics&.fetch(:ui_parity_selector_name, nil) || @mellow_ui_parity_result&.selector_name,
      ui_parity_verified_selector: @mellow_reward_diagnostics&.fetch(:ui_parity_verified_selector, nil) || @mellow_ui_parity_result&.verified_selector,
      ui_parity_call_from: @mellow_ui_parity_result&.call_from,
      ui_parity_call_to: @mellow_ui_parity_result&.call_to,
      ui_parity_wallet_arg: @mellow_ui_parity_result&.wallet_arg,
      ui_parity_raw_result: @mellow_ui_parity_result&.raw_result,
      ui_parity_decoded_aero: decimal_string(@mellow_ui_parity_result&.amount),
      ui_parity_delta: decimal_string(@mellow_ui_parity_result&.expected_delta),
      ui_parity_delta_percent: decimal_string(@mellow_ui_parity_result&.expected_delta_percent),
      candidate_reward_sources: candidate_reward_sources,
      expected_aero: decimal_string(expected_aero),
      expected_aero_delta: decimal_string(expected_aero_delta(reward_data)),
      expected_aero_delta_percent: decimal_string(expected_aero_delta_percent(reward_data)),
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
      pro_rata_share_raw: token.pro_rata_share_raw,
      pro_rata_share_interpretation: token.pro_rata_share_interpretation,
      exposure_derived_share: token.exposure_derived_share,
      pro_rata_fraction_used: token.strategy_level ? token.pro_rata_share : BigDecimal("1"),
      reward_scope: token.strategy_level ? "strategy_level" : "direct_deposit",
      source_confidence: "high",
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
    ui_parity = token.strategy_level ? read_mellow_ui_parity_rewards(position) : nil
    if ui_parity && ui_parity.status.in?(%w[estimated verified_zero unverified_match unverified_mismatch])
      reward_data = mellow_ui_parity_reward_data(position: position, token: token, gauge_address: gauge_address, result: ui_parity)
      @checks << { name: "Mellow UI-parity reward read", status: reward_data.status, value: ui_parity.contract_address }
      return reward_data
    end

    if token.strategy_level && same_address?(owner_address, gauge_address)
      reward_data = mellow_gauge_owner_reward_data(
        position: position,
        gauge_address: gauge_address,
        account_address: owner_address,
        token: token
      )
      @mellow_reward_scope = "unknown"
      @mellow_source_confidence = "low"
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
    staking_account = rewards_service.deposited_account_for_token(gauge_address, token.token_id) || account_address
    reward_token = rewards_service.reward_token(gauge_address)
    reward_read = rewards_service.claimable_for_staked_token(
      gauge_address: gauge_address,
      token_id: token.token_id,
      account_address: staking_account
    )
    raise AerodromeRewardsService::RpcError, reward_read[:error] if reward_read[:error].present?

    raw = reward_read.fetch(:raw)
    decimals = rewards_service.reward_decimals(reward_token)
    amount = decimal_amount(raw, decimals)
    @mellow_reward_scope = "unknown"
    @mellow_source_confidence = "low"
    @mellow_pro_rata_fraction_used = token.pro_rata_share
    @mellow_reward_diagnostics = {
      raw_gauge_earned: raw,
      raw_aero_amount_before_pro_rata: amount,
      reward_read_method: reward_read.fetch(:method),
      reward_account_address: reward_read[:account_address] || staking_account,
      reward_token_decimals: decimals,
      reward_read_attempts: reward_read[:attempts]
    }
    pro_rated_amount = pro_rate_decimal(amount, @mellow_pro_rata_fraction_used)
    pro_rated_raw = pro_rate_integer(raw, @mellow_pro_rata_fraction_used)

    AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: staking_account,
      account_address: staking_account,
      token_id: token.display_token_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: reward_token,
      claimable_aero_raw: pro_rated_raw,
      claimable_aero: pro_rated_amount,
      claimable_aero_usd: nil,
      warnings: token.warnings + [ "Mellow strategy token ownerOf equals discovered gauge; reward scope is unverified until reconciled with Mellow UI." ],
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
      warnings: token.warnings + [ "Strategy token is staked in gauge, but no supported reward read method succeeded: #{e.message}" ],
      blockers: []
    )
  end

  def decimal_amount(raw, decimals)
    BigDecimal(raw.to_s) / (BigDecimal("10")**Integer(decimals))
  end

  def read_mellow_ui_parity_rewards(position)
    return nil if position.mellow_metadata_hash["share_token"].blank? && ENV["MELLOW_UI_PARITY_REWARDS_ENABLED"].to_s.downcase != "true"

    @mellow_ui_parity_result = MellowUiParityRewards.new(position: position).read
  rescue MellowUiParityRewards::Error => e
    @warnings << "Mellow UI-parity reward read unavailable: #{e.message}"
    nil
  end

  def mellow_ui_parity_reward_data(position:, token:, gauge_address:, result:)
    @mellow_reward_scope = "direct_deposit"
    @mellow_source_confidence = result.confidence
    @mellow_pro_rata_fraction_used = BigDecimal("1")
    @mellow_reward_source = result.source
    @mellow_reward_value_state_override = result.status if result.status.in?(%w[unverified_match unverified_mismatch])
    @mellow_reward_diagnostics = {
      raw_gauge_earned: result.raw_amount,
      raw_aero_amount_before_pro_rata: result.amount,
      reward_read_method: result.selector_name,
      reward_account_address: result.wallet_address,
      reward_token_decimals: result.decimals,
      reward_read_attempts: [ { method: result.selector_name, raw: result.raw_amount, error: result.stop_reason } ],
      ui_parity_contract_address: result.contract_address,
      ui_parity_contract_role: result.contract_role,
      ui_parity_selector: result.selector,
      ui_parity_selector_name: result.selector_name,
      ui_parity_verified_selector: result.verified_selector,
      ui_parity_call_from: result.call_from,
      ui_parity_call_to: result.call_to,
      ui_parity_wallet_arg: result.wallet_arg
    }

    AerodromeRewardsService::RewardData.new(
      status: "detected",
      pool_address: position.pool_address,
      gauge_address: gauge_address,
      depositor_address: result.wallet_address,
      account_address: result.wallet_address,
      token_id: token.display_token_id,
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: nil,
      reward_token_address: ENV["AERODROME_AERO_TOKEN_ADDRESS"].presence,
      claimable_aero_raw: result.raw_amount,
      claimable_aero: result.amount,
      claimable_aero_usd: nil,
      warnings: token.warnings + [ "Mellow UI-parity AERO rewards estimate from #{result.selector_name}; claiming is not implemented." ],
      blockers: []
    )
  end

  def candidate_reward_sources
    sources = []
    if @mellow_ui_parity_result
      sources << {
        source: @mellow_ui_parity_result.source,
        status: @mellow_ui_parity_result.status,
        confidence: @mellow_ui_parity_result.confidence,
        amount: decimal_string(@mellow_ui_parity_result.amount),
        stop_reason: @mellow_ui_parity_result.stop_reason
      }
    end
    if @mellow_reward_diagnostics
      sources << {
        source: "aerodrome_cl_gauge",
        method: @mellow_reward_diagnostics[:reward_read_method],
        amount: decimal_string(@mellow_reward_diagnostics[:raw_aero_amount_before_pro_rata])
      }
    end
    sources
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
    return @mellow_reward_value_state_override if @mellow_reward_value_state_override

    claimable = BigDecimal(reward_data.claimable_aero.to_s)
    return "verified_zero" if claimable.zero?
    return "unverified_mismatch" if context[:source_confidence] == "low"
    return "unverified_mismatch" if expected_aero_delta_percent(reward_data)&.abs&.> BigDecimal("5")
    return "unavailable" unless price_data.price

    context[:strategy_level_estimate] ? "estimated" : "detected"
  rescue KeyError
    "unavailable"
  rescue ArgumentError
    "unavailable"
  end

  def reward_stop_reason(reward_data, context, claimable_aero_usd)
    return context[:token_unavailable_reason] if context[:token_unavailable_reason].present?
    if reward_data&.claimable_aero && BigDecimal(reward_data.claimable_aero.to_s).positive? && claimable_aero_usd.nil?
      return "Missing AERO USD price; reward amount is available but USD estimate is unavailable."
    end
    if expected_aero_delta_percent(reward_data)&.abs&.> BigDecimal("5")
      return "Unverified — differs from Mellow UI reference by more than 5%."
    end
    if reward_data && reward_data.status != "detected"
      staked_mellow_reason = reward_data.warnings.find { |warning| warning.to_s.start_with?("Strategy token is staked in gauge") }
      return staked_mellow_reason if staked_mellow_reason

      direct_mellow_reason = reward_data.warnings.find { |warning| warning.to_s.start_with?("No direct gauge stake detected") }
      return direct_mellow_reason || reward_data.warnings.first
    end
    if context[:source_confidence] == "low"
      return "Reward scope is unverified for Mellow gauge-owned strategy token; value is shown for diagnostics but excluded from Total PnL."
    end

    nil
  rescue ArgumentError
    "Reward amount could not be parsed."
  end

  def expected_aero
    raw = ENV["EXPECTED_AERO"].presence
    raw ? BigDecimal(raw) : nil
  rescue ArgumentError
    nil
  end

  def expected_aero_delta(reward_data)
    return nil unless expected_aero && reward_data&.claimable_aero

    BigDecimal(reward_data.claimable_aero.to_s) - expected_aero
  end

  def expected_aero_delta_percent(reward_data)
    return nil unless expected_aero&.positive?
    delta = expected_aero_delta(reward_data)
    return nil unless delta

    (delta / expected_aero) * 100
  end

  def apply_mellow_reward_diagnostics(context)
    return context unless @mellow_reward_scope

    context.merge(
      reward_scope: @mellow_reward_scope,
      source_confidence: @mellow_source_confidence,
      pro_rata_fraction_used: @mellow_pro_rata_fraction_used
    )
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
