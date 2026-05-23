# Builds local, manual-only hedge proposal records for Aerodrome monitor-only positions.
#
# This service only reads persisted Position fields and writes
# AerodromeHedgeProposal rows. It never calls RPC, never calls Hyperliquid, and
# never creates executable Hedge records.
class AerodromeHedgeProposalBuilder
  Result = Data.define(:created, :proposal, :reason)

  def initialize(
    preview: nil,
    weth_address: ENV["AERODROME_WETH_ADDRESS"].presence,
    usdc_address: ENV["AERODROME_USDC_ADDRESS"].presence
  )
    @weth_address = weth_address
    @usdc_address = usdc_address
    @preview = preview || AerodromeHedgePreview.new(weth_address: @weth_address)
  end

  def call(position)
    return unsupported("position is not Aerodrome Slipstream") unless aerodrome_position?(position)
    return unsupported("AERODROME_WETH_ADDRESS is not configured") if @weth_address.blank?
    return unsupported("AERODROME_USDC_ADDRESS is not configured") if @usdc_address.blank?

    token_addresses = configured_token_addresses_for(position)
    return unsupported("position token identity is not a configured WETH/USDC pair") if token_addresses.nil?
    return unsupported("amount or USD price is missing") if missing_amount_or_price?(position)

    preview = @preview.preview_fields(
      token0_address: token_addresses.fetch(:token0_address),
      token1_address: token_addresses.fetch(:token1_address),
      amount0_decimal: position.asset0_amount,
      amount1_decimal: position.asset1_amount,
      token0_price_usd: position.asset0_price_usd,
      token1_price_usd: position.asset1_price_usd,
      total_value_usd: PositionValuation.current(position).current_value_usd,
      amount_verified: true,
      valuation_supported: true
    )
    return unsupported(preview.reason || "preview is unsupported") unless preview.supported

    proposal = position.aerodrome_hedge_proposals.draft.latest_first.first_or_initialize
    proposal.assign_attributes(
      hedge_asset: preview.hedge_asset,
      hedge_side: preview.hedge_side,
      suggested_short_amount: preview.suggested_short_amount,
      suggested_short_notional_usd: preview.suggested_short_notional_usd,
      lp_total_value_usd: preview.lp_total_value_usd,
      weth_price_usd: preview.weth_price_usd,
      source: preview.source,
      execution_enabled: false,
      hyperliquid_called: false,
      generated_at: Time.current
    )
    proposal.save!

    Result.new(created: true, proposal: proposal, reason: nil)
  end

  private

  def unsupported(reason)
    Result.new(created: false, proposal: nil, reason: reason)
  end

  def aerodrome_position?(position)
    position.dex.name == "aerodrome_slipstream"
  end

  def missing_amount_or_price?(position)
    [
      position.asset0_amount,
      position.asset1_amount,
      position.asset0_price_usd,
      position.asset1_price_usd
    ].any?(&:nil?)
  end

  def configured_token_addresses_for(position)
    symbols = [ position.asset0.to_s.upcase, position.asset1.to_s.upcase ]
    return unless symbols.sort == [ "USDC", "WETH" ]

    {
      token0_address: symbols[0] == "WETH" ? @weth_address : @usdc_address,
      token1_address: symbols[1] == "WETH" ? @weth_address : @usdc_address
    }
  end
end
