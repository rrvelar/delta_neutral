class MellowRewardsRouteDiscovery
  Result = Data.define(
    :position_id,
    :source,
    :synthetic_external_id,
    :resolved_strategy_token_id,
    :owner_address,
    :gauge_address,
    :gauge_staked,
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
    staked = read_staked(gauge, token.token_id)
    stop_reason = stop_reason_for(gauge: gauge, staked: staked)

    Result.new(
      position_id: @position.id,
      source: @position.source,
      synthetic_external_id: @position.external_id,
      resolved_strategy_token_id: token.token_id,
      owner_address: owner,
      gauge_address: gauge,
      gauge_staked: staked,
      reward_route_status: stop_reason ? "unavailable" : "estimated",
      fee_route_status: token.strategy_level ? "estimated" : "unavailable",
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

    depositor = ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].presence || @position.wallet.address
    rewards_service.staked_contains(gauge, depositor, token_id)
  rescue AerodromeRewardsService::Error => e
    @warnings << "gauge stake status unavailable: #{e.message}"
    nil
  end

  def stop_reason_for(gauge:, staked:)
    return "No direct CL gauge discovered for strategy pool; Mellow strategy reward route is unavailable to this app." if gauge.blank?
    return nil if staked
    return "No direct gauge stake detected for strategy token; rewards may be handled by Mellow strategy or unavailable to this app." if staked == false

    "Gauge stake status could not be verified for strategy token; reward route is unavailable."
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
