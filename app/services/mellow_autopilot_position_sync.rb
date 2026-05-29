class MellowAutopilotPositionSync
  def initialize(position:, probe_factory: nil)
    @position = position
    @probe_factory = probe_factory || method(:default_probe)
  end

  def sync
    metadata = @position.mellow_metadata_hash
    report = @probe_factory.call(metadata).report
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
      "current_share_token_total_amounts_attempts" => exposure[:current_share_token_total_amounts_attempts]
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
