namespace :ethereal do
  desc "Build Ethereal hedge order payloads without signing or submitting"
  task hedge_payload_check: :environment do
    position_id = ENV.fetch("POSITION_ID", nil)
    position = position_id.present? ? Position.find(position_id) : Position.active_hedgeable.order(id: :desc).first
    unless position
      fake_hedge = Struct.new(:id, keyword_init: true) do
        def ethereal_execution? = true
      end.new(id: nil)
      position = Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
        def active? = true
        def mellow_autopilot? = true
        def hedge_ready? = true
        def mellow_weth_exposure = BigDecimal("0.8")
        def mellow_current_value_usd = BigDecimal("2000")
        def mellow_usdc_exposure = BigDecimal("400")
      end.new(id: "synthetic", hedge: fake_hedge, asset0_price_usd: BigDecimal("2000"))
    end

    current_position = {
      venue: "Ethereal",
      symbol: "ETH-PERP",
      side: "short",
      size: "-0.5",
      short_size: "0.5",
      margin_mode: "cross",
      mark_price: position.asset0_price_usd&.to_s || "2000",
      notional_usd: "1000",
      account_value_usd: "5000"
    }
    service = EtherealHedgeExecutionService.new(
      env: ENV.to_h.merge(
        "ETHEREAL_READ_ONLY_ENABLED" => "true",
        "ETHEREAL_API_BASE_URL" => ENV.fetch("ETHEREAL_API_BASE_URL", "https://ethereal.invalid"),
        "ETHEREAL_SUBACCOUNT_ID" => ENV.fetch("ETHEREAL_SUBACCOUNT_ID", "default_1"),
        "ETHEREAL_LINKED_SIGNER_ADDRESS" => ENV.fetch("ETHEREAL_LINKED_SIGNER_ADDRESS", "0x0000000000000000000000000000000000000000"),
        "ETHEREAL_ONCHAIN_ID" => ENV.fetch("ETHEREAL_ONCHAIN_ID", "2"),
        "ETHEREAL_LOT_SIZE" => ENV.fetch("ETHEREAL_LOT_SIZE", "0.0001"),
        "ETHEREAL_TICK_SIZE" => ENV.fetch("ETHEREAL_TICK_SIZE", "0.1")
      ),
      http_get: ->(uri) {
        body = if uri.to_s.include?("/v1/subaccount/")
          { id: ENV["ETHEREAL_SUBACCOUNT_ID"], name: ENV.fetch("ETHEREAL_SUBACCOUNT_NAME", "0x7072696d61727900000000000000000000000000000000000000000000000000") }
        elsif uri.to_s.end_with?("/health")
          { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ], mode: "eip712_external" }
        else
          { domain: EtherealHedgeExecutionService::DOMAIN }
        end
        Struct.new(:body).new(body.to_json)
      },
      sleeper: ->(_) { }
    )

    checks = {
      open: service.build_order_preview(position: position, action: "open", size_eth: "0.01", current_position: nil, max_slippage: "0.01"),
      increase: service.build_order_preview(position: position, action: "rebalance", size_eth: "0.01", current_position: current_position, max_slippage: "0.01"),
      decrease: service.build_order_preview(position: position, action: "rebalance", size_eth: "-0.01", current_position: current_position, max_slippage: "0.01"),
      close: service.build_order_preview(position: position, action: "close", size_eth: "0.5", current_position: current_position, max_slippage: "0.01")
    }
    summary = checks.transform_values do |order|
      {
        schema: order[:schema],
        endpoint: order[:endpoint],
        margin_mode: order[:margin_mode],
        side: order.dig(:summary, :side),
        reduce_only: order.dig(:summary, :reduce_only),
        quantity: order.dig(:summary, :rounded_size_eth),
        isolated_fields_present: order.to_json.match?(/isolated_margin|isolated_margin_x6|appendix/i)
      }
    end
    signer_preflight = EtherealHedgeExecutionService.new(
      env: ENV.to_h.merge(
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
        "ETHEREAL_READ_ONLY_ENABLED" => "true",
        "ETHEREAL_API_BASE_URL" => ENV.fetch("ETHEREAL_API_BASE_URL", "https://ethereal.invalid"),
        "ETHEREAL_SUBACCOUNT_ID" => ENV.fetch("ETHEREAL_SUBACCOUNT_ID", "default_1"),
        "ETHEREAL_LINKED_SIGNER_ADDRESS" => ENV.fetch("ETHEREAL_LINKED_SIGNER_ADDRESS", "0x0000000000000000000000000000000000000000"),
        "ETHEREAL_ONCHAIN_ID" => ENV.fetch("ETHEREAL_ONCHAIN_ID", "2"),
        "ETHEREAL_LOT_SIZE" => ENV.fetch("ETHEREAL_LOT_SIZE", "0.0001"),
        "ETHEREAL_TICK_SIZE" => ENV.fetch("ETHEREAL_TICK_SIZE", "0.1"),
        "EXECUTION_SIGNER_URL" => "http://mock-ethereal-signer.local"
      ),
      http_get: ->(uri) {
        body = if uri.to_s.include?("/v1/subaccount/")
          { id: ENV["ETHEREAL_SUBACCOUNT_ID"], name: ENV.fetch("ETHEREAL_SUBACCOUNT_NAME", "0x7072696d61727900000000000000000000000000000000000000000000000000") }
        elsif uri.to_s.end_with?("/health")
          { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ], mode: "eip712_external" }
        else
          { domain: EtherealHedgeExecutionService::DOMAIN }
        end
        Struct.new(:body).new(body.to_json)
      },
      sleeper: ->(_) { }
    ).preflight(
      position: position,
      action: "open",
      size_eth: "0.01",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )
    summary[:mocked_signer_health] = {
      supported_exchanges: [ "Nado", "Ethereal" ],
      supported_actions: [ "place_order" ],
      ethereal_support_gate_passed: !signer_preflight.fetch(:blockers).include?("Ethereal signer service does not advertise Ethereal support"),
      orders_placed: 0,
      signatures_created: 0
    }
    puts JSON.pretty_generate(summary)
    abort "Ethereal check failed: isolated fields present" if summary.values.any? { |item| item[:isolated_fields_present] }
    abort "Ethereal check failed: decrease is not reduce-only buy" unless summary[:decrease][:side] == "buy" && summary[:decrease][:reduce_only]
    abort "Ethereal check failed: close is not reduce-only buy" unless summary[:close][:side] == "buy" && summary[:close][:reduce_only]
    abort "Ethereal check failed: mocked signer health did not advertise Ethereal support" unless summary[:mocked_signer_health][:ethereal_support_gate_passed]
  end
end
