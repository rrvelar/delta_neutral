# Read-only operational report for manually checking Aerodrome Slipstream NFTs.
#
# This command object does not write to the database, does not run jobs, does
# not require private keys, and does not call Hyperliquid.
class AerodromeSlipstreamDryRun
  SAFETY_BANNER = "READ-ONLY DRY RUN — no DB writes, no trades, no hedges."

  def initialize(
    token_ids:,
    rpc_url: nil,
    position_manager_address: nil,
    factory_address: nil,
    slipstream_service: nil,
    slipstream_service_class: AerodromeSlipstreamService
  )
    @token_ids = Array(token_ids).map(&:to_s).map(&:strip).compact_blank
    @rpc_url = rpc_url
    @position_manager_address = position_manager_address
    @factory_address = factory_address
    @slipstream_service = slipstream_service
    @slipstream_service_class = slipstream_service_class
  end

  def report
    {
      safety_banner: SAFETY_BANNER,
      database_write: false,
      hedge_enabled: false,
      token_count: @token_ids.size,
      results: @token_ids.map { |token_id| report_token(token_id) }
    }
  end

  private

  def report_token(token_id)
    data = service.fetch_position(token_id)
    {
      token_id: data.token_id,
      status: data.verification_status == "partial" ? "partial" : "ok",
      owner_address: data.owner_address,
      position_manager_address: data.position_manager_address,
      factory_address: data.factory_address,
      pool_address: data.pool_address,
      token0_address: data.token0_address,
      token1_address: data.token1_address,
      token0_symbol: data.token0_symbol,
      token1_symbol: data.token1_symbol,
      token0_decimals: data.token0_decimals,
      token1_decimals: data.token1_decimals,
      tick_spacing: data.tick_spacing,
      tick_lower: data.tick_lower,
      tick_upper: data.tick_upper,
      liquidity: data.liquidity,
      sqrt_price_x96: data.sqrt_price_x96,
      current_tick: data.current_tick,
      tokens_owed0_raw: data.tokens_owed0_raw,
      tokens_owed1_raw: data.tokens_owed1_raw,
      amount0_raw: data.amount0_raw,
      amount1_raw: data.amount1_raw,
      partial_data_reason: data.partial_data_reason,
      hedge_enabled: false,
      database_write: false,
      error_class: nil,
      error_message: nil
    }
  rescue => e
    error_report(token_id, e)
  end

  def service
    @slipstream_service ||= @slipstream_service_class.new(
      rpc_url: @rpc_url,
      position_manager_address: @position_manager_address,
      factory_address: @factory_address
    )
  end

  def error_report(token_id, error)
    {
      token_id: token_id,
      status: "error",
      owner_address: nil,
      position_manager_address: @position_manager_address,
      factory_address: @factory_address,
      pool_address: nil,
      token0_address: nil,
      token1_address: nil,
      token0_symbol: nil,
      token1_symbol: nil,
      token0_decimals: nil,
      token1_decimals: nil,
      tick_spacing: nil,
      tick_lower: nil,
      tick_upper: nil,
      liquidity: nil,
      sqrt_price_x96: nil,
      current_tick: nil,
      tokens_owed0_raw: nil,
      tokens_owed1_raw: nil,
      amount0_raw: nil,
      amount1_raw: nil,
      partial_data_reason: nil,
      hedge_enabled: false,
      database_write: false,
      error_class: error.class.name,
      error_message: error.message
    }
  end
end
