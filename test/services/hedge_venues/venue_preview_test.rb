require "test_helper"

module HedgeVenues
  class VenuePreviewTest < ActiveSupport::TestCase
    test "hyperliquid is the default venue" do
      assert_equal "hyperliquid", HedgeVenues.normalize(nil)
      assert_instance_of HedgeVenues::Hyperliquid, HedgeVenues.build(nil)
    end

    test "ethereal preview is dry run only and reports missing config blockers" do
      venue = HedgeVenues::Ethereal.new(env: {})
      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.1234"), max_slippage: "0.01")

      assert_equal "Ethereal", preview.fetch(:venue)
      assert_equal "read_only_dry_run", preview.fetch(:mode)
      assert_equal false, preview.fetch(:submit_enabled)
      assert_equal false, preview.fetch(:order_submission)
      assert_equal "ethereal_eip712_trade_order_preview", preview.fetch(:payload).fetch(:schema)
      assert_includes preview.fetch(:blockers), "Dry-run/read-only only; live submit not enabled for Ethereal."
      assert_includes preview.fetch(:blockers), "ETHEREAL_READ_ONLY_ENABLED is not true"
      assert_includes preview.fetch(:blockers), "ETHEREAL_API_BASE_URL is required for Ethereal read-only account/position checks"
      assert_includes preview.fetch(:blockers), "ETHEREAL_SUBACCOUNT_ID is required for Ethereal position readback"
    end

    test "ethereal account state normalizes account health object to dashboard hash" do
      env = {
        "ETHEREAL_READ_ONLY_ENABLED" => "true",
        "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
        "ETHEREAL_SUBACCOUNT_ID" => "raw-subaccount"
      }
      account_health = HedgeBackends::AccountHealth.new(
        backend: "ethereal",
        account: "raw-account",
        subaccount: "raw-subaccount",
        collateral: "USD",
        account_value_usd: "100.25",
        withdrawable_usd: "80.5",
        margin_used_usd: "19.75",
        status: "ok"
      )
      probe = Object.new
      probe.define_singleton_method(:account_health) { account_health }
      venue = HedgeVenues::Ethereal.new(env: env, probe: probe)

      state = venue.account_state

      assert_equal Hash, state.class
      assert_equal "Ethereal", state.fetch(:venue)
      assert_equal "read_only_dry_run", state.fetch(:mode)
      assert_equal false, state.fetch(:live_supported)
      assert_equal false, state.fetch(:live_enabled)
      assert_equal "ok", state.fetch(:status)
      assert_equal "USD", state.fetch(:collateral)
      assert_equal "100.25", state.fetch(:account_value_usd)
      assert_equal "80.5", state.fetch(:withdrawable_usd)
      assert_equal "19.75", state.fetch(:margin_used_usd)
      assert_not state.key?(:account)
      assert_not state.key?(:subaccount)
      assert_not state.key?(:raw)
    end

    test "nado preview is dry run only and rounds size to increment" do
      venue = HedgeVenues::Nado.new(env: { "NADO_SIZE_INCREMENT" => "0.01" })
      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.1234"), max_slippage: "0.01")

      assert_equal "Nado", preview.fetch(:venue)
      assert_equal false, preview.fetch(:submit_enabled)
      assert_equal "0.12", preview.fetch(:rounded_size_eth)
      assert_equal "nado_eip712_order_preview", preview.fetch(:payload).fetch(:schema)
      assert_equal "0.01", preview.fetch(:payload).fetch(:size_increment)
      assert_equal "floor_to_size_increment", preview.fetch(:payload).fetch(:size_rounding)
      assert_includes preview.fetch(:blockers), "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit."
      assert_includes preview.fetch(:blockers), "NADO_READ_ONLY_ENABLED is not true"
    end

    test "nado read position uses get only account query when configured" do
      env = {
        "NADO_READ_ONLY_ENABLED" => "true",
        "NADO_GATEWAY_QUERY_BASE_URL" => "https://nado.example/v1",
        "NADO_ACCOUNT_SUBACCOUNT" => "0xsubaccount"
      }
      calls = []
      http_get = ->(uri) {
        calls << uri
        {
          data: {
            perp_products: [ { product_id: "1", symbol: "ETH-PERP" } ],
            perp_balances: [
              { product_id: "1", balance: { amount: "-120000000000000000" }, mark_price: "2300" }
            ]
          }
        }.to_json
      }
      venue = HedgeVenues::Nado.new(env: env, http_get: http_get)

      position = venue.read_position(symbol: "ETH")

      assert_equal "ETH-PERP", position.fetch(:symbol)
      assert_equal BigDecimal("0.12"), position.fetch(:short_size)
      assert_equal 1, calls.size
      assert_equal "/v1/query", calls.first.path
      assert_equal "type=subaccount_info&subaccount=0xsubaccount", calls.first.query
    end

    test "nado read position parses cross margin ETH-PERP short from subaccount info" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env, http_get: ->(_uri) { nado_cross_margin_response(amount: "-955000000000000000").to_json })

      eth = venue.read_position(symbol: "ETH")
      perp = venue.read_position(symbol: "ETH-PERP")
      state = venue.account_state

      assert_equal eth, perp
      assert_equal "ETH-PERP", eth.fetch(:symbol)
      assert_equal 4, eth.fetch(:product_id)
      assert_equal "short", eth.fetch(:side)
      assert_equal BigDecimal("0.955"), eth.fetch(:short_size)
      assert_equal "cross", eth.fetch(:margin_mode)
      assert_equal BigDecimal("2061"), eth.fetch(:entry_price)
      assert_includes state.fetch(:warnings), "Current Nado hedge is cross-margin; target mode is isolated 1x. Close and reopen isolated after confirmation."
      assert_equal 1, state.fetch(:raw_positions_count)
      assert_equal 1, state.fetch(:raw_position_like_count)
      assert_equal 0, state.fetch(:unresolved_position_like_count)
      assert_equal 1, state.fetch(:normalized_positions_count)
      assert_equal "0.955", state.fetch(:current_short_eth)
      assert_equal "short", state.fetch(:current_side)
    end

    test "nado read position parses isolated ETH-PERP short margin mode" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env, http_get: ->(uri) {
        if uri.query.include?("isolated_positions")
          {
            data: {
              isolated_positions: [
                {
                  base_product: { product_id: 4, symbol: "ETH-PERP", risk: { price_x18: "2061000000000000000000" } },
                  base_balance: { balance: { amount: "-955000000000000000", v_quote_balance: "1968255000000000000000" } },
                  quote_balance: { balance: { amount: "1968255000000000000000" } }
                }
              ]
            }
          }.to_json
        else
          { data: { perp_products: [ { product_id: 4, symbol: "ETH-PERP" } ], perp_balances: [] } }.to_json
        end
      })

      position = venue.read_position(symbol: "ETH")

      assert_equal "isolated", position.fetch(:margin_mode)
      assert_equal "short", position.fetch(:side)
      assert_equal BigDecimal("0.955"), position.fetch(:short_size)
      assert_equal BigDecimal("2061"), position.fetch(:entry_price)
      assert_equal BigDecimal("2061"), position.fetch(:mark_price)
      assert_equal BigDecimal("1968.255"), position.fetch(:isolated_margin_usd)
    end

    test "nado isolated ETH-PERP readback leaves entry price nil without v quote balance" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env, http_get: ->(uri) {
        if uri.query.include?("isolated_positions")
          {
            data: {
              isolated_positions: [
                {
                  base_product: { product_id: 4, symbol: "ETH-PERP", risk: { price_x18: "2061000000000000000000" } },
                  base_balance: { balance: { amount: "-955000000000000000" } },
                  quote_balance: { balance: { amount: "1968255000000000000000" } }
                }
              ]
            }
          }.to_json
        else
          { data: { perp_products: [ { product_id: 4, symbol: "ETH-PERP" } ], perp_balances: [] } }.to_json
        end
      })

      position = venue.read_position(symbol: "ETH")

      assert_equal "isolated", position.fetch(:margin_mode)
      assert_equal BigDecimal("0.955"), position.fetch(:short_size)
      assert_nil position.fetch(:entry_price)
      assert_equal BigDecimal("2061"), position.fetch(:mark_price)
    end

    test "nado read position ignores spot collateral only rows" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env, http_get: ->(_uri) {
        {
          data: {
            spot_products: [ { product_id: 9, symbol: "USDC" } ],
            spot_balances: [ { product_id: 9, balance: { amount: "1000000000000000000000" } } ]
          }
        }.to_json
      })

      assert_nil venue.read_position(symbol: "ETH")
      assert_equal 0, venue.account_state.fetch(:raw_positions_count)
    end

    test "nado product slots and zero ETH-PERP balances do not block flat account" do
      rows = Array.new(58) { |index| { product_id: index + 1, balance: { amount: "0" } } }
      venue = HedgeVenues::Nado.new(env: nado_readonly_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true"), http_get: ->(_uri) {
        {
          data: {
            perp_products: rows.map { |row| { product_id: row[:product_id], symbol: row[:product_id] == 4 ? "ETH-PERP" : "PERP-#{row[:product_id]}" } },
            perp_balances: rows
          }
        }.to_json
      })

      assert_nil venue.read_position(symbol: "ETH")
      state = venue.account_state
      assert_equal 58, state.fetch(:raw_slots_count)
      assert_equal 58, state.fetch(:raw_products_count)
      assert_equal 0, state.fetch(:raw_positions_count)
      assert_equal 0, state.fetch(:raw_position_like_count)
      assert_equal 0, state.fetch(:unresolved_position_like_count)
      assert_equal 0, state.fetch(:normalized_positions_count)
      assert_not_includes state.fetch(:blockers), "Nado raw positions are present but parser could not normalize ETH-PERP; refusing to submit another order."
      assert_not_includes state.fetch(:warnings), "Nado raw positions are present but no ETH-PERP position was normalized."
    end

    test "nado read position classifies ETH-PERP long as conflicting long" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env, http_get: ->(_uri) { nado_cross_margin_response(amount: "955000000000000000").to_json })

      position = venue.read_position(symbol: "ETH")

      assert_equal "long", position.fetch(:side)
      assert_equal BigDecimal("0"), position.fetch(:short_size)
      assert_equal BigDecimal("0.955"), position.fetch(:size)
    end

    test "nado account state warns and blocks when raw positions cannot be normalized" do
      venue = HedgeVenues::Nado.new(env: nado_readonly_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true"), http_get: ->(_uri) {
        {
          data: {
            positions: [ { balance: { amount: "1000000000000000000" } } ],
            perp_products: []
          }
        }.to_json
      })

      assert_nil venue.read_position(symbol: "ETH")
      state = venue.account_state
      assert_equal 1, state.fetch(:raw_positions_count)
      assert_equal 1, state.fetch(:raw_position_like_count)
      assert_equal 1, state.fetch(:unresolved_position_like_count)
      assert_equal 0, state.fetch(:normalized_positions_count)
      assert_includes state.fetch(:warnings), "Nado raw positions are present but no ETH-PERP position was normalized."
      assert_includes state.fetch(:blockers), "Nado raw positions are present but parser could not normalize ETH-PERP; refusing to submit another order."
    end

    test "nado single venue preflight blocks when reduce only close path is unavailable" do
      venue = HedgeVenues::Nado.new(
        env: {
          "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
          "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO",
          "AERODROME_HEDGE_ENABLED" => "true",
          "AERODROME_HEDGE_PAUSED" => "false"
        },
        close_reduce_only_available: false
      )
      position = mellow_position

      preflight = venue.single_venue_preflight(
        position: position,
        action: "open",
        target_size_eth: BigDecimal("1.09"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_includes preflight.fetch(:blockers), "close/reduce-only path is unavailable"
      assert_equal false, preflight.fetch(:submitted)
      assert_equal "1.09", preflight.fetch(:target_hedge_size_eth)
    end

    test "ethereal single venue preflight blocks conflicting venue readback" do
      venue = HedgeVenues::Ethereal.new(
        env: {
          "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
          "AERODROME_ETHEREAL_HEDGE_CONFIRMATION" => "CONFIRM_ETHEREAL",
          "AERODROME_HEDGE_ENABLED" => "true",
          "AERODROME_HEDGE_PAUSED" => "false"
        }
      )
      position = mellow_position

      preflight = venue.single_venue_preflight(
        position: position,
        action: "open",
        target_size_eth: BigDecimal("1.09"),
        current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" },
        confirmation: "CONFIRM_ETHEREAL",
        max_slippage: "0.01"
      )

      assert_includes preflight.fetch(:blockers), HedgeVenues::SingleVenuePreflight::CONFLICTING_POSITION_BLOCKER
      assert_equal "sell_short", preflight.fetch(:intended_side)
    end

    test "nado live service blocks when signer is unavailable" do
      service = NadoHedgeExecutionService.new(env: nado_live_env.except("EXECUTION_SIGNER_URL"))
      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1.09"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "Nado signer service is not configured"
    end

    test "nado live service blocks open when venue readback has existing position" do
      service = NadoHedgeExecutionService.new(env: nado_live_env, signer_post: ->(*) { raise "signer should not be called" })

      preflight = service.preflight(
        position: mellow_position,
        action: "open",
        size_eth: BigDecimal("1.09"),
        current_position: { size: BigDecimal("0.2"), symbol: "ETH-PERP" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_includes preflight.fetch(:blockers), "current Nado position already exists; use close/readback before opening"
    end

    test "nado live open submits single signed short with rounded size" do
      submitted = []
      fixed_now = Time.utc(2026, 5, 23, 12, 0, 0)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"cd" * 32}" } ] }
        },
        now: -> { fixed_now }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1.0934"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "submitted_but_readback_pending", result.status
      assert submitted.first.key?(:place_orders)
      assert_not submitted.first.key?(:place_order)
      assert_nil submitted.first.fetch(:place_orders).fetch(:stop_on_failure)
      assert_equal 1, submitted.first.fetch(:place_orders).fetch(:orders).size
      row = submitted.first.fetch(:place_orders).fetch(:orders).first
      order = row.fetch(:order)
      assert_equal 4, row.fetch(:product_id)
      assert_equal "-1093000000000000000", order.fetch(:amount)
      assert_equal (fixed_now.to_i + NadoHedgeExecutionService::DEFAULT_ORDER_TTL_SECONDS).to_s, order.fetch(:expiration)
      assert_equal ((fixed_now.to_f * 1000).to_i + 5000), order.fetch(:nonce).to_i >> 20
      appendix = order.fetch(:appendix).to_i
      assert_equal true, (appendix & (1 << 8)).positive?
      assert_equal true, (appendix & (1 << 9)).positive?
      decoded = result.receipt.fetch(:submitted_order_summary).fetch(:appendix_decoded)
      assert_equal true, decoded.fetch(:isolated)
      assert_equal "ioc", decoded.fetch(:order_type)
      assert_equal "1.0", result.receipt.fetch(:submitted_order_summary).fetch(:requested_leverage)
      assert_equal "isolated", result.receipt.fetch(:submitted_order_summary).fetch(:margin_mode)
      assert_equal result.receipt.fetch(:submitted_order_summary).fetch(:estimated_notional_usd), result.receipt.fetch(:submitted_order_summary).fetch(:isolated_margin_usd)
      assert_equal "0x#{"ab" * 65}", row.fetch(:signature)
      assert_equal "1.093", result.receipt.fetch(:rounded_size_eth)
      assert_equal "execute_place_orders_batch", result.receipt.fetch(:submitted_order_summary).fetch(:body_shape)
      diagnostics = result.receipt.fetch(:submitted_order_summary).fetch(:recv_time_diagnostics)
      assert_equal 5.0, diagnostics.fetch(:seconds_until_recv_time)
      assert_equal order.fetch(:expiration).to_i, diagnostics.fetch(:order_expiration)
      assert_equal "0x#{"cd" * 32}", result.receipt.fetch(:exchange_order_id)
      assert_equal "submitted", result.receipt.fetch(:submit_response_classification).fetch(:status)
      assert_equal "<redacted>", result.receipt.fetch(:submitted_order_summary).fetch(:signature)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
    end

    test "nado live open blocks when isolated margin mode cannot be built" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_MARGIN_MODE" => "cross"),
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "Nado margin mode must be isolated for live open/increase; refusing cross-margin submit."
    end

    test "nado live rebalance increase blocks existing cross margin short" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("0.1"),
        current_position: { size: BigDecimal("-0.955"), symbol: "ETH-PERP", side: "short", margin_mode: "cross" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "Existing Nado position is cross-margin but desired mode is isolated; close existing position before reopening."
    end

    test "nado live close allows existing cross margin short with reduce only buy" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ef" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.955"),
        current_position: { size: BigDecimal("-0.955"), symbol: "ETH-PERP", side: "short", margin_mode: "cross" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "buy", result.receipt.fetch(:submitted_order_summary).fetch(:side)
      assert_equal true, result.receipt.fetch(:submitted_order_summary).fetch(:reduce_only)
      assert_equal false, result.receipt.fetch(:submitted_order_summary).fetch(:isolated)
      assert_equal "955000000000000000", order.fetch(:amount)
    end

    test "nado live rebalance decrease isolated short uses isolated reduce only appendix" do
      submitted = []
      signer_payloads = []
      isolated_sender = "0x#{"02" * 32}"
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, payload) {
          signer_payloads << payload
          { status: "signed", signature: "0x#{"78" * 65}" }
        },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        }
      )

      service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
        current_position: {
          size: BigDecimal("-0.936"),
          short_size: BigDecimal("0.936"),
          symbol: "ETH-PERP",
          side: "short",
          margin_mode: "isolated",
          isolated_margin_usd: BigDecimal("1909"),
          metadata: { raw: { "subaccount" => isolated_sender } }
        },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      summary = signer_payloads.first.fetch(:payload_preview)
      decoded = summary.fetch(:appendix_decoded)
      assert_equal nado_live_env.fetch("NADO_ACCOUNT_SUBACCOUNT"), order.fetch(:sender)
      assert_equal isolated_sender, summary.fetch(:current_position_subaccount)
      assert_equal "91000000000000000", order.fetch(:amount)
      assert_equal "buy", summary.fetch(:side)
      assert_equal true, summary.fetch(:reduce_only)
      assert_equal "isolated_reduce_only", summary.fetch(:margin_mode)
      assert_equal "1909.0", summary.fetch(:isolated_margin_usd)
      assert_equal 1_909_000_000, summary.fetch(:isolated_margin_x6)
      assert_equal true, decoded.fetch(:isolated)
      assert_equal true, decoded.fetch(:reduce_only)
      assert_equal "ioc", decoded.fetch(:order_type)
    end

    test "nado live close isolated short uses isolated reduce only appendix" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ef" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        }
      )

      service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.936"),
        current_position: {
          size: BigDecimal("-0.936"),
          short_size: BigDecimal("0.936"),
          symbol: "ETH-PERP",
          side: "short",
          margin_mode: "isolated",
          isolated_margin_usd: BigDecimal("1909")
        },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      appendix = order.fetch(:appendix).to_i
      assert_equal "936000000000000000", order.fetch(:amount)
      assert_equal true, (appendix & (1 << 8)).positive?
      assert_equal true, (appendix & (1 << 11)).positive?
      assert_equal 1_909_000_000, appendix >> 64
    end

    test "nado isolated reduce only blocks when isolated margin readback is missing" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "Nado isolated reduce-only close requires isolated margin readback."
    end

    test "nado accepted submit polls until readback confirms short" do
      venue = NadoPollingVenue.new([ nil, { size: BigDecimal("-0.955"), short_size: BigDecimal("0.955"), symbol: "ETH-PERP", side: "short" } ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, _payload) { { status: "success", data: [ { digest: "0x#{"cd" * 32}" } ] } },
        sleeper: ->(_seconds) { }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("0.955"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "submitted_and_confirmed", result.status
      assert_equal "0x#{"cd" * 32}", result.receipt.fetch(:exchange_order_id)
      assert_equal 2, result.receipt.fetch(:post_submit_readback_poll_attempts).size
      assert_equal BigDecimal("0.955"), result.receipt.fetch(:post_submit_readback).fetch(:short_size)
    end

    test "nado accepted submit with nil readback remains unconfirmed" do
      venue = NadoPollingVenue.new([ nil, nil, nil ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, _payload) { { status: "success", data: [ { digest: "0x#{"cd" * 32}" } ] } },
        sleeper: ->(_seconds) { }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("0.955"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "submitted_but_readback_pending", result.status
      assert_equal "Nado submit accepted but readback did not confirm ETH-PERP position.", result.receipt.fetch(:final_message)
      assert_equal 3, result.receipt.fetch(:post_submit_readback_poll_attempts).size
      assert_nil result.receipt.fetch(:post_submit_readback)
      assert_no_match(/#{'ab' * 20}|private_key|authorization|cookie/i, result.receipt.to_json)
    end

    test "nado live submit recv_time rejection records useful sanitized response message" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) {
          {
            status: "failure",
            data: [ { error_code: 2012, error: "Request received more than 100 seconds before the 'recv_time'." } ],
            request_type: "execute_place_orders"
          }
        }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1.0934"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", classification.fetch(:status)
      assert_match "error_code=2012", classification.fetch(:message)
      assert_match "more than 100 seconds", classification.fetch(:message)
      assert_nil result.receipt.fetch(:exchange_order_id)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
    end

    test "nado reduce only increases position rejection records exchange reason" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) {
          {
            status: "failure",
            data: [ { error_code: 400, error: "Reduce only order increases position." } ],
            request_type: "execute_place_orders"
          }
        }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated", isolated_margin_usd: BigDecimal("1909") },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", classification.fetch(:status)
      assert_match "Reduce only order increases position", classification.fetch(:message)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
    end

    test "nado isolated subaccount sender rejection records exchange reason" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) {
          {
            status: "failure",
            data: [ { error_code: 2081, error: "An isolated subaccount cannot place order." } ],
            request_type: "execute_place_orders"
          }
        }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated", isolated_margin_usd: BigDecimal("1909") },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", classification.fetch(:status)
      assert_match "error_code=2081", classification.fetch(:message)
      assert_match "isolated subaccount cannot place order", classification.fetch(:message)
      assert_equal nado_live_env.fetch("NADO_ACCOUNT_SUBACCOUNT"), result.receipt.fetch(:submitted_order_summary).fetch(:sender)
    end


    test "nado live submit http error surfaces endpoint failure" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) { raise "POST /execute failed with HTTP 404: not found" }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1.0934"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "http_error", classification.fetch(:status)
      assert_match "POST /execute", classification.fetch(:message)
      assert_match "HTTP 404", classification.fetch(:message)
    end

    test "nado live close submits reduce only buy" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ef" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.5"),
        current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "500000000000000000", order.fetch(:amount)
      assert_equal true, (order.fetch(:appendix).to_i & (1 << 11)).positive?
      assert_equal "submitted_and_confirmed", result.status
    end

    test "nado live rebalance increase sells non reduce only" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"34" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"56" * 32}" } ] }
        }
      )

      service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("0.25"),
        current_position: { size: BigDecimal("-0.75"), symbol: "ETH-PERP", margin_mode: "isolated" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "-250000000000000000", order.fetch(:amount)
      assert_equal false, (order.fetch(:appendix).to_i & (1 << 11)).positive?
    end

    test "nado live rebalance decrease buys reduce only" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"78" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        }
      )

      service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.25"),
        current_position: { size: BigDecimal("-1.25"), symbol: "ETH-PERP" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "250000000000000000", order.fetch(:amount)
      assert_equal true, (order.fetch(:appendix).to_i & (1 << 11)).positive?
      assert_equal false, (order.fetch(:appendix).to_i & (1 << 8)).positive?
    end

    private

    def nado_live_env
      {
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO",
        "NADO_API_BASE_URL" => "https://nado.example/v1",
        "NADO_ACCOUNT_SUBACCOUNT" => "0x#{"01" * 32}",
        "EXECUTION_SIGNER_URL" => "http://127.0.0.1:9123",
        "NADO_ETH_PERP_PRODUCT_METADATA_JSON" => {
          product_id: 4,
          chain_id: 1,
          price_increment_x18: "1000000000000000000",
          size_increment: "1000000000000000",
          market_price: "2300"
        }.to_json
      }
    end

    def nado_readonly_env
      {
        "NADO_READ_ONLY_ENABLED" => "true",
        "NADO_GATEWAY_QUERY_BASE_URL" => "https://nado.example/v1",
        "NADO_ACCOUNT_SUBACCOUNT" => "0xsubaccount"
      }
    end

    def nado_cross_margin_response(amount:)
      {
        data: {
          perp_products: [
            {
              product_id: 4,
              symbol: "ETH-PERP",
              risk: { price_x18: "2061000000000000000000" }
            }
          ],
          perp_balances: [
            {
              product_id: 4,
              balance: {
                amount: amount,
                v_quote_balance: "1968255000000000000000"
              }
            }
          ]
        }
      }
    end

    class NadoPollingVenue
      def initialize(readbacks, env:)
        @readbacks = readbacks
        @env = env
      end

      def live_flag_enabled?
        @env["AERODROME_NADO_HEDGE_LIVE_ENABLED"] == "true"
      end

      def live_confirmation_phrase
        @env["AERODROME_NADO_HEDGE_CONFIRMATION"].to_s
      end

      def live_mode_state
        "live_ready"
      end

      def live_enabled?
        live_flag_enabled?
      end

      def read_position(symbol:)
        @readbacks.shift
      end

      def raw_positions_present_but_unnormalized?
        false
      end
    end

    def mellow_position
      dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
      wallet = Wallet.find_or_create_by!(
        user: users(:one),
        network: networks(:base),
        address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
      )
      Position.create!(
        user: users(:one),
        dex: dex,
        wallet: wallet,
        source: Position::SOURCE_MELLOW_AUTOPILOT,
        external_id: "mellow:71261528",
        pool_address: "0xb2cc224c1c9fee385f8ad6a55b4d94e92359dc59",
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: "1.09",
        asset1_amount: "240.0",
        asset0_price_usd: "2300.0",
        asset1_price_usd: "1.0",
        entry_value_usd: "2611.0",
        active: true,
        mellow_metadata: {
          hedge_ready: true,
          last_probe_confidence: "high",
          user_weth_exposure: "1.09",
          user_usdc_exposure: "240.0",
          user_total_value_usd: "2611.0"
        }.to_json
      )
    end
  end
end
