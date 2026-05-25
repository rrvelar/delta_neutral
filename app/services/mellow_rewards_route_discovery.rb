class MellowRewardsRouteDiscovery
  Result = Data.define(
    :position_id,
    :source,
    :synthetic_external_id,
    :resolved_strategy_token_id,
    :owner_address,
    :gauge_address,
    :gauge_staked,
    :strategy_token_staked_in_gauge,
    :direct_depositor_staked,
    :reward_read_method,
    :reward_route_status,
    :fee_route_status,
    :pro_rata_share,
    :stop_reason,
    :warnings
  )

  def initialize(position:, token_resolver: AerodromePositionTokenResolver, slipstream_service: nil, rewards_service: nil)
    @position = position
    @token_resolver = token_resolver
    @slipstream_service = slipstream_service
    @rewards_service = rewards_service
    @warnings = []
  end

  def report
    token = @token_resolver.resolve(@position)
    return unavailable_result(token: token, reason: token.unavailable_reason || "Mellow strategy token id is unavailable.") unless token.status == "ok"

    owner = read_owner(token.token_id)
    gauge = read_gauge
    owner_is_gauge = same_address?(owner, gauge)
    direct_depositor_staked = read_staked(gauge, token.token_id)
    strategy_token_staked = owner_is_gauge || direct_depositor_staked
    reward_read = if strategy_token_staked
      read_gauge_rewards(gauge: gauge, token_id: token.token_id, account: owner_is_gauge ? gauge : depositor_address)
    else
      { method: "CLGauge.earned(address,uint256)", raw: nil, error: nil }
    end
    route_status, stop_reason = reward_route_status(
      gauge: gauge,
      strategy_token_staked: strategy_token_staked,
      reward_read: reward_read
    )

    Result.new(
      position_id: @position.id,
      source: @position.source,
      synthetic_external_id: @position.external_id,
      resolved_strategy_token_id: token.token_id,
      owner_address: owner,
      gauge_address: gauge,
      gauge_staked: strategy_token_staked,
      strategy_token_staked_in_gauge: strategy_token_staked,
      direct_depositor_staked: direct_depositor_staked,
      reward_read_method: reward_read[:method],
      reward_route_status: route_status,
      fee_route_status: token.strategy_level ? "verified_zero" : "unavailable",
      pro_rata_share: token.pro_rata_share,
      stop_reason: stop_reason,
      warnings: @warnings
    )
  end

  private

  def unavailable_result(token:, reason:)
    Result.new(
      position_id: @position.id,
      source: @position.source,
      synthetic_external_id: @position.external_id,
      resolved_strategy_token_id: token.token_id,
      owner_address: nil,
      gauge_address: nil,
      gauge_staked: nil,
      strategy_token_staked_in_gauge: nil,
      direct_depositor_staked: nil,
      reward_read_method: nil,
      reward_route_status: "unavailable",
      fee_route_status: "unavailable",
      pro_rata_share: token.pro_rata_share,
      stop_reason: reason,
      warnings: token.warnings
    )
  end

  def read_owner(token_id)
    return nil unless slipstream_service

    slipstream_service.owner_of(token_id)
  rescue AerodromeSlipstreamService::Error => e
    @warnings << "ownerOf read unavailable: #{e.message}"
    nil
  end

  def read_gauge
    return nil unless rewards_service
    return nil if @position.pool_address.blank?

    gauge = rewards_service.gauge_for_pool(@position.pool_address)
    gauge == AerodromeRewardsService::ZERO_ADDRESS ? nil : gauge
  rescue AerodromeRewardsService::Error => e
    @warnings << "gauge discovery unavailable: #{e.message}"
    nil
  end

  def read_staked(gauge, token_id)
    return nil if gauge.blank? || rewards_service.nil?

    rewards_service.staked_contains(gauge, depositor_address, token_id)
  rescue AerodromeRewardsService::Error => e
    @warnings << "direct depositor gauge stake status unavailable: #{e.message}"
    nil
  end

  def read_gauge_rewards(gauge:, token_id:, account:)
    method = "CLGauge.earned(address,uint256)"
    return { method: method, raw: nil, error: "gauge unavailable" } if gauge.blank?
    return { method: method, raw: nil, error: "reward account unavailable" } if account.blank?
    return { method: method, raw: nil, error: "rewards service unavailable" } if rewards_service.nil?

    { method: method, raw: rewards_service.earned(gauge, account, token_id), error: nil }
  rescue AerodromeRewardsService::Error => e
    { method: method, raw: nil, error: e.message }
  end

  def reward_route_status(gauge:, strategy_token_staked:, reward_read:)
    return [ "unavailable", "No direct CL gauge discovered for strategy pool; Mellow strategy reward route is unavailable to this app." ] if gauge.blank?
    unless strategy_token_staked
      return [ "unavailable", "No direct gauge stake detected for strategy token; rewards may be handled by Mellow strategy or unavailable to this app." ]
    end
    if reward_read[:error].present?
      return [ "unavailable", "Strategy token is staked in gauge, but reward read method is unavailable/failed: #{reward_read[:error]}" ]
    end
    return [ "verified_zero", nil ] if BigDecimal(reward_read[:raw].to_s).zero?

    [ "estimated", nil ]
  rescue ArgumentError
    [ "unavailable", "Strategy token is staked in gauge, but reward read method returned an unparseable value." ]
  end

  def same_address?(left, right)
    left.present? && right.present? && left.to_s.downcase == right.to_s.downcase
  end

  def depositor_address
    ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].presence || @position.wallet.address
  end

  def slipstream_service
    @slipstream_service ||= begin
      AerodromeSlipstreamService.new
    rescue AerodromeSlipstreamService::ConfigError => e
      @warnings << "Slipstream service unavailable: #{e.message}"
      nil
    end
  end

  def rewards_service
    @rewards_service ||= begin
      AerodromeRewardsService.new(aero_token_address: ENV["AERODROME_AERO_TOKEN_ADDRESS"].presence)
    rescue AerodromeRewardsService::ConfigError => e
      @warnings << "Rewards service unavailable: #{e.message}"
      nil
    end
  end
end
