require "test_helper"

class ExtendedMainnetLifecycleCheckTest < ActiveSupport::TestCase
  FakeHedge = Struct.new(:target, keyword_init: true) do
    def id = 7
    def extended_execution? = true
  end
  FakePosition = Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
    def active? = true
    def mellow_autopilot? = true
    def hedge_ready? = true
    def mellow_weth_exposure = BigDecimal("0.5")
  end

  test "live mode refuses without probe gate and confirmation" do
    result = build_service.run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: "wrong",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_MAINNET_PROBE_ENABLED must be true"
    assert_includes result.blockers, "EXTENDED_LIVE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedMainnetLifecycleCheck::CONFIRMATION}"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_no_match(/api-secret|stark-private|authorization|cookie/i, result.receipt.to_json)
  end

  test "missing confirmation blocks before signer or submit" do
    signer = CountingSigner.new(ok: true)
    api_client = live_api_client
    result = build_service(
      env: live_env,
      api_client: api_client,
      signer_client: signer
    ).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: "wrong",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedMainnetLifecycleCheck::CONFIRMATION}"
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "live mode refuses without signer health even when gates are present" do
    signer = Struct.new(:health, keyword_init: true) do
      def supports_extended_order_signing? = false
    end.new(health: { ok: false, reason: "disabled" })
    service = build_service(
      env: extended_env.merge(
        "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
        "EXTENDED_LIVE_ENABLED" => "true",
        "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid",
        "EXTENDED_REQUIRED_LEVERAGE" => "1",
        "EXTENDED_REQUIRED_MARGIN_MODE" => "isolated",
        "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true"
      ),
      signer_client: signer,
      api_client: live_api_client
    )

    result = service.run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_includes result.blockers, "Extended Stark signer verified_algorithm=false"
  end

  test "live mode refuses when signer algorithm is unverified" do
    result = build_service(env: live_env, api_client: live_api_client, signer_client: CountingSigner.new(ok: false, verified_algorithm: false, signing_enabled: true)).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended Stark signer verified_algorithm=false"
  end

  test "live mode refuses when signer signing is disabled" do
    result = build_service(env: live_env, api_client: live_api_client, signer_client: CountingSigner.new(ok: false, verified_algorithm: true, signing_enabled: false)).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended Stark signer signing_enabled=false"
  end

  test "live mode refuses below min size before any signing or submit" do
    result = build_service(api_client: min_size_api_client).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.005",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    summary = result.receipt.fetch(:order_payload_summaries).first
    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "requested size 0.005 is below Extended min order size 0.01"
    assert_equal false, summary.fetch(:size_valid)
    assert_equal "0.01", summary.fetch(:min_size)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live open blocks when Extended leverage is unknown before signer or submit" do
    api_client = live_api_client(leverage_payload: { "error" => "unsupported" })
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended current leverage is unknown; refusing live submit."
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "live open blocks when Extended leverage is 10x before signer or submit" do
    api_client = live_api_client(leverage_payload: { "data" => [ { "market" => "ETH-USD", "leverage" => "10" } ] })
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended current leverage 10.0 does not match required 1.0x. Run extended:set_leverage dry_run=true."
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "live close blocks when Extended margin mode is cross before signer or submit" do
    api_client = live_api_client(
      before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", leverage: "1", marginMode: "cross", status: "OPEN" } ],
      leverage_payload: { "data" => [ { "market" => "ETH-USD", "leverage" => "1", "marginMode" => "cross" } ] }
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env.merge("EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "false"), api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended current margin mode is cross; required isolated or isolated-equivalent."
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "live open passes margin gate when leverage is 1 and isolated account is confirmed" do
    api_client = live_api_client(after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ])
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_not_includes result.blockers, "Extended current leverage is unknown; refusing live submit."
    assert_equal "pass", result.receipt.dig(:read_only_account_diagnostics, :margin_gate_status)
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
  end

  test "dry run builds lifecycle payloads and submits nothing" do
    result = build_service(api_client: live_api_client).run(
      position: fake_position,
      mode: "delta_round_trip",
      size_eth: "0.01",
      confirmation: nil,
      dry_run: true
    )

    summaries = result.receipt.fetch(:order_payload_summaries)
    assert_equal "dry_run", result.status
    assert_equal [ "open", "decrease", "increase", "close" ], summaries.map { |summary| summary.fetch(:probe_leg) }
    assert_equal [ "sell", "buy", "sell", "buy" ], summaries.map { |summary| summary.fetch(:side) }
    assert_equal [ false, true, false, true ], summaries.map { |summary| summary.fetch(:reduce_only) }
    assert_equal [ "0.02", "0.01", "0.01", "0.02" ], summaries.map { |summary| summary.fetch(:rounded_size_eth) }
    assert_equal "ETH-USD", result.receipt.dig(:market_metadata, :requested_market_symbol)
    assert_equal "env", result.receipt.dig(:market_metadata, :size_increment_source)
    assert_equal "env", result.receipt.dig(:market_metadata, :price_increment_source)
    assert_equal true, result.receipt.dig(:read_only_account_diagnostics, :account_read_attempted)
    assert_equal true, result.receipt.dig(:read_only_account_diagnostics, :positions_read_attempted)
    assert_equal true, result.receipt.dig(:read_only_account_diagnostics, :open_orders_read_attempted)
    assert_equal "1999.79", result.receipt.dig(:read_only_account_diagnostics, :account_value_usd)
    assert_equal "no_position", result.receipt.dig(:read_only_account_diagnostics, :current_position_status)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
    assert_no_match(/api-secret|authorization|cookie/i, result.receipt.to_json)
  end

  test "dry run includes verified signer health and reports signing disabled without algorithm blocker" do
    signer = CountingSigner.new(ok: false, verified_algorithm: true, signing_enabled: false)
    result = build_service(
      env: extended_env.merge("EXTENDED_SIGNER_URL" => "http://extended-signer.invalid"),
      signer_client: signer
    ).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: nil,
      dry_run: true
    )

    payload = result.receipt.fetch(:order_payload_summaries).first
    assert_equal "dry_run", result.status
    assert_equal true, result.receipt.dig(:signer_health, "verified_algorithm")
    assert_equal false, result.receipt.dig(:signer_health, "signing_enabled")
    assert_not_includes result.blockers, "Extended Stark signer verified_algorithm=false"
    assert_includes result.blockers, "Extended Stark signer signing_enabled=false"
    assert_equal "dry_run_no_signature", payload.dig(:signer_request, :status)
    assert_equal "dry_run_no_signature", result.receipt.dig(:signer_request, :status)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  test "close only dry run builds full size buy reduce only order for current short" do
    result = build_service(
      api_client: live_api_client(before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", status: "OPEN" } ])
    ).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.005",
      confirmation: nil,
      dry_run: true
    )

    summary = result.receipt.fetch(:order_payload_summaries).first
    assert_equal "dry_run", result.status
    assert_equal "close_short", summary.fetch(:action)
    assert_equal "buy", summary.fetch(:side)
    assert_equal "BUY", summary.fetch(:extended_side)
    assert_equal true, summary.fetch(:reduce_only)
    assert_equal "0.01", summary.fetch(:rounded_size_eth)
    assert_equal "2141.2", summary.fetch(:crossing_price)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  test "close only blocks when no current Extended short exists" do
    result = build_service(api_client: live_api_client).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.01",
      confirmation: nil,
      dry_run: true
    )

    assert_equal "dry_run", result.status
    assert_includes result.blockers, "close_only probe requires current Extended short position"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live close only refuses without probe gates and confirmation" do
    signer = CountingSigner.new(ok: true)
    api_client = live_api_client(before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", status: "OPEN" } ])
    result = build_service(api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.01",
      confirmation: "wrong",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_MAINNET_PROBE_ENABLED must be true"
    assert_includes result.blockers, "EXTENDED_LIVE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedMainnetLifecycleCheck::CONFIRMATION}"
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "dry run records unreachable signer health as blocker" do
    signer = Struct.new(:health, keyword_init: true).new(
      health: {
        ok: false,
        reason: "Errno::ECONNREFUSED: Connection refused",
        verified_algorithm: false,
        signing_enabled: false,
        supported_exchanges: [],
        supported_actions: []
      }.with_indifferent_access
    )
    result = build_service(
      env: extended_env.merge("EXTENDED_SIGNER_URL" => "http://extended-signer.invalid"),
      signer_client: signer
    ).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: nil,
      dry_run: true
    )

    assert_equal "dry_run", result.status
    assert_equal "Errno::ECONNREFUSED: Connection refused", result.receipt.dig(:signer_health, "reason")
    assert_includes result.blockers, "Extended signer unhealthy: Errno::ECONNREFUSED: Connection refused"
    assert_includes result.blockers, "Extended Stark signer verified_algorithm=false"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live open submits exactly one order and requires readback confirmation" do
    api_client = live_api_client(after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ])
    signer = CountingSigner.new(ok: true)
    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal true, result.receipt.fetch(:submitted)
    assert_equal "SELL", api_client.submitted_payload.fetch("side")
    assert_equal false, api_client.submitted_payload.fetch("reduceOnly")
    assert_equal "MARKET", api_client.submitted_payload.fetch("type")
    assert_equal "IOC", api_client.submitted_payload.fetch("timeInForce")
    assert_equal "2098.8", api_client.submitted_payload.fetch("price")
    assert_equal "abc123", result.receipt.fetch(:exchange_order_id)
    assert_no_match(/0xsignature|api-secret/i, result.receipt.to_json)
  end

  test "dashboard live open uses full server target size without probe cap" do
    api_client = live_api_client(
      account_value: "8000",
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "2.268371052741099", value: "4809.74623129113", openPrice: "2120", markPrice: "2120", status: "OPEN" } ]
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => "0.01"), api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "2.268371052741099",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      size_source: "dashboard_server_target"
    )

    assert_equal "success", result.status
    assert_equal "2.268371052741099", result.receipt.fetch(:requested_size_eth)
    assert_equal "2.268", result.receipt.fetch(:submitted_size_eth)
    assert_equal "2.268", result.receipt.fetch(:quantity_sent_to_extended)
    assert_equal "2.268", api_client.submitted_payload.fetch("qty")
    assert_not_equal "0.01", api_client.submitted_payload.fetch("qty")
    assert_equal "dashboard_server_target", result.receipt.fetch(:size_source)
    assert_equal false, result.receipt.fetch(:partial)
  end

  test "missing dashboard size fails closed before signing or submit" do
    api_client = live_api_client(account_value: "8000")
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "open_only",
      size_eth: nil,
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      size_source: "dashboard_server_target"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended live open size could not be computed; refusing to default to probe/min size."
    assert_equal 0, signer.sign_calls
    assert_equal 0, api_client.submit_calls
  end

  test "probe cap remains isolated from dashboard sizing policy" do
    result = build_service(api_client: live_api_client(account_value: "8000")).run(
      position: fake_position,
      mode: "delta_round_trip",
      size_eth: "2.268371052741099",
      confirmation: nil,
      dry_run: true,
      size_source: "probe_cap"
    )

    summaries = result.receipt.fetch(:order_payload_summaries)
    assert_equal "0.02", summaries.first.fetch(:rounded_size_eth)
    assert_equal "2.268371052741099", result.receipt.fetch(:requested_size_eth)
    assert_equal "0.02", result.receipt.fetch(:submitted_size_eth)
    assert_equal true, result.receipt.fetch(:partial)
  end

  test "underfilled dashboard live open is not successful" do
    api_client = live_api_client(
      account_value: "8000",
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ]
    )

    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true), sleeper: ->(_) { }).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "2.27",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      size_source: "dashboard_server_target"
    )

    assert_equal "underfilled", result.status
    assert_equal "2.27", result.receipt.fetch(:requested_size_eth)
    assert_equal "2.27", result.receipt.fetch(:submitted_size_eth)
    assert_equal "2.27", result.receipt.fetch(:expected_after_short_eth)
    assert_equal "0.01", result.receipt.fetch(:readback_short_after_submit)
    assert_equal "-2.26", result.receipt.fetch(:readback_delta_eth)
    assert_equal false, result.receipt.fetch(:inside_tolerance_after_submit)
  end

  test "live open accepted without readback is pending" do
    api_client = live_api_client
    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true), sleeper: ->(_) { }).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "submitted_but_readback_pending", result.status
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "live close only submits one reduce only buy and requires flat readback" do
    api_client = live_api_client(
      before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", status: "OPEN" } ],
      after_positions: []
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.005",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal "BUY", api_client.submitted_payload.fetch("side")
    assert_equal true, api_client.submitted_payload.fetch("reduceOnly")
    assert_equal "0.01", api_client.submitted_payload.fetch("qty")
    assert_equal "2141.2", api_client.submitted_payload.fetch("price")
    assert_equal true, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
    assert_equal "success", result.receipt.fetch(:final_status)
    assert_equal BigDecimal("0"), BigDecimal(result.receipt.fetch(:readback_attempts).last.fetch(:short_size))
    assert_equal "<redacted>", result.receipt.dig(:signer_response, "settlement", "signature")
    assert_equal "<redacted>", result.receipt.dig(:submit_payload, "settlement", "signature")
    assert_no_match(/0xsignature|api-secret/i, result.receipt.to_json)
  end

  test "live receipts redact signatures api keys auth headers and private keys" do
    api_client = live_api_client(
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
      submit_response: {
        "status" => "OK",
        "data" => {
          "id" => "abc123",
          "signature" => "0xechoed-signature",
          "apiKey" => "echoed-api-key",
          "authorization" => "Bearer secret",
          "cookie" => "session=secret",
          "privateKey" => "0xprivate"
        }
      }
    )

    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true)).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_no_match(/0xechoed-signature|echoed-api-key|Bearer secret|session=secret|0xprivate|0xsignature/i, result.receipt.to_json)
    assert_equal "<redacted>", result.receipt.dig(:submit_response, "data", "signature")
    assert_equal "<redacted>", result.receipt.dig(:submit_response, "data", "apiKey")
    assert_equal "<redacted>", result.receipt.dig(:submit_response, "data", "authorization")
    assert_equal "<redacted>", result.receipt.dig(:submit_response, "data", "cookie")
    assert_equal "<redacted>", result.receipt.dig(:submit_response, "data", "privateKey")
  end

  test "live rebalance delta decrease submits one reduce only buy and requires target readback" do
    api_client = live_api_client(
      before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.25", value: "530", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.24", value: "508.8", openPrice: "2120", markPrice: "2120", status: "OPEN" } ]
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "rebalance_delta",
      size_eth: "0.01",
      delta_eth: "-0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
    assert_equal "BUY", api_client.submitted_payload.fetch("side")
    assert_equal true, api_client.submitted_payload.fetch("reduceOnly")
    assert_equal "0.01", api_client.submitted_payload.fetch("qty")
    assert_equal true, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "live rebalance delta increase submits one sell and requires target readback" do
    api_client = live_api_client(
      before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.25", value: "530", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.26", value: "551.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ]
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "rebalance_delta",
      size_eth: "0.01",
      delta_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
    assert_equal "SELL", api_client.submitted_payload.fetch("side")
    assert_equal false, api_client.submitted_payload.fetch("reduceOnly")
    assert_equal "0.01", api_client.submitted_payload.fetch("qty")
    assert_equal true, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "live close only accepted without flat readback is pending" do
    api_client = live_api_client(
      before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", status: "OPEN" } ],
      after_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "20.85", openPrice: "2085", markPrice: "2085", status: "OPEN" } ]
    )

    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true), sleeper: ->(_) { }).run(
      position: fake_position,
      mode: "close_only",
      size_eth: "0.005",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "submitted_but_readback_pending", result.status
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "live delta round trip opens reduces increases and closes with readback confirmation per leg" do
    api_client = sequence_api_client(
      states: [
        [],
        [ { market: "ETH-USD", side: "SHORT", size: "0.02", value: "42.4", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
        [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
        [ { market: "ETH-USD", side: "SHORT", size: "0.02", value: "42.4", openPrice: "2120", markPrice: "2120", status: "OPEN" } ],
        []
      ]
    )
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer).run(
      position: fake_position,
      mode: "delta_round_trip",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "success", result.status
    assert_equal 4, signer.sign_calls
    assert_equal 4, api_client.submit_calls
    assert_equal 4, result.receipt.fetch(:orders_placed)
    assert_equal 4, result.receipt.fetch(:signatures_created)
    assert_equal [ "SELL", "BUY", "SELL", "BUY" ], api_client.submitted_payloads.map { |payload| payload.fetch("side") }
    assert_equal [ false, true, false, true ], api_client.submitted_payloads.map { |payload| payload.fetch("reduceOnly") }
    assert_equal [ "0.02", "0.01", "0.01", "0.02" ], api_client.submitted_payloads.map { |payload| payload.fetch("qty") }
    assert_equal [ "open", "decrease", "increase", "close" ], result.receipt.fetch(:leg_summaries).map { |leg| leg.fetch(:leg) }
    assert_equal true, result.receipt.fetch(:readback_attempts).all? { |attempt| attempt.fetch(:confirmed) }
    assert_no_match(/0xsignature|api-secret/i, result.receipt.to_json)
  end

  test "live delta round trip stops immediately when a leg readback fails" do
    api_client = sequence_api_client(states: [ [], [] ])
    signer = CountingSigner.new(ok: true)

    result = build_service(env: live_env, api_client: api_client, signer_client: signer, sleeper: ->(_) { }).run(
      position: fake_position,
      mode: "delta_round_trip",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "submitted_but_readback_pending", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, api_client.submit_calls
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal [ "open" ], result.receipt.fetch(:leg_summaries).map { |leg| leg.fetch(:leg) }
  end

  test "live open blocks when current position exists" do
    api_client = live_api_client(before_positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01" } ])
    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true)).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "open_only live probe requires no current Extended position"
    assert_equal 0, api_client.submit_calls
  end

  test "live open blocks when open orders exist" do
    api_client = live_api_client(open_orders: [ { id: 1, market: "ETH-USD" } ])
    result = build_service(env: live_env, api_client: api_client, signer_client: CountingSigner.new(ok: true)).run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.01",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "open_only live probe requires open_orders_count=0"
    assert_equal 0, api_client.submit_calls
  end

  private

  CountingSigner = Struct.new(:ok, :verified_algorithm, :signing_enabled, :sign_calls, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ ok: true, verified_algorithm: true, signing_enabled: true, sign_calls: 0 }.merge(kwargs))
    end

    def health
      {
        ok: ok,
        reason: ok ? "ok" : "disabled",
        supported_exchanges: ok ? [ "Extended" ] : [],
        supported_actions: ok ? [ "sign_extended_order" ] : [],
        verified_algorithm: verified_algorithm,
        signing_enabled: signing_enabled,
        stark_public_key: "0x1234...abcd"
      }.with_indifferent_access
    end

    def supports_extended_order_signing?
      ok && verified_algorithm && signing_enabled
    end

    def verified_algorithm? = verified_algorithm

    def sign_order(order)
      self.sign_calls += 1
      {
        status: "signed",
        order_id: "signed-order-id",
        settlement: { signature: { r: "0xsignature-r", s: "0xsignature-s" }, starkKey: order.fetch("starkPublicKey"), collateralPosition: order.fetch("vault") },
        debuggingAmounts: { collateralAmount: "21200000", feeAmount: "10600", syntheticAmount: "-10000" }
      }.with_indifferent_access
    end
  end

  def build_service(env: extended_env, signer_client: nil, api_client: fake_api_client, sleeper: ->(_) { })
    venue = HedgeVenues::Extended.new(env: env, api_client: api_client)
    signer_client ||= Struct.new(:health, keyword_init: true) do
      def supports_extended_order_signing? = false
      def verified_algorithm? = false
    end.new(health: { ok: false, reason: "not configured" })
    ExtendedMainnetLifecycleCheck.new(env: env, venue: venue, signer_client: signer_client, sleeper: sleeper)
  end

  def fake_position
    FakePosition.new(id: 3, hedge: FakeHedge.new(target: BigDecimal("1.0")), asset0_price_usd: BigDecimal("2100"))
  end

  def fake_api_client
    Class.new do
      def positions(market:)
        [ { market: market, side: "SHORT", size: "0.25", value: "525", openPrice: "2120", markPrice: "2100", unrealisedPnl: "5", status: "OPEN" } ]
      end

      def balance = { equity: "5000", balance: "5000" }
      def account_info = { status: "ACTIVE", accountId: "acct" }
      def market(market:) = { name: market, active: true }
      def open_orders(market:) = []
    end.new
  end

  def min_size_api_client
    Class.new do
      def positions(market:)
        []
      end

      def balance = { equity: "5000", balance: "5000" }
      def account_info = { status: "ACTIVE", accountId: "acct" }
      def open_orders(market:) = []

      def market(market:)
        {
          data: {
            name: market,
            tradingConfig: {
              minOrderSize: "0.01",
              minOrderSizeChange: "0.001",
              minPriceChange: "0.1"
            },
            marketStats: { markPrice: "2120" }
          }
        }
      end
    end.new
  end

  def live_api_client(before_positions: [], after_positions: [], open_orders: [], submit_response: nil, leverage_payload: nil, account_value: "1999.79")
    Class.new do
      attr_reader :submit_calls, :submitted_payload

      define_method(:initialize) do |before_rows, after_rows, orders, response, leverage_response, value|
        @before_rows = before_rows
        @after_rows = after_rows
        @orders = orders
        @submit_response = response
        @leverage_payload = leverage_response
        @account_value = value
        @submit_calls = 0
      end

      def positions(market:)
        @submit_calls.positive? ? @after_rows : @before_rows
      end

      def balance = { "status" => "OK", "data" => { "equity" => @account_value, "balance" => @account_value } }
      def account_info = { "status" => "ACTIVE", "data" => { "equity" => @account_value, "balance" => @account_value } }
      def open_orders(market:) = @orders
      def leverage(market:) = @leverage_payload || { "data" => [ { "market" => market, "leverage" => "1" } ] }
      def fees(market:) = { "data" => [ { "market" => market, "takerFeeRate" => "0.0005" } ] }

      def market(market:)
        {
          data: {
            name: market,
            tradingConfig: { minOrderSize: "0.01", minOrderSizeChange: "0.001", minPriceChange: "0.1" },
            marketStats: { markPrice: "2120" },
            l2Config: {
              collateralId: "0x31857064564ed0ff978e687456963cba09c2c6985d8f9300a1de4962fafa054",
              syntheticId: "0x4554482d3800000000000000000000",
              collateralResolution: 1000000,
              syntheticResolution: 1000000
            }
          }
        }
      end

      def submit_order(payload)
        @submit_calls += 1
        @submitted_payload = payload
        @submit_response || { "status" => "OK", "data" => { "id" => "abc123" } }
      end
    end.new(before_positions, after_positions, open_orders, submit_response, leverage_payload, account_value)
  end

  def sequence_api_client(states:, open_orders: [], submit_response: nil, leverage_payload: nil)
    Class.new do
      attr_reader :submit_calls, :submitted_payloads

      define_method(:initialize) do |position_states, orders, response, leverage_response|
        @position_states = position_states
        @orders = orders
        @submit_response = response
        @leverage_payload = leverage_response
        @submit_calls = 0
        @submitted_payloads = []
      end

      def positions(market:)
        @position_states.fetch([ @submit_calls, @position_states.size - 1 ].min)
      end

      def balance = { "status" => "OK", "data" => { "equity" => "1999.79", "balance" => "1999.79" } }
      def account_info = { "status" => "ACTIVE", "data" => { "equity" => "1999.79", "balance" => "1999.79" } }
      def open_orders(market:) = @orders
      def leverage(market:) = @leverage_payload || { "data" => [ { "market" => market, "leverage" => "1" } ] }
      def fees(market:) = { "data" => [ { "market" => market, "takerFeeRate" => "0.0005" } ] }

      def market(market:)
        {
          data: {
            name: market,
            tradingConfig: { minOrderSize: "0.01", minOrderSizeChange: "0.001", minPriceChange: "0.1" },
            marketStats: { markPrice: "2120" },
            l2Config: {
              collateralId: "0x31857064564ed0ff978e687456963cba09c2c6985d8f9300a1de4962fafa054",
              syntheticId: "0x4554482d3800000000000000000000",
              collateralResolution: 1000000,
              syntheticResolution: 1000000
            }
          }
        }
      end

      def submit_order(payload)
        @submit_calls += 1
        @submitted_payloads << payload
        @submit_response || { "status" => "OK", "data" => { "id" => "abc#{@submit_calls}" } }
      end
    end.new(states, open_orders, submit_response, leverage_payload)
  end

  def live_env
    extended_env.merge(
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_REQUIRED_LEVERAGE" => "1",
      "EXTENDED_REQUIRED_MARGIN_MODE" => "isolated",
      "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true",
      "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid",
      "EXTENDED_STARK_PUBLIC_KEY" => "0x1234...abcd"
    ).except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT")
  end

  def extended_env
    {
      "EXTENDED_API_BASE_URL" => "https://api.starknet.extended.exchange/api/v1",
      "EXTENDED_API_KEY" => "api-secret",
      "EXTENDED_ACCOUNT_ID" => "acct",
      "EXTENDED_VAULT_NUMBER" => "123",
      "EXTENDED_CLIENT_ID" => "client",
      "EXTENDED_STARK_PUBLIC_KEY" => "0xpublic",
      "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
      "EXTENDED_SIZE_INCREMENT" => "0.0001",
      "EXTENDED_PRICE_INCREMENT" => "0.1"
    }
  end
end
