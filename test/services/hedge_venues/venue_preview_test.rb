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
      assert_includes preview.fetch(:blockers), "Dry-run/read-only only; live submit not enabled for Nado."
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
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: { digest: "0x#{"cd" * 32}" } }
        }
      )

      result = service.open_short(
        position: mellow_position,
        size_eth: BigDecimal("1.0934"),
        current_position: nil,
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "submitted_but_readback_pending", result.status
      order = submitted.first.fetch(:place_order).fetch(:order)
      assert_equal "-1093000000000000000", order.fetch(:amount)
      assert_equal "0x#{"ab" * 65}", submitted.first.fetch(:place_order).fetch(:signature)
      assert_equal "1.093", result.receipt.fetch(:rounded_size_eth)
      assert_equal "<redacted>", result.receipt.fetch(:submitted_order_summary).fetch(:signature)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
    end

    test "nado live close submits reduce only buy" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ef" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: { digest: "0x#{"12" * 32}" } }
        }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.5"),
        current_position: { size: BigDecimal("-0.5"), symbol: "ETH-PERP" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      order = submitted.first.fetch(:place_order).fetch(:order)
      assert_equal "500000000000000000", order.fetch(:amount)
      assert_equal true, (order.fetch(:appendix).to_i & (1 << 11)).positive?
      assert_equal "submitted_and_confirmed", result.status
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
