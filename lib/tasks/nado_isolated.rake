namespace :nado do
  desc "No-live Nado isolated payload parity check"
  task isolated_payload_check: :environment do
    env = {
      "NADO_API_BASE_URL" => "https://nado.invalid/v1",
      "NADO_ACCOUNT_ADDRESS" => "0x#{"11" * 20}",
      "NADO_ACCOUNT_SUBACCOUNT" => "0x#{"01" * 32}",
      "NADO_ETH_PERP_PRODUCT_METADATA_JSON" => {
        product_id: 4,
        chain_id: 1,
        price_increment_x18: "100000000000000000",
        size_increment: "1000000000000000",
        market_price: "2300"
      }.to_json
    }
    service = NadoHedgeExecutionService.new(env: env)
    position = Position.new(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "0.809",
      asset1_amount: "240",
      asset0_price_usd: "2300",
      asset1_price_usd: "1",
      mellow_metadata: {
        hedge_ready: true,
        user_weth_exposure: "0.809",
        user_usdc_exposure: "240",
        user_total_value_usd: "2100.7"
      }.to_json
    )
    current = {
      size: BigDecimal("-0.809"),
      short_size: BigDecimal("0.809"),
      symbol: "ETH-PERP",
      side: "short",
      margin_mode: "isolated",
      isolated_margin_usd: BigDecimal("1860.7"),
      metadata: { raw: { "subaccount" => "0x#{"02" * 32}" } }
    }
    close = service.build_order_preview(position: position, action: "close", size_eth: BigDecimal("0.809"), max_slippage: "0.01", current_position: current)
    increase = service.build_order_preview(position: position, action: "rebalance", size_eth: BigDecimal("0.047"), max_slippage: "0.01", current_position: current)
    plan = service.plan_rebalance(target_size_eth: BigDecimal("0.762"), current_position: current, tolerance_eth: BigDecimal("0.001"))
    failures = []
    failures << "close appendix must be UI-equivalent 2817" unless close.dig(:summary, :appendix).to_s == "2817"
    failures << "close sender must be default_1" unless close.dig(:summary, :order_sender_kind) == "default_1"
    failures << "close amount must be positive buy full size" unless close.dig(:summary, :amount_x18).to_s == "809000000000000000"
    failures << "increase amount must be negative sell delta" unless increase.dig(:summary, :amount_x18).to_s == "-47000000000000000"
    failures << "target decrease must plan close/reopen while partial reduce is unproven" unless plan[:action] == "isolated_full_close_then_reopen"
    result = {
      status: failures.empty? ? "PASS" : "FAIL",
      failures: failures,
      statement: "No orders submitted and no signatures created.",
      source: "delta_neutral no-live Nado isolated payload parity check",
      close_summary: close[:summary].except(:signature),
      increase_summary: increase[:summary].except(:signature),
      decrease_plan: plan
    }
    puts JSON.pretty_generate(result)
    abort("Nado isolated payload check failed") if failures.any?
  end
end
