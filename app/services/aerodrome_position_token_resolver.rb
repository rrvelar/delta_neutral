class AerodromePositionTokenResolver
  Result = Data.define(
    :status,
    :token_id,
    :display_token_id,
    :source,
    :strategy_level,
    :pro_rata_share,
    :warnings,
    :unavailable_reason
  )

  def self.resolve(position)
    new(position).resolve
  end

  def initialize(position)
    @position = position
  end

  def resolve
    return direct_result unless @position.mellow_autopilot?

    mellow_result
  end

  private

  def direct_result
    token_id = numeric_token_id(@position.external_id)
    return unavailable("Direct Aerodrome position token id is not numeric.") unless token_id

    Result.new(
      status: "ok",
      token_id: token_id,
      display_token_id: @position.external_id.to_s,
      source: "direct_slipstream_nft",
      strategy_level: false,
      pro_rata_share: BigDecimal("1"),
      warnings: [],
      unavailable_reason: nil
    )
  end

  def mellow_result
    token_id = numeric_token_id(metadata_token_id) || numeric_token_id(synthetic_external_id_token)
    return unavailable("Mellow observed strategy token id is unavailable.") unless token_id

    share = user_share_fraction
    return unavailable("Mellow user_share_percent is unavailable.") unless share

    Result.new(
      status: "ok",
      token_id: token_id,
      display_token_id: "mellow:#{token_id}",
      source: "mellow_strategy_observed_token",
      strategy_level: true,
      pro_rata_share: share,
      warnings: [ "Mellow rewards/fees are read-only pro-rata estimates from the observed strategy token; claiming/collecting is not implemented." ],
      unavailable_reason: nil
    )
  end

  def unavailable(reason)
    Result.new(
      status: "unavailable",
      token_id: nil,
      display_token_id: @position.external_id.to_s,
      source: @position.mellow_autopilot? ? "mellow_strategy_observed_token" : "direct_slipstream_nft",
      strategy_level: @position.mellow_autopilot?,
      pro_rata_share: nil,
      warnings: [ reason ],
      unavailable_reason: reason
    )
  end

  def metadata_token_id
    metadata = @position.mellow_metadata_hash
    metadata["strategy_token_id"].presence || metadata["observed_strategy_token_id"].presence
  end

  def synthetic_external_id_token
    match = @position.external_id.to_s.match(/\Amellow:(\d+)\z/)
    match && match[1]
  end

  def numeric_token_id(value)
    raw = value.to_s.strip
    return nil unless raw.match?(/\A\d+\z/)

    raw
  end

  def user_share_fraction
    raw = @position.mellow_metadata_hash["user_share_percent"]
    return nil if raw.blank?

    value = BigDecimal(raw.to_s)
    value > 1 ? value / 100 : value
  rescue ArgumentError
    nil
  end
end
