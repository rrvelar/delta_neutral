require "test_helper"

class EtherealHedgeExecutionServiceTest < ActiveSupport::TestCase
  FakeHedge = Struct.new(:execution_venue, keyword_init: true) do
    def id = 42
    def ethereal_execution? = execution_venue == "ethereal"
  end

  FakePosition = Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
    def active? = true
    def mellow_autopilot? = true
    def hedge_ready? = true
    def mellow_weth_exposure = BigDecimal("0.8")
    def mellow_current_value_usd = BigDecimal("2000")
    def mellow_usdc_exposure = BigDecimal("400")
  end

  FakeVenue = Struct.new(:position, keyword_init: true) do
    def live_enabled? = false
    def live_mode_state = "read_only_dry_run"
    def round_order_size(value) = (BigDecimal(value.to_s) / BigDecimal("0.001")).floor * BigDecimal("0.001")
    def account_state = { account_value_usd: "5000", collateral_usd: "5000" }
    def read_position(symbol:) = position
  end

  test "open preview builds Ethereal cross-margin sell without isolated fields" do
    service = build_service
    order = service.build_order_preview(position: fake_position, action: "open", size_eth: "0.1234", current_position: nil, max_slippage: "0.01")

    assert_equal "ethereal_eip712_trade_order", order.fetch(:schema)
    assert_equal "POST /v1/order", order.fetch(:endpoint)
    assert_equal "cross", order.fetch(:margin_mode)
    assert_equal "sell", order.dig(:summary, :side)
    assert_equal false, order.dig(:summary, :reduce_only)
    assert_equal "0.123", order.dig(:summary, :rounded_size_eth)
    assert_no_match(/isolated_margin|appendix/i, order.to_json)
  end

  test "decrease preview builds reduce-only buy delta" do
    service = build_service
    current = ethereal_short("0.5")
    order = service.build_order_preview(position: fake_position, action: "rebalance", size_eth: "-0.05", current_position: current, max_slippage: "0.01")

    assert_equal "buy", order.dig(:summary, :side)
    assert_equal true, order.dig(:summary, :reduce_only)
    assert_equal "0.05", order.dig(:summary, :rounded_size_eth)
    assert_equal "0.45", order.dig(:summary, :expected_after_short_eth)
    assert_equal true, order.dig(:submit_payload, :data, :reduceOnly)
    assert_equal 0, order.dig(:submit_payload, :data, :side)
  end

  test "rebalance decrease receipt expected short subtracts reduce-only size" do
    reads = [ ethereal_short("0.5"), ethereal_short("0.45") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:live_enabled?) { true }
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-1" } }
    )

    result = service.rebalance_short(
      position: fake_position,
      delta_eth: "-0.05",
      current_position: ethereal_short("0.5"),
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "0.45", result.receipt.fetch(:expected_short_eth)
    assert_equal "0.45", result.receipt.dig(:post_submit_readback, :short_size)
  end

  test "live mode blocks without Ethereal venue and confirmation" do
    service = build_service
    position = fake_position(execution_venue: "nado")
    report = service.preflight(
      position: position,
      action: "open",
      size_eth: "0.1",
      current_position: nil,
      confirmation: "wrong",
      max_slippage: "0.01"
    )

    assert_includes report.fetch(:blockers), "selected hedge execution venue must be ethereal"
    assert_includes report.fetch(:blockers), "submitted confirmation must equal #{EtherealHedgeExecutionService::CONFIRMATION}"
  end

  test "live preflight requires signer health to advertise Ethereal support" do
    service = build_service(
      http_get: ->(uri) {
        body = if uri.to_s.end_with?("/health")
          { ok: true, supported_exchanges: [ "Nado" ], supported_actions: [ "place_order" ] }
        else
          { domain: EtherealHedgeExecutionService::DOMAIN }
        end
        Struct.new(:body).new(body.to_json)
      }
    )

    report = service.preflight(
      position: fake_position,
      action: "open",
      size_eth: "0.1",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_includes report.fetch(:blockers), "Ethereal signer service does not advertise Ethereal support"
  end

  test "live preflight accepts mocked signer health with Ethereal support" do
    service = build_service(
      http_get: ->(uri) {
        body = if uri.to_s.end_with?("/health")
          { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ] }
        else
          { domain: EtherealHedgeExecutionService::DOMAIN }
        end
        Struct.new(:body).new(body.to_json)
      }
    )

    report = service.preflight(
      position: fake_position,
      action: "open",
      size_eth: "0.1",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_not_includes report.fetch(:blockers), "Ethereal signer service does not advertise Ethereal support"
  end

  test "live preflight deduplicates missing linked signer blocker" do
    service = build_service
    service.instance_variable_set(:@env, service.instance_variable_get(:@env).except("ETHEREAL_LINKED_SIGNER_ADDRESS"))

    report = service.preflight(
      position: fake_position,
      action: "open",
      size_eth: "0.1",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal 1, report.fetch(:blockers).count { |blocker| blocker == "ETHEREAL_LINKED_SIGNER_ADDRESS is required" }
    assert_not_includes report.fetch(:blockers), "ETHEREAL_LINKED_SIGNER_ADDRESS is required for Ethereal order payloads"
    assert_equal report.fetch(:blockers).uniq, report.fetch(:blockers)
  end

  test "accepted submit requires readback confirmation before success" do
    reads = [ ethereal_short("0.5"), ethereal_short("0.55") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:live_enabled?) { true }
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-1" } }
    )

    result = service.rebalance_short(
      position: fake_position,
      delta_eth: "0.05",
      current_position: ethereal_short("0.5"),
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "eth-1", result.receipt.fetch(:exchange_order_id)
    assert_equal "0.55", result.receipt.dig(:post_submit_readback, :short_size)
    assert_no_match(/0xsig|private|cookie|auth/i, result.receipt.to_json)
  end

  test "delta probe dry-run decrease builds buy reduce-only delta order" do
    service = build_service

    result = service.delta_probe(
      position: fake_position,
      direction: "decrease",
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: nil,
      max_slippage: "0.01",
      dry_run: true
    )

    summary = result.receipt.fetch(:payload_summary)
    assert_equal "dry_run", result.status
    assert_equal "decrease", summary.fetch(:probe_direction)
    assert_equal "buy", summary.fetch(:side)
    assert_equal true, summary.fetch(:reduce_only)
    assert_equal "0.005", summary.fetch(:rounded_size_eth)
    assert_equal "0.5557", summary.fetch(:expected_after_short_eth)
    assert_equal false, summary.fetch(:close_reopen)
    assert_equal false, summary.fetch(:full_close)
    assert_no_match(/isolated|appendix/i, result.receipt.to_json)
    assert_no_match(/0xsig|private_key|authorization|cookie/i, result.receipt.to_json)
  end

  test "delta probe dry-run increase builds sell non reduce-only delta order" do
    service = build_service

    result = service.delta_probe(
      position: fake_position,
      direction: "increase",
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: nil,
      max_slippage: "0.01",
      dry_run: true
    )

    summary = result.receipt.fetch(:payload_summary)
    assert_equal "dry_run", result.status
    assert_equal "increase", summary.fetch(:probe_direction)
    assert_equal "sell", summary.fetch(:side)
    assert_equal false, summary.fetch(:reduce_only)
    assert_equal "0.5657", summary.fetch(:expected_after_short_eth)
  end

  test "delta probe live mode refuses without explicit env gate and confirmation" do
    service = build_service(signer_post: ->(*) { raise "signer should not be called" })

    result = service.delta_probe(
      position: fake_position,
      direction: "decrease",
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: "wrong",
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "AERODROME_ETHEREAL_DELTA_PROBE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{EtherealHedgeExecutionService::DELTA_PROBE_CONFIRMATION}"
  end

  test "delta probe decrease success requires readback before minus delta" do
    submitted = []
    reads = [ ethereal_short("0.5557") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_DELTA_PROBE_ENABLED" => "true" },
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, payload) {
        submitted << payload
        { status: "SUBMITTED", id: "eth-delta-1" }
      }
    )

    result = service.delta_probe(
      position: fake_position,
      direction: "decrease",
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "eth-delta-1", result.receipt.fetch(:exchange_order_id)
    assert_equal true, submitted.first.dig(:data, :reduceOnly)
    assert_equal 0, submitted.first.dig(:data, :side)
    assert_equal "0.5557", result.receipt.fetch(:expected_after_short_eth)
    assert_equal "0.5557", result.receipt.fetch(:after_readback).fetch(:short_size)
    assert_no_match(/0xsig|private_key|authorization|cookie/i, result.receipt.to_json)
  end

  test "delta probe increase success requires readback before plus delta" do
    reads = [ ethereal_short("0.5657") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_DELTA_PROBE_ENABLED" => "true" },
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-delta-2" } }
    )

    result = service.delta_probe(
      position: fake_position,
      direction: "increase",
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "0.5657", result.receipt.fetch(:expected_after_short_eth)
    assert_equal "0.5657", result.receipt.fetch(:after_readback).fetch(:short_size)
  end

  test "delta probe round trip does not run increase after failed decrease" do
    submitted = []
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_DELTA_PROBE_ENABLED" => "true" },
      venue: FakeVenue.new(position: ethereal_short("0.5607")),
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, payload) {
        submitted << payload
        { status: "REJECTED", message: "blocked by exchange" }
      }
    )

    result = service.round_trip_delta_probe(
      position: fake_position,
      size_eth: "0.005",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal 1, submitted.size
    assert_equal "failed_before_submit", result.status
    assert_nil result.receipt.fetch(:increase_leg)
    assert_match "increase leg was not submitted", result.receipt.fetch(:final_message)
  end

  test "close probe dry-run close only builds buy reduce-only full-size close" do
    service = build_service

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_only",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: nil,
      max_slippage: "0.01",
      dry_run: true
    )

    close = result.receipt.fetch(:close_payload_summary)
    assert_equal "dry_run", result.status
    assert_equal "buy", close.fetch(:side)
    assert_equal true, close.fetch(:reduce_only)
    assert_equal "0.56", close.fetch(:rounded_size_eth)
    assert_equal "0.0", close.fetch(:expected_after_short_eth)
    assert_nil result.receipt[:reopen_payload_summary]
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "close probe dry-run close reopen builds close then target sell reopen" do
    service = build_service

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_reopen",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: nil,
      max_slippage: "0.01",
      dry_run: true
    )

    close = result.receipt.fetch(:close_payload_summary)
    reopen = result.receipt.fetch(:reopen_payload_summary)
    assert_equal "buy", close.fetch(:side)
    assert_equal true, close.fetch(:reduce_only)
    assert_equal "sell", reopen.fetch(:side)
    assert_equal false, reopen.fetch(:reduce_only)
    assert_equal "0.8", reopen.fetch(:rounded_size_eth)
    assert_equal "0.8", reopen.fetch(:expected_after_short_eth)
  end

  test "close probe live mode refuses without explicit env gate and confirmation" do
    service = build_service(signer_post: ->(*) { raise "signer should not be called" })

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_only",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: "wrong",
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{EtherealHedgeExecutionService::CLOSE_PROBE_CONFIRMATION}"
  end

  test "close probe close only success requires flat readback" do
    submitted = []
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:read_position) { |symbol:| nil }
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED" => "true" },
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, payload) {
        submitted << payload
        { status: "SUBMITTED", id: "eth-close-1" }
      }
    )

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_only",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::CLOSE_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal 1, submitted.size
    assert_equal true, submitted.first.dig(:data, :reduceOnly)
    assert_equal 0, submitted.first.dig(:data, :side)
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_nil result.receipt[:reopen_submit_classification]
    assert_no_match(/0xsig|private_key|authorization|cookie/i, result.receipt.to_json)
  end

  test "close reopen does not submit reopen unless flat readback is confirmed" do
    submitted = []
    venue = FakeVenue.new(position: ethereal_short("0.5607"))
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED" => "true" },
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, payload) {
        submitted << payload
        { status: "SUBMITTED", id: "eth-close-1" }
      }
    )

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_reopen",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::CLOSE_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "submitted_but_readback_pending", result.status
    assert_equal 1, submitted.size
    assert_nil result.receipt[:reopen_submit_classification]
  end

  test "close reopen success requires final target short readback" do
    submitted = []
    reads = [ nil, ethereal_short("0.8") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      env_extra: { "AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED" => "true" },
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, payload) {
        order_id = submitted.empty? ? "eth-close-1" : "eth-open-1"
        submitted << payload
        { status: "SUBMITTED", id: order_id }
      }
    )

    result = service.close_reopen_probe(
      position: fake_position,
      mode: "close_reopen",
      target_size_eth: "0.8",
      current_position: ethereal_short("0.5607"),
      confirmation: EtherealHedgeExecutionService::CLOSE_PROBE_CONFIRMATION,
      max_slippage: "0.01",
      dry_run: false
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal 2, submitted.size
    assert_equal true, submitted.first.dig(:data, :reduceOnly)
    assert_equal false, submitted.second.dig(:data, :reduceOnly)
    assert_equal "0.8", result.receipt.fetch(:final_readback).fetch(:short_size)
    assert_equal 2, result.receipt.fetch(:orders_placed)
    assert_equal [ "eth-close-1", "eth-open-1" ], result.receipt.fetch(:exchange_order_ids)
  end

  test "signer request uses external eip712 endpoint and includes parity diagnostics" do
    signer_calls = []
    venue = FakeVenue.new(position: ethereal_short("0.5"))
    venue.define_singleton_method(:live_enabled?) { true }
    service = build_service(
      venue: venue,
      signer_post: ->(uri, payload) {
        signer_calls << [ uri.to_s, payload ]
        { status: "blocked", reason: "stop before submit" }
      }
    )

    result = service.rebalance_short(
      position: fake_position,
      delta_eth: "0.05",
      current_position: ethereal_short("0.5"),
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_equal "failed_before_submit", result.status
    assert_equal "http://127.0.0.1:8787/sign/eip712", signer_calls.dig(0, 0)
    payload = signer_calls.dig(0, 1)
    assert_equal "Ethereal", payload.fetch(:exchange)
    assert_equal "place_order", payload.fetch(:action)
    assert_equal "eip712", payload.fetch(:signing_standard)
    assert_match(/\Asha256:/, payload.fetch(:typed_data_hash))
    assert_equal "0x0000000000000000000000000000000000000001", payload.fetch(:expected_signer_address)
  end

  test "uuid subaccount is resolved through GET subaccount id response name" do
    uuid = "5a1f8999-73f3-426d-9532-41014a7a66aa"
    subaccount = "0x7072696d61727900000000000000000000000000000000000000000000000000"
    get_calls = []
    service = EtherealHedgeExecutionService.new(
      env: {
        "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
        "ETHEREAL_SUBACCOUNT_ID" => uuid,
        "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
        "ETHEREAL_ONCHAIN_ID" => "2",
        "ETHEREAL_LOT_SIZE" => "0.0001",
        "ETHEREAL_TICK_SIZE" => "0.1"
      },
      venue: FakeVenue.new(position: nil),
      http_get: ->(uri) {
        get_calls << uri.to_s
        body = uri.to_s.include?("/v1/subaccount/") ? { data: { name: subaccount } } : { domain: EtherealHedgeExecutionService::DOMAIN }
        Struct.new(:body).new(body.to_json)
      },
      sleeper: ->(_) { }
    )

    order = service.build_order_preview(position: fake_position, action: "open", size_eth: "0.01", current_position: nil, max_slippage: "0.01")

    assert_includes get_calls.first, "/v1/subaccount/#{uuid}"
    assert get_calls.none? { |url| url.include?("#{uuid}.name") || url.include?("#{uuid}/name") }
    assert_equal subaccount, order.dig(:submit_payload, :data, :subaccount)
    assert_equal subaccount, order.dig(:typed_data, :message, :subaccount)
  end

  test "explicit subaccount name override must be non-zero bytes32" do
    service = build_service
    service.instance_variable_set(:@env, service.instance_variable_get(:@env).merge(
      "ETHEREAL_SUBACCOUNT_NAME" => "0x#{"00" * 32}"
    ))

    report = service.preflight(
      position: fake_position,
      action: "open",
      size_eth: "0.01",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_includes report.fetch(:blockers), "Ethereal signed subaccount mapping unavailable/zero; source=ETHEREAL_SUBACCOUNT_NAME"
  end

  test "missing uuid name fails closed without suffix endpoint" do
    uuid = "5a1f8999-73f3-426d-9532-41014a7a66aa"
    get_calls = []
    service = EtherealHedgeExecutionService.new(
      env: {
        "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
        "ETHEREAL_SUBACCOUNT_ID" => uuid,
        "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
        "ETHEREAL_ONCHAIN_ID" => "2",
        "ETHEREAL_LOT_SIZE" => "0.0001",
        "ETHEREAL_TICK_SIZE" => "0.1"
      },
      venue: FakeVenue.new(position: nil),
      http_get: ->(uri) {
        get_calls << uri.to_s
        Struct.new(:body).new({ id: uuid }.to_json)
      },
      sleeper: ->(_) { }
    )

    report = service.preflight(
      position: fake_position,
      action: "open",
      size_eth: "0.01",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )

    assert_includes report.fetch(:blockers), "Ethereal signed subaccount mapping unavailable/zero; source=GET /v1/subaccount/{id} response.name"
    assert get_calls.any? { |url| url.include?("/v1/subaccount/#{uuid}") }
    assert get_calls.none? { |url| url.include?("#{uuid}.name") || url.include?("#{uuid}/name") }
  end

  private

  def build_service(venue: FakeVenue.new(position: nil), signer_post: nil, http_post: nil, http_get: nil, env_extra: {})
    EtherealHedgeExecutionService.new(
      env: {
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
        "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
        "ETHEREAL_SUBACCOUNT_ID" => "default_1",
        "ETHEREAL_LINKED_SIGNER_ADDRESS" => "0x0000000000000000000000000000000000000001",
        "ETHEREAL_ONCHAIN_ID" => "1",
        "ETHEREAL_LOT_SIZE" => "0.001",
        "ETHEREAL_TICK_SIZE" => "0.1",
        "EXECUTION_SIGNER_URL" => "http://127.0.0.1:8787/sign/eip712"
      }.merge(env_extra),
      venue: venue,
      http_get: http_get || ->(uri) {
        body = if uri.to_s.end_with?("/health")
          { ok: true, supported_exchanges: [ "Nado", "Ethereal" ], supported_actions: [ "place_order" ] }
        else
          { domain: EtherealHedgeExecutionService::DOMAIN }
        end
        Struct.new(:body).new(body.to_json)
      },
      http_post: http_post,
      signer_post: signer_post,
      now: -> { Time.zone.local(2026, 5, 24, 12, 0, 0) },
      sleeper: ->(_) { }
    )
  end

  def fake_position(execution_venue: "ethereal")
    FakePosition.new(id: 7, hedge: FakeHedge.new(execution_venue: execution_venue), asset0_price_usd: BigDecimal("2000"))
  end

  def ethereal_short(size)
    {
      venue: "Ethereal",
      symbol: "ETH-PERP",
      side: "short",
      size: "-#{size}",
      short_size: size,
      margin_mode: "cross",
      mark_price: "2000",
      notional_usd: (BigDecimal(size) * 2000).to_s("F")
    }
  end
end
