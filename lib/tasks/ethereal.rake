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

  desc "Controlled Ethereal cross-margin delta-order live verification path; dry-run by default"
  task delta_live_check: :environment do
    direction = (ENV["direction"] || ENV["DIRECTION"] || "decrease").to_s.downcase
    size_eth = BigDecimal((ENV["size_eth"] || ENV["SIZE_ETH"] || "0.005").to_s)
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    position = ethereal_delta_probe_position
    current_position = ethereal_delta_probe_current_position
    service = ethereal_delta_probe_service(current_position)

    result = if direction == "round_trip"
      service.round_trip_delta_probe(
        position: position,
        size_eth: size_eth,
        current_position: current_position,
        confirmation: confirmation,
        max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
        dry_run: dry_run
      )
    else
      service.delta_probe(
        position: position,
        direction: direction,
        size_eth: size_eth,
        current_position: current_position,
        confirmation: confirmation,
        max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
        dry_run: dry_run
      )
    end

    receipt_path = Rails.root.join("storage", "ethereal_delta_live_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt)) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    abort("Ethereal delta probe did not pass: #{result.status}") unless result.status.in?(%w[dry_run submitted_and_confirmed])
  end

  desc "Controlled Ethereal full close and optional reopen live verification path; dry-run by default"
  task close_reopen_live_check: :environment do
    mode = (ENV["mode"] || ENV["MODE"] || "close_only").to_s.downcase
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    position = ethereal_delta_probe_position
    current_position = ethereal_delta_probe_current_position
    target_size = ethereal_close_probe_target_size(position)
    service = ethereal_delta_probe_service(current_position)

    result = service.close_reopen_probe(
      position: position,
      mode: mode,
      target_size_eth: target_size,
      current_position: current_position,
      confirmation: confirmation,
      max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
      dry_run: dry_run
    )

    receipt_path = Rails.root.join("storage", "ethereal_close_reopen_live_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt)) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    abort("Ethereal close/reopen probe did not pass: #{result.status}") unless result.status.in?(%w[dry_run submitted_and_confirmed])
  end

  def ethereal_close_probe_target_size(position)
    hedge = position.hedge
    valuation = PositionValuation.current(position)
    exposure = valuation.weth_exposure || position.mellow_weth_exposure
    return BigDecimal("0") unless hedge && exposure

    BigDecimal(exposure.to_s) * BigDecimal(hedge.target.to_s)
  end

  def ethereal_delta_probe_position
    return ethereal_delta_probe_mock_position if ActiveModel::Type::Boolean.new.cast(ENV["MOCK_ETHEREAL_READBACK"])

    Position.find(ENV["position_id"] || ENV["POSITION_ID"] || 3)
  end

  def ethereal_delta_probe_mock_position
    hedge = Struct.new(:id, :target, keyword_init: true) do
      def ethereal_execution? = true
    end.new(id: ENV["HEDGE_ID"] || 3, target: BigDecimal("1.0"))
    Struct.new(:id, :hedge, :asset0_price_usd, :external_id, keyword_init: true) do
      def active? = true
      def mellow_autopilot? = true
      def hedge_ready? = true
      def position_source = Position::SOURCE_MELLOW_AUTOPILOT
      def mellow_weth_exposure = BigDecimal("0.5607")
      def mellow_usdc_exposure = BigDecimal("240")
      def mellow_current_value_usd = BigDecimal("1417.47")
      def mellow_metadata_hash = { "hedge_ready" => true, "last_probe_confidence" => "high" }
      def entry_value_usd = BigDecimal("1417.47")
    end.new(
      id: ENV["position_id"] || ENV["POSITION_ID"] || 3,
      hedge: hedge,
      asset0_price_usd: BigDecimal("2100"),
      external_id: "mellow:mock-ethereal-delta-probe"
    )
  end

  def ethereal_delta_probe_current_position
    return ethereal_delta_probe_mock_readback if ActiveModel::Type::Boolean.new.cast(ENV["MOCK_ETHEREAL_READBACK"])

    HedgeVenues::Ethereal.new.read_position(symbol: "ETH")
  end

  def ethereal_delta_probe_mock_readback(size: BigDecimal("0.5607"))
    {
      venue: "Ethereal",
      symbol: "ETH-PERP",
      side: "short",
      size: "-#{size.to_s('F')}",
      short_size: size.to_s("F"),
      margin_mode: "cross",
      mark_price: "2100",
      notional_usd: (size * BigDecimal("2100")).to_s("F"),
      account_value_usd: "5000"
    }
  end

  def ethereal_delta_probe_service(current_position)
    mock = ActiveModel::Type::Boolean.new.cast(ENV["MOCK_ETHEREAL_READBACK"])
    env = mock ? ethereal_delta_probe_mock_env : ENV
    venue = mock ? EtherealDeltaProbeMockVenue.new([ current_position ], env: env) : nil
    EtherealHedgeExecutionService.new(env: env, venue: venue, sleeper: ->(_seconds) { })
  end

  def ethereal_delta_probe_mock_env
    {
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.invalid",
      "ETHEREAL_SUBACCOUNT_ID" => "0x7072696d61727900000000000000000000000000000000000000000000000000",
      "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
      "ETHEREAL_ONCHAIN_ID" => "2",
      "ETHEREAL_LOT_SIZE" => "0.0001",
      "ETHEREAL_TICK_SIZE" => "0.1",
      "EXECUTION_SIGNER_URL" => "http://127.0.0.1:8787/sign/eip712"
    }
  end

  class EtherealDeltaProbeMockVenue
    def initialize(readbacks, env:)
      @readbacks = readbacks
      @env = env
    end

    def live_mode_state = "live_gated"

    def live_enabled? = false

    def round_order_size(value)
      lot = BigDecimal(@env.fetch("ETHEREAL_LOT_SIZE", "0.0001"))
      (BigDecimal(value.to_s) / lot).floor * lot
    end

    def account_state = { account_value_usd: "5000", collateral_usd: "5000" }

    def read_position(symbol:)
      raise "unexpected symbol" unless symbol == "ETH"

      @readbacks.last
    end
  end
end
