class PositionValuation
  Result = Data.define(
    :source,
    :current_value_usd,
    :entry_value_usd,
    :pool_delta_usd,
    :weth_exposure,
    :usdc_exposure,
    :current_value_label,
    :entry_value_label,
    :pool_delta_label,
    :hedge_target_label,
    :status,
    :warnings
  )

  def self.current(position)
    new(position).current
  end

  def initialize(position)
    @position = position
  end

  def current
    @position.mellow_autopilot? ? mellow_result : direct_result
  end

  private

  def direct_result
    current_value = @position.total_value_usd
    entry_value = @position.entry_value_usd
    Result.new(
      source: @position.position_source,
      current_value_usd: current_value,
      entry_value_usd: entry_value,
      pool_delta_usd: entry_value ? current_value - entry_value : nil,
      weth_exposure: weth_exposure,
      usdc_exposure: usdc_exposure,
      current_value_label: "Current pooled value",
      entry_value_label: "Entry value",
      pool_delta_label: "Pool delta from entry",
      hedge_target_label: "Target ETH short",
      status: "ok",
      warnings: []
    )
  end

  def mellow_result
    metadata = @position.mellow_metadata_hash
    current_value = @position.mellow_current_value_usd
    entry_value = @position.entry_value_usd
    warnings = []
    warnings << "Mellow pro-rata value is stale or unavailable." if current_value.nil? && !@position.current_share_token_resolver_ready?(metadata)

    Result.new(
      source: @position.position_source,
      current_value_usd: current_value,
      entry_value_usd: entry_value,
      pool_delta_usd: current_value && entry_value ? current_value - entry_value : nil,
      weth_exposure: @position.mellow_weth_exposure,
      usdc_exposure: @position.mellow_usdc_exposure,
      current_value_label: "Mellow pro-rata current value",
      entry_value_label: "Mellow entry value",
      pool_delta_label: "Mellow pro-rata delta from entry",
      hedge_target_label: "Mellow WETH pro-rata exposure",
      status: current_value ? "ok" : "stale_unavailable",
      warnings: warnings + metadata_warnings(metadata)
    )
  end

  def metadata_warnings(metadata)
    warnings = []
    warnings << "Mellow metadata is not hedge-ready." unless metadata["hedge_ready"] == true
    warnings << "Mellow probe confidence is not high." unless metadata["last_probe_confidence"].to_s.in?(%w[high current_share_token_resolver_high share_token_current_fallback])
    warnings
  end

  def weth_exposure
    if @position.asset0.to_s.upcase.in?(%w[ETH WETH])
      @position.asset0_amount
    elsif @position.asset1.to_s.upcase.in?(%w[ETH WETH])
      @position.asset1_amount
    end
  end

  def usdc_exposure
    if @position.asset0.to_s.upcase == "USDC"
      @position.asset0_amount
    elsif @position.asset1.to_s.upcase == "USDC"
      @position.asset1_amount
    end
  end
end
