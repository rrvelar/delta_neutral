class MellowAutopilotPositionSync
  def initialize(position:, probe_factory: nil, resolver_factory: nil)
    @position = position
    @probe_factory = probe_factory || method(:default_probe)
    @resolver_factory = resolver_factory || method(:default_resolver)
  end

  def sync
    metadata = @position.mellow_metadata_hash
    report = @probe_factory.call(metadata).report
    report = report_from_resolver(report, metadata) unless report[:hedgeable]
    previous_token_id = metadata["strategy_token_id"].presence

    unless report[:hedgeable]
      metadata = metadata.merge(
        "hedge_ready" => false,
        "last_probe_confidence" => report[:exposure_confidence] || report.dig(:pro_rata_exposure, :exposure_confidence),
        "last_probe_at" => Time.current.iso8601,
        "last_probe_blockers" => report.fetch(:blockers, []),
        "current_share_token_total_amounts_attempts" => report.dig(:pro_rata_exposure, :current_share_token_total_amounts_attempts)
      )
      @position.update!(mellow_metadata: JSON.generate(metadata))
      return { status: "blocked", report: report, blockers: report.fetch(:blockers, []) }
    end

    exposure = report.fetch(:pro_rata_exposure)
    metadata = metadata.merge(metadata_from_report(report)).merge(
      "hedge_ready" => true,
      "last_probe_at" => Time.current.iso8601,
      "last_current_exposure_at" => Time.current.iso8601,
      "last_probe_blockers" => []
    )
    if previous_token_id.present? && previous_token_id != metadata["strategy_token_id"]
      metadata["observed_strategy_token_id_history"] = Array(metadata["observed_strategy_token_id_history"]) | [ previous_token_id ]
    end

    update_attrs = {
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal(exposure.fetch(:user_weth_exposure)),
      asset1_amount: exposure[:user_usdc_exposure].present? ? BigDecimal(exposure.fetch(:user_usdc_exposure)) : nil,
      asset0_price_usd: strategy_weth_price(report),
      asset1_price_usd: BigDecimal("1"),
      pool_address: exposure[:strategy_pool_address],
      mellow_metadata: JSON.generate(metadata)
    }
    if @position.entry_value_usd.nil? && exposure[:user_total_value_usd].present?
      update_attrs[:entry_value_usd] = BigDecimal(exposure.fetch(:user_total_value_usd))
    end

    @position.update!(update_attrs)

    { status: "synced", report: report, blockers: [] }
  end

  private

  def default_probe(metadata)
    AerodromeAutopilotTransactionProbe.new(
      tx_hash: metadata.fetch("tx_hash"),
      wallet_address: metadata.fetch("submitted_wallet"),
      network: "base"
    )
  end

  def default_resolver(report, metadata)
    exposure = report[:pro_rata_exposure] || {}
    MellowCurrentExposureResolver.new(
      position: @position,
      share_token: exposure[:share_token].presence || metadata["share_token"],
      submitted_wallet: report[:submitted_wallet].presence || metadata["submitted_wallet"],
      strategy_pool_address: exposure[:strategy_pool_address].presence || metadata["strategy_pool_address"],
      token0: exposure[:strategy_token0].presence || metadata["strategy_token0"],
      token1: exposure[:strategy_token1].presence || metadata["strategy_token1"]
    )
  end

  def report_from_resolver(report, metadata)
    resolver_result = @resolver_factory.call(report, metadata).resolve
    return report.merge(resolver_result: resolver_result) unless resolver_result[:status] == "ok"

    exposure = (report[:pro_rata_exposure] || {}).merge(
      share_token: resolver_result[:share_token],
      strategy_token_id: report.dig(:pro_rata_exposure, :strategy_token_id) || metadata["strategy_token_id"],
      stale_strategy_token_id: resolver_result[:stale_strategy_token_id],
      strategy_pool_address: resolver_result[:strategy_pool_address],
      strategy_token0: resolver_result[:strategy_token0],
      strategy_token1: resolver_result[:strategy_token1],
      strategy_total_weth: resolver_result[:strategy_total_weth],
      strategy_total_usdc: resolver_result[:strategy_total_usdc],
      strategy_total_value_usd: nil,
      user_share_balance: resolver_result[:user_share_balance],
      total_shares: resolver_result[:total_supply],
      share_fraction: resolver_result[:share_fraction],
      user_share_percent: resolver_result[:user_share_percent],
      user_weth_exposure: resolver_result[:user_weth_exposure],
      user_usdc_exposure: resolver_result[:user_usdc_exposure],
      user_total_value_usd: resolver_result[:user_total_value_usd],
      confidence: "current_share_token_resolver_high",
      exposure_confidence: "current_share_token_resolver_high",
      exposure_source: "current_share_token_resolver",
      successful_contract: resolver_result[:successful_contract],
      successful_method: resolver_result[:successful_method],
      current_share_token_total_amounts_attempts: resolver_result[:attempted_methods],
      resolver_diagnostics: resolver_result[:diagnostics]
    )
    report.merge(
      hedgeable: true,
      blockers: [],
      exposure_confidence: "current_share_token_resolver_high",
      pro_rata_exposure: exposure,
      user_weth_exposure: exposure[:user_weth_exposure],
      user_usdc_exposure: exposure[:user_usdc_exposure],
      strategy_total_weth: exposure[:strategy_total_weth],
      strategy_total_usdc: exposure[:strategy_total_usdc],
      resolver_result: resolver_result
    )
  end

  def metadata_from_report(report)
    exposure = report.fetch(:pro_rata_exposure)
    {
      "tx_hash" => report[:tx_hash],
      "submitted_wallet" => report[:submitted_wallet],
      "share_token" => exposure[:share_token],
      "strategy_token_id" => exposure[:strategy_token_id],
      "strategy_pool_address" => exposure[:strategy_pool_address],
      "user_share_balance" => exposure[:user_share_balance],
      "total_shares" => exposure[:total_shares],
      "share_fraction" => exposure[:share_fraction],
      "user_share_percent" => exposure[:user_share_percent],
      "strategy_token0" => report.dig(:strategy_nft_exposure, :token0_address) || exposure[:strategy_token0],
      "strategy_token1" => report.dig(:strategy_nft_exposure, :token1_address) || exposure[:strategy_token1],
      "strategy_total_weth" => exposure[:strategy_total_weth],
      "strategy_total_usdc" => exposure[:strategy_total_usdc],
      "user_weth_exposure" => exposure[:user_weth_exposure],
      "user_usdc_exposure" => exposure[:user_usdc_exposure],
      "user_total_value_usd" => exposure[:user_total_value_usd],
      "last_probe_confidence" => exposure[:exposure_confidence] || exposure[:confidence],
      "exposure_source" => exposure[:exposure_source],
      "stale_strategy_token_id" => exposure[:stale_strategy_token_id],
      "successful_contract" => exposure[:successful_contract],
      "successful_method" => exposure[:successful_method],
      "current_share_token_total_amounts_attempts" => exposure[:current_share_token_total_amounts_attempts],
      "resolver_diagnostics" => exposure[:resolver_diagnostics]
    }
  end

  def strategy_weth_price(report)
    exposure = report.fetch(:pro_rata_exposure)
    total_value = BigDecimal(exposure[:strategy_total_value_usd].presence || "0")
    total_weth = BigDecimal(exposure[:strategy_total_weth].presence || "0")
    total_usdc = BigDecimal(exposure[:strategy_total_usdc].presence || "0")
    return nil unless total_weth.positive? && total_value.positive?

    (total_value - total_usdc) / total_weth
  end
end
