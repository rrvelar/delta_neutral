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

  test "migration target leg preflight does not require production venue already ethereal" do
    service = build_service
    position = fake_position(execution_venue: "extended")
    report = service.preflight(
      position: position,
      action: "open",
      size_eth: "0.1",
      current_position: nil,
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01",
      migration_target_leg: true
    )

    assert_not_includes report.fetch(:blockers), "selected hedge execution venue must be ethereal"
    assert_not report.fetch(:blockers).any? { |blocker| blocker.to_s.start_with?("Current active hedge venue is") }
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

  test "target leg readback confirms rounded expected short" do
    reads = [ ethereal_short("1.0027") ]
    venue = FakeVenue.new(position: nil)
    venue.define_singleton_method(:round_order_size) { |value| (BigDecimal(value.to_s) / BigDecimal("0.0001")).floor * BigDecimal("0.0001") }
    venue.define_singleton_method(:live_enabled?) { true }
    venue.define_singleton_method(:read_position) { |symbol:| reads.shift }
    service = build_service(
      venue: venue,
      env_extra: { "ETHEREAL_LOT_SIZE" => "0.0001" },
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-target-1" } }
    )

    result = service.open_short(
      position: fake_position(execution_venue: "extended"),
      size_eth: "1.00275492301127",
      current_position: nil,
      confirmation: nil,
      max_slippage: "0.01",
      require_confirmation: false,
      migration: true
    )

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "1.0027", result.receipt.fetch(:expected_short_eth)
    assert_equal "1.0027", result.receipt.dig(:post_submit_readback, :short_size)
    assert_equal true, result.receipt.fetch(:readback_poll_attempts).first.fetch(:confirmed)
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

  # --- fast reduce-only close fill confirmation ---

  def close_fill_service(order_status_get:, position:, enabled: true, read_counter: nil, status_counter: nil)
    venue = FakeVenue.new(position: position)
    venue.define_singleton_method(:live_enabled?) { true }
    venue.define_singleton_method(:read_position) do |symbol:|
      read_counter << :read if read_counter
      position
    end
    wrapped_status = lambda do |order_id|
      status_counter << :status if status_counter
      order_status_get.call(order_id)
    end
    build_service(
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-close-1" } },
      order_status_get: wrapped_status,
      env_extra: enabled ? { "ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED" => "true" } : {}
    )
  end

  def run_close(service)
    service.close_short(
      position: fake_position,
      size_eth: "1.7025",
      current_position: ethereal_short("1.7025"),
      confirmation: EtherealHedgeExecutionService::CONFIRMATION,
      max_slippage: "0.01"
    )
  end

  test "reduce-only close confirms via fast order fill before slow position polling" do
    reads = []
    filled = ->(_id) { { status: "FILLED", filled_eth: "1.702", remaining_eth: "0", reduce_only: true } }
    # Position endpoint still reports a short (lagging); fill status is authoritative.
    service = close_fill_service(order_status_get: filled, position: ethereal_short("1.7025"), read_counter: reads)

    result = run_close(service)

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "ethereal_order_list_fill", result.receipt.fetch(:readback_poll_attempts).first.fetch(:source)
    assert_operator reads.size, :<=, 1, "should not fall back to the 12-attempt position poll"
    # The authoritative close-fill confirmation is surfaced for the executor.
    cfc = result.receipt.fetch(:close_fill_confirmation)
    assert_equal true, cfc[:confirmed]
    assert_equal "ethereal_order_list_fill", cfc[:source]
    assert_equal true, cfc[:reduce_only]
    assert cfc[:confirmed_at].present?
  end

  test "close falls back fail-closed to position readback when order fill is unavailable" do
    reads = []
    unavailable = ->(_id) { nil }
    # Position reads flat, so the fallback poll confirms.
    service = close_fill_service(order_status_get: unavailable, position: nil, read_counter: reads)

    result = run_close(service)

    assert_equal "submitted_and_confirmed", result.status
    refute_equal "order_fill", result.receipt.fetch(:readback_poll_attempts).first.fetch(:source, nil)
    assert_operator reads.size, :>=, 1
  end

  test "partial fill never confirms flat" do
    partial = ->(_id) { { status: "PARTIALLY_FILLED", filled_eth: "0.5", remaining_eth: "1.2", reduce_only: true } }
    # Position still short -> fallback poll also cannot confirm -> pending, never flat.
    service = close_fill_service(order_status_get: partial, position: ethereal_short("1.2"))

    result = run_close(service)

    assert_equal "submitted_but_readback_pending", result.status
    assert result.receipt.fetch(:readback_poll_attempts).none? { |a| a[:classification] == "filled" }
  end

  test "non-reduce-only order fill is ignored and falls back to position readback" do
    reads = []
    non_reduce = ->(_id) { { status: "FILLED", filled_eth: "1.702", remaining_eth: "0", reduce_only: false } }
    service = close_fill_service(order_status_get: non_reduce, position: nil, read_counter: reads)

    result = run_close(service)

    assert_equal "submitted_and_confirmed", result.status
    assert_operator reads.size, :>=, 1, "must confirm via authoritative position readback, not a non-reduce-only fill"
  end

  test "fast fill confirmation is disabled by default and does not query order status" do
    status_calls = []
    filled = ->(_id) { { status: "FILLED", filled_eth: "1.702", remaining_eth: "0", reduce_only: true } }
    # Feature OFF: even a FILLED order status is ignored; position (still short) drives the result.
    service = close_fill_service(order_status_get: filled, position: ethereal_short("1.7025"), enabled: false, status_counter: status_calls)

    result = run_close(service)

    assert_equal "submitted_but_readback_pending", result.status
    assert_empty status_calls, "order status must not be queried when the feature is disabled"
  end

  # Real Ethereal order shape captured read-only from GET /v1/order?subaccountId=...
  # for the Step 3 filled reduce-only close (order c91e028d-...).
  def real_ethereal_filled_close_order
    {
      "id" => "c91e028d-748e-4770-adfb-a71d083c4983",
      "clientOrderId" => "6close1",
      "type" => "LIMIT",
      "quantity" => "1.7025",
      "availableQuantity" => "1.7025",
      "side" => 0,
      "productId" => "480014cc-536e-4fd4-958b-b2afcf8ce09f",
      "status" => "FILLED",
      "filled" => "1.7025",
      "reduceOnly" => true,
      "close" => true
    }
  end

  test "normalize_ethereal_order maps the real filled reduce-only close shape" do
    service = build_service
    status = service.send(:normalize_ethereal_order, real_ethereal_filled_close_order)

    assert_equal "FILLED", status[:status]
    assert_equal "1.7025", status[:filled_eth]
    assert_equal "0.0", status[:remaining_eth]
    assert_equal true, status[:reduce_only]
    assert_equal :filled, service.send(:classify_close_fill, status, close_size: BigDecimal("1.702"))
  end

  test "normalize_ethereal_order derives remaining from quantity minus filled, ignoring availableQuantity" do
    service = build_service
    # availableQuantity stays at quantity (as the live API reports) but the order is
    # only partially filled -> remaining must come from quantity - filled.
    order = real_ethereal_filled_close_order.merge("filled" => "1.0", "status" => "SUBMITTED")
    status = service.send(:normalize_ethereal_order, order)

    assert_equal "0.7025", status[:remaining_eth]
    assert_equal :partial, service.send(:classify_close_fill, status, close_size: BigDecimal("1.702"))
  end

  test "get_order_status returns nil when the subaccount is not configured (fail closed)" do
    service = build_service(env_extra: { "ETHEREAL_SUBACCOUNT_ID" => "" })

    assert_nil service.send(:get_order_status, "c91e028d-748e-4770-adfb-a71d083c4983")
  end

  # --- fast target-open fill confirmation ---

  def open_fill_service(order_status_get:, position:, enabled: true, read_counter: nil, status_counter: nil)
    venue = FakeVenue.new(position: position)
    venue.define_singleton_method(:live_enabled?) { true }
    venue.define_singleton_method(:read_position) do |symbol:|
      read_counter << :read if read_counter
      position
    end
    wrapped_status = lambda do |order_id|
      status_counter << :status if status_counter
      order_status_get.call(order_id)
    end
    build_service(
      venue: venue,
      signer_post: ->(_uri, _payload) { { status: "signed", signature: "0xsig" } },
      http_post: ->(_uri, _payload) { { status: "SUBMITTED", id: "eth-open-1" } },
      order_status_get: wrapped_status,
      env_extra: enabled ? { "ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED" => "true" } : {}
    )
  end

  def run_open(service)
    service.open_short(
      position: fake_position(execution_venue: "extended"),
      size_eth: "1.0",
      current_position: nil,
      confirmation: nil,
      max_slippage: "0.01",
      require_confirmation: false,
      migration: true
    )
  end

  test "target open confirms via fast order fill before slow position polling" do
    reads = []
    filled = ->(_id) { { status: "FILLED", filled_eth: "1.0", remaining_eth: "0", reduce_only: false } }
    # Position endpoint still lags (flat); the non-reduce-only order fill is authoritative.
    service = open_fill_service(order_status_get: filled, position: nil, read_counter: reads)

    result = run_open(service)

    assert_equal "submitted_and_confirmed", result.status
    assert_equal "ethereal_order_list_open_fill", result.receipt.fetch(:readback_poll_attempts).first.fetch(:source)
    assert_operator reads.size, :<=, 1, "should not fall back to the 12-attempt position poll"
    ofc = result.receipt.fetch(:open_fill_confirmation)
    assert_equal true, ofc[:confirmed]
    assert_equal "ethereal_order_list_open_fill", ofc[:source]
    assert_equal false, ofc[:reduce_only]
    assert_equal "1.0", ofc[:open_size_eth]
    assert ofc[:confirmed_at].present?
  end

  test "partial target open never confirms via fast fill" do
    partial = ->(_id) { { status: "PARTIALLY_FILLED", filled_eth: "0.5", remaining_eth: "0.5", reduce_only: false } }
    # Position lags (flat) so the fallback poll also cannot confirm -> pending, never confirmed on a partial.
    service = open_fill_service(order_status_get: partial, position: nil)

    result = run_open(service)

    assert_equal "submitted_but_readback_pending", result.status
    assert result.receipt.fetch(:readback_poll_attempts).none? { |a| a[:classification] == "filled" }
  end

  test "reduce-only order fill is ignored for a target open and falls back to position readback" do
    reads = []
    reduce_only = ->(_id) { { status: "FILLED", filled_eth: "1.0", remaining_eth: "0", reduce_only: true } }
    service = open_fill_service(order_status_get: reduce_only, position: ethereal_short("1.0"), read_counter: reads)

    result = run_open(service)

    assert_equal "submitted_and_confirmed", result.status
    assert_operator reads.size, :>=, 1, "must confirm via position readback, not a reduce-only fill on an open"
  end

  test "target open falls back fail-closed to position readback when order fill is unavailable" do
    reads = []
    unavailable = ->(_id) { nil }
    service = open_fill_service(order_status_get: unavailable, position: ethereal_short("1.0"), read_counter: reads)

    result = run_open(service)

    assert_equal "submitted_and_confirmed", result.status
    assert_operator reads.size, :>=, 1
  end

  test "target open fast fill confirmation is disabled by default and does not query order status" do
    status_calls = []
    filled = ->(_id) { { status: "FILLED", filled_eth: "1.0", remaining_eth: "0", reduce_only: false } }
    service = open_fill_service(order_status_get: filled, position: nil, enabled: false, status_counter: status_calls)

    result = run_open(service)

    assert_equal "submitted_but_readback_pending", result.status
    assert_empty status_calls, "order status must not be queried when the feature is disabled"
  end

  test "classify_open_fill confirms a terminal filled non-reduce-only open" do
    service = build_service
    order = real_ethereal_filled_close_order.merge("reduceOnly" => false, "close" => false)
    status = service.send(:normalize_ethereal_order, order)

    assert_equal false, status[:reduce_only]
    assert_equal :filled, service.send(:classify_open_fill, status, open_size: BigDecimal("1.702"))
    # A reduce-only order is never an authoritative OPEN confirmation.
    reduce_status = service.send(:normalize_ethereal_order, real_ethereal_filled_close_order)
    assert_equal :unknown, service.send(:classify_open_fill, reduce_status, open_size: BigDecimal("1.702"))
  end

  private

  def build_service(venue: FakeVenue.new(position: nil), signer_post: nil, http_post: nil, http_get: nil, order_status_get: nil, env_extra: {})
    EtherealHedgeExecutionService.new(
      order_status_get: order_status_get,
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
