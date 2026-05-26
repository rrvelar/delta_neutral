require "test_helper"

module HedgeVenues
  class VenuePreviewTest < ActiveSupport::TestCase
    test "hyperliquid is the default venue" do
      assert_equal "hyperliquid", HedgeVenues.normalize(nil)
      assert_instance_of HedgeVenues::Hyperliquid, HedgeVenues.build(nil)
    end

    test "extended venue is read only scaffold and disabled by default" do
      venue = HedgeVenues::Extended.new(env: {})
      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.1234"), max_slippage: "0.01")
      state = venue.account_state

      assert_equal "extended", HedgeVenues.normalize("extended")
      assert_equal "Extended", HedgeVenues.label("extended")
      assert_equal "Extended", preview.fetch(:venue)
      assert_equal "read_only_scaffold", preview.fetch(:mode)
      assert_equal false, preview.fetch(:live_supported)
      assert_equal false, preview.fetch(:live_enabled)
      assert_equal false, preview.fetch(:submit_enabled)
      assert_equal false, preview.fetch(:order_submission)
      assert_equal false, preview.fetch(:signature_required)
      assert_equal "extended_dry_run_order_intent", preview.fetch(:payload).fetch(:schema)
      assert_equal true, preview.fetch(:payload).fetch(:submit_implemented)
      assert_equal true, preview.fetch(:payload).fetch(:signing_implemented)
      assert_equal false, preview.fetch(:payload).fetch(:stark_signature_created)
      assert_equal "sell", preview.fetch(:payload).fetch(:side)
      assert_equal false, preview.fetch(:payload).fetch(:reduce_only)
      assert_equal "not_configured", state.fetch(:status)
      assert_includes state.fetch(:blockers), "EXTENDED_API_BASE_URL missing"
      assert_includes state.fetch(:blockers), "EXTENDED_API_KEY missing"
      assert_includes state.fetch(:blockers), "EXTENDED_ACCOUNT_ID missing"
      assert_includes state.fetch(:blockers), "EXTENDED_VAULT_NUMBER missing"
      assert_includes state.fetch(:blockers), "EXTENDED_CLIENT_ID missing"
      assert_includes state.fetch(:blockers), "EXTENDED_STARK_PUBLIC_KEY missing"
      assert_includes state.fetch(:blockers), "EXTENDED_MARKET_SYMBOL missing"
      assert_includes state.fetch(:blockers), "EXTENDED_SIZE_INCREMENT missing and not discovered from Extended market metadata"
      assert_includes state.fetch(:blockers), "EXTENDED_PRICE_INCREMENT missing and not discovered from Extended market metadata"
      assert_not_includes state.fetch(:blockers), "Extended submit endpoint integration not implemented."
      assert_includes state.fetch(:warnings), "Extended read-only scaffold."
      assert_nil venue.read_position(symbol: "ETH")
    end

    test "extended dry run previews map sides and reduce only flags" do
      venue = HedgeVenues::Extended.new(
        env: {
          "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
          "EXTENDED_SIZE_INCREMENT" => "0.0001",
          "EXTENDED_PRICE_INCREMENT" => "0.1"
        }
      )

      open = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.12345"), max_slippage: "0.01")
      increase = venue.rebalance_preview(symbol: "ETH", delta_eth: BigDecimal("0.05009"), max_slippage: "0.01")
      decrease = venue.rebalance_preview(symbol: "ETH", delta_eth: BigDecimal("-0.02009"), max_slippage: "0.01")
      close = venue.close_preview(symbol: "ETH", size_eth: BigDecimal("0.12345"))

      assert_extended_intent(open, action: "open_short", side: "sell", reduce_only: false, rounded_size: "0.1234")
      assert_extended_intent(increase, action: "increase_short", side: "sell", reduce_only: false, rounded_size: "0.05")
      assert_extended_intent(decrease, action: "decrease_short", side: "buy", reduce_only: true, rounded_size: "0.02")
      assert_extended_intent(close, action: "close_short", side: "buy", reduce_only: true, rounded_size: "0.1234")
    end

    test "extended dry run preview reports unknown rounding when market metadata is missing" do
      venue = HedgeVenues::Extended.new(env: {})
      preview = venue.rebalance_preview(symbol: "ETH", delta_eth: BigDecimal("-0.02"), max_slippage: "0.01")

      assert_equal "unknown", preview.fetch(:rounded_size_eth)
      assert_equal "unknown", preview.fetch(:payload).fetch(:rounded_size_eth)
      assert_equal "required_later", preview.fetch(:payload).fetch(:size_increment)
      assert_equal "required_later", preview.fetch(:payload).fetch(:price_increment)
      assert_includes preview.fetch(:blockers), "EXTENDED_MARKET_SYMBOL missing"
      assert_includes preview.fetch(:blockers), "EXTENDED_SIZE_INCREMENT missing and not discovered from Extended market metadata"
      assert_includes preview.fetch(:blockers), "EXTENDED_PRICE_INCREMENT missing and not discovered from Extended market metadata"
    end

    test "extended market metadata discovers increments from trading config" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT"),
        api_client: metadata_api_client(
          "data" => [
            { "name" => "BTC-USD", "tradingConfig" => { "minOrderSizeChange" => "0.001", "minPriceChange" => "1" } },
            {
              "name" => "ETH-USD",
              "active" => true,
              "tradingConfig" => {
                "minOrderSize" => "0.0001",
                "minOrderSizeChange" => "0.0001",
                "minPriceChange" => "0.1",
                "minOrderValue" => "10"
              },
              "marketStats" => { "markPrice" => "2100.5" },
              "l2Config" => { "syntheticAssetId" => "0x455448" }
            }
          ]
        )
      )

      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.12345"), max_slippage: "0.01")
      payload = preview.fetch(:payload)
      metadata = payload.fetch(:market_metadata)

      assert_equal "0.1234", preview.fetch(:rounded_size_eth)
      assert_equal "0.0001", payload.fetch(:size_increment)
      assert_equal "extended_api_market_metadata", payload.fetch(:size_increment_source)
      assert_equal "0.1", payload.fetch(:price_increment)
      assert_equal "extended_api_market_metadata", payload.fetch(:price_increment_source)
      assert_equal "ETH-USD", metadata.fetch(:matched_market_symbol)
      assert_equal "0.0001", metadata.fetch(:min_size)
      assert_equal "10", metadata.fetch(:min_notional)
      assert_equal "2100.5", metadata.fetch(:mark_price)
      assert_not_includes preview.fetch(:blockers), "EXTENDED_SIZE_INCREMENT missing and not discovered from Extended market metadata"
      assert_not_includes preview.fetch(:blockers), "EXTENDED_PRICE_INCREMENT missing and not discovered from Extended market metadata"
    end

    test "extended missing market metadata keeps blockers and prints safe response keys" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT"),
        api_client: metadata_api_client(
          "data" => {
            "name" => "ETH-USD",
            "apiKey" => "must-not-leak",
            "tradingConfig" => { "unsupportedField" => "1" }
          }
        )
      )

      state = venue.account_state
      metadata = state.fetch(:market_metadata)

      assert_includes state.fetch(:blockers), "EXTENDED_SIZE_INCREMENT missing and not discovered from Extended market metadata"
      assert_includes state.fetch(:blockers), "EXTENDED_PRICE_INCREMENT missing and not discovered from Extended market metadata"
      assert_equal "extended_api_market_metadata", metadata.fetch(:source)
      assert_includes metadata.fetch(:response_keys), "data"
      assert_includes metadata.fetch(:market_keys), "name"
      assert_includes metadata.fetch(:trading_config_keys), "unsupportedField"
      assert_no_match(/must-not-leak|apiKey/i, state.to_json)
    end

    test "extended market metadata env overrides win over api increments" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.merge(
          "EXTENDED_SIZE_INCREMENT" => "0.001",
          "EXTENDED_PRICE_INCREMENT" => "0.5"
        ),
        api_client: metadata_api_client(
          "data" => {
            "name" => "ETH-USD",
            "tradingConfig" => {
              "minOrderSizeChange" => "0.0001",
              "minPriceChange" => "0.1"
            }
          }
        )
      )

      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.12345"), max_slippage: "0.01")
      payload = preview.fetch(:payload)

      assert_equal "0.123", preview.fetch(:rounded_size_eth)
      assert_equal "0.001", payload.fetch(:size_increment)
      assert_equal "env", payload.fetch(:size_increment_source)
      assert_equal "0.5", payload.fetch(:price_increment)
      assert_equal "env", payload.fetch(:price_increment_source)
    end

    test "extended dry run blocks requested size below discovered min size" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT"),
        api_client: metadata_api_client(
          "data" => {
            "name" => "ETH-USD",
            "tradingConfig" => {
              "minOrderSize" => "0.01",
              "minOrderSizeChange" => "0.001",
              "minPriceChange" => "0.1"
            },
            "marketStats" => { "markPrice" => "2120" }
          }
        )
      )

      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.005"), max_slippage: "0.01")
      payload = preview.fetch(:payload)

      assert_equal "0.005", payload.fetch(:requested_size_eth)
      assert_equal "0.005", payload.fetch(:rounded_size_eth)
      assert_equal "0.01", payload.fetch(:min_size)
      assert_equal false, payload.fetch(:size_valid)
      assert_equal true, payload.fetch(:notional_valid)
      assert_includes preview.fetch(:blockers), "requested size 0.005 is below Extended min order size 0.01"
    end

    test "extended dry run passes discovered min size validation at minimum size" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT"),
        api_client: metadata_api_client(
          "data" => {
            "name" => "ETH-USD",
            "tradingConfig" => {
              "minOrderSize" => "0.01",
              "minOrderSizeChange" => "0.001",
              "minPriceChange" => "0.1"
            },
            "marketStats" => { "markPrice" => "2120" }
          }
        )
      )

      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.01"), max_slippage: "0.01")
      payload = preview.fetch(:payload)

      assert_equal "0.01", payload.fetch(:rounded_size_eth)
      assert_equal true, payload.fetch(:size_valid)
      assert_not_includes preview.fetch(:blockers), "requested size 0.01 is below Extended min order size 0.01"
    end

    test "extended dry run validates discovered min notional when available" do
      venue = HedgeVenues::Extended.new(
        env: extended_config_env.except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT"),
        api_client: metadata_api_client(
          "data" => {
            "name" => "ETH-USD",
            "tradingConfig" => {
              "minOrderSize" => "0.001",
              "minOrderSizeChange" => "0.001",
              "minPriceChange" => "0.1",
              "minOrderValue" => "25"
            },
            "marketStats" => { "markPrice" => "2120" }
          }
        )
      )

      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.01"), max_slippage: "0.01")
      payload = preview.fetch(:payload)

      assert_equal "25.0", payload.fetch(:min_notional)
      assert_equal "21.2", payload.fetch(:estimated_notional_usd)
      assert_equal false, payload.fetch(:notional_valid)
      assert_includes preview.fetch(:blockers), "estimated notional 21.2 is below Extended min notional 25.0"
    end

    test "extended execution service exposes dry run previews but live remains blocked" do
      venue = HedgeVenues::Extended.new(
        env: {
          "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
          "EXTENDED_SIZE_INCREMENT" => "0.0001",
          "EXTENDED_PRICE_INCREMENT" => "0.1"
        }
      )
      service = ExtendedHedgeExecutionService.new(venue: venue)

      decrease = service.decrease_short_preview(size_eth: BigDecimal("0.005"), max_slippage: "0.01")
      result = service.rebalance_short

      assert_extended_intent(decrease, action: "decrease_short", side: "buy", reduce_only: true, rounded_size: "0.005")
      assert_equal "blocked_before_submit", result.status
      assert_equal 0, result.receipt.fetch(:orders_submitted)
      assert_equal 0, result.receipt.fetch(:signatures_created)
      assert_equal false, result.receipt.fetch(:submitted)
    end

    test "extended execution service blocks all live actions without signing or submitting" do
      venue = HedgeVenues::Extended.new(env: {})
      service = ExtendedHedgeExecutionService.new(venue: venue)

      open = service.open_short
      rebalance = service.rebalance_short
      close = service.close_short

      [ open, rebalance, close ].each do |result|
        assert_equal "blocked_before_submit", result.status
        assert_includes result.blockers, "Extended live disabled."
        assert_not_includes result.blockers, "Extended submit endpoint integration not implemented."
        assert_equal 0, result.receipt.fetch(:orders_submitted)
        assert_equal 0, result.receipt.fetch(:signatures_created)
        assert_equal false, result.receipt.fetch(:submitted)
      end
    end

    test "extended preflight reports signer algorithm blocker only when health is unverified" do
      venue = HedgeVenues::Extended.new(env: {})
      signer = Struct.new(:health, keyword_init: true).new(
        health: {
          ok: false,
          reason: "algorithm disabled",
          verified_algorithm: false,
          signing_enabled: false,
          supported_exchanges: [],
          supported_actions: []
        }.with_indifferent_access
      )
      service = ExtendedHedgeExecutionService.new(venue: venue, signer_client: signer)
      position = Struct.new(:id).new(3)

      report = service.preflight(
        position: position,
        action: "open",
        size_eth: "0.01",
        current_position: nil,
        confirmation: nil,
        max_slippage: "0.01"
      )

      assert_includes report.fetch(:blockers), "Extended Stark signer unhealthy: algorithm disabled"
      assert_includes report.fetch(:blockers), "Extended Stark signer verified_algorithm=false"
      assert_includes report.fetch(:blockers), "Extended Stark signer signing_enabled=false"
      assert_not_includes report.fetch(:blockers), "Extended submit endpoint integration not implemented."
      assert_no_match(/private_key=|0x[a-f0-9]{40,}|authorization|cookie/i, report.to_json)
    end

    test "extended preflight removes algorithm blocker when signer advertises verified algorithm" do
      venue = HedgeVenues::Extended.new(env: {})
      signer = Struct.new(:health, keyword_init: true).new(
        health: {
          ok: true,
          reason: "ok",
          signer_id: "dummy-extended",
          supported_exchanges: [ "Extended" ],
          supported_actions: [ "sign_extended_order" ],
          verified_algorithm: true,
          signing_enabled: true,
          stark_public_key: "0x1234...abcd"
        }.with_indifferent_access
      )
      service = ExtendedHedgeExecutionService.new(venue: venue, signer_client: signer)
      position = Struct.new(:id).new(3)

      report = service.preflight(
        position: position,
        action: "open",
        size_eth: "0.01",
        current_position: nil,
        confirmation: nil,
        max_slippage: "0.01"
      )

      assert_not_includes report.fetch(:blockers), "Extended Stark signer verified_algorithm=false"
      assert_not_includes report.fetch(:blockers), "Extended Stark signer signing_enabled=false"
      assert_not report.fetch(:blockers).any? { |blocker| blocker.to_s.start_with?("Extended Stark signer unhealthy") }
      assert_not_includes report.fetch(:blockers), "Extended submit endpoint integration not implemented."
      assert_equal true, report.dig(:signer_health, "verified_algorithm")
      assert_equal false, report.fetch(:submitted)
    end

    def assert_extended_intent(preview, action:, side:, reduce_only:, rounded_size:)
      payload = preview.fetch(:payload)
      assert_equal "extended_dry_run_order_intent", payload.fetch(:schema)
      assert_equal action, payload.fetch(:action)
      assert_equal side, payload.fetch(:side)
      assert_equal side.upcase, payload.fetch(:extended_side)
      assert_equal reduce_only, payload.fetch(:reduce_only)
      assert_equal rounded_size, payload.fetch(:rounded_size_eth)
      assert_equal false, payload.fetch(:order_submission)
      assert_equal true, payload.fetch(:signature_required)
      assert_equal false, payload.fetch(:stark_signature_created)
      assert_equal true, payload.fetch(:submit_implemented)
      assert_equal true, payload.fetch(:signing_implemented)
      assert_equal false, payload.fetch(:cancel_implemented)
      assert_equal true, payload.fetch(:live_submit_blocked)
      assert_equal "POST /user/order", payload.fetch(:submit_endpoint)
      assert_equal "dry_run_no_signature", payload.dig(:signer_request, :status)
    end

    test "extended normalized read only position shape maps short fields" do
      venue = HedgeVenues::Extended.new(env: { "EXTENDED_MARKET_SYMBOL" => "ETH-USD" })

      position = venue.normalize_position(
        market: "ETH-USD",
        side: "SHORT",
        size: "-0.25",
        value: "520",
        open_price: "2100",
        mark_price: "2080",
        unrealised_pnl: "5",
        equity: "1000",
        margin_mode: "cross",
        status: "OPENED"
      )

      assert_equal "Extended", position.fetch(:venue)
      assert_equal "ETH-PERP", position.fetch(:symbol)
      assert_equal "ETH-USD", position.fetch(:market_symbol)
      assert_equal "short", position.fetch(:side)
      assert_equal "-0.25", position.fetch(:size)
      assert_equal "0.25", position.fetch(:short_size)
      assert_equal "520.0", position.fetch(:notional_usd)
      assert_equal "2100.0", position.fetch(:entry_price)
      assert_equal "2080.0", position.fetch(:mark_price)
      assert_equal "5.0", position.fetch(:unrealized_pnl_usd)
      assert_equal "1000.0", position.fetch(:account_value_usd)
      assert_equal "0.52", position.fetch(:effective_leverage)
      assert_equal "cross", position.fetch(:margin_mode)
      assert_equal "OPENED", position.fetch(:status)
    end

    test "extended read only fixture normalizes a short position from api client" do
      api_client = Class.new do
        def positions(market:)
          [ { "market" => market, "side" => "SHORT", "size" => "0.42", "value" => "882", "openPrice" => "2120", "markPrice" => "2100", "unrealisedPnl" => "8", "status" => "OPEN" } ]
        end

        def balance = { "equity" => "5000", "balance" => "5000" }
        def account_info = { "status" => "ACTIVE" }
        def market(market:) = { "name" => market, "active" => true }
        def open_orders(market:) = []
      end.new
      venue = HedgeVenues::Extended.new(env: extended_config_env, api_client: api_client)

      position = venue.read_position(symbol: "ETH")
      state = venue.account_state

      assert_equal "Extended", position.fetch(:venue)
      assert_equal "ETH-USD", position.fetch(:market_symbol)
      assert_equal "short", position.fetch(:side)
      assert_equal "-0.42", position.fetch(:size)
      assert_equal "0.42", position.fetch(:short_size)
      assert_equal "882.0", position.fetch(:notional_usd)
      assert_equal "5000.0", position.fetch(:account_value_usd)
      assert_equal "read_only", state.fetch(:status)
      assert_equal "0.42", state.fetch(:current_short_eth)
      assert_equal 0, state.fetch(:open_orders_count)
    end

    test "extended account state parses documented balance data payload" do
      api_client = Class.new do
        def positions(market:) = []
        def balance = { "status" => "OK", "data" => { "collateralName" => "USDC", "balance" => "13500", "equity" => "12000", "availableForTrade" => "1200" } }
        def account_info = { "status" => "ACTIVE" }
        def market(market:) = { "name" => market, "active" => true }
        def open_orders(market:) = []
      end.new
      venue = HedgeVenues::Extended.new(env: extended_config_env, api_client: api_client)

      state = venue.account_state
      diagnostics = state.fetch(:read_only_diagnostics)

      assert_equal "read_only", state.fetch(:status)
      assert_equal "12000.0", state.fetch(:account_value_usd)
      assert_equal "13500.0", state.fetch(:collateral_usd)
      assert_equal "ok", diagnostics.fetch(:balance_read_status)
      assert_includes diagnostics.fetch(:balance_data_keys), "equity"
      assert_no_match(/redacted-test-key|authorization|cookie/i, state.to_json)
    end

    test "extended balance 404 is classified as unsupported zero balance not read only error" do
      api_client = Class.new do
        def positions(market:) = []
        def balance = { "error" => "HTTP 404", "http_status" => 404, "message" => "balance not found", "response_keys" => [ "message", "status" ] }
        def account_info = { "status" => "ACTIVE" }
        def market(market:) = { "name" => market, "active" => true }
        def open_orders(market:) = []
      end.new
      venue = HedgeVenues::Extended.new(env: extended_config_env, api_client: api_client)

      state = venue.account_state
      diagnostics = state.fetch(:read_only_diagnostics)

      assert_equal "read_only", state.fetch(:status)
      assert_equal "unsupported", diagnostics.fetch(:balance_read_status)
      assert_equal 404, diagnostics.fetch(:balance_http_status)
      assert_equal "Extended balance endpoint returned HTTP 404; docs state this means the user's balance is 0.", diagnostics.fetch(:balance_stop_reason)
    end

    test "extended account info fallback fills collateral when balance is unsupported" do
      api_client = Class.new do
        def positions(market:) = []
        def balance = { "error" => "HTTP 404", "http_status" => 404, "message" => "balance not found" }
        def account_info = { "status" => "ACTIVE", "data" => { "equity" => "100", "balance" => "125" } }
        def market(market:) = { "name" => market, "active" => true }
        def open_orders(market:) = []
      end.new
      venue = HedgeVenues::Extended.new(env: extended_config_env, api_client: api_client)

      state = venue.account_state

      assert_equal "read_only", state.fetch(:status)
      assert_equal "100.0", state.fetch(:account_value_usd)
      assert_equal "125.0", state.fetch(:collateral_usd)
    end

    def extended_config_env
      {
        "EXTENDED_API_BASE_URL" => "https://api.starknet.extended.exchange/api/v1",
        "EXTENDED_API_KEY" => "redacted-test-key",
        "EXTENDED_ACCOUNT_ID" => "account",
        "EXTENDED_VAULT_NUMBER" => "123",
        "EXTENDED_CLIENT_ID" => "client",
        "EXTENDED_STARK_PUBLIC_KEY" => "0xpublic",
        "EXTENDED_MARKET_SYMBOL" => "ETH-USD",
        "EXTENDED_SIZE_INCREMENT" => "0.0001",
        "EXTENDED_PRICE_INCREMENT" => "0.1"
      }
    end

    def metadata_api_client(market_payload)
      Class.new do
        define_method(:initialize) do |payload|
          @payload = payload
        end

        def positions(market:) = []
        def balance = { "equity" => "5000", "balance" => "5000" }
        def account_info = { "status" => "ACTIVE" }
        def open_orders(market:) = []

        define_method(:market) do |market:|
          @payload
        end
      end.new(market_payload)
    end

    test "ethereal preview is cross margin live gated and reports missing config blockers" do
      venue = HedgeVenues::Ethereal.new(env: {})
      preview = venue.open_short_preview(symbol: "ETH", size_eth: BigDecimal("0.1234"), max_slippage: "0.01")

      assert_equal "Ethereal", preview.fetch(:venue)
      assert_equal "read_only_dry_run", preview.fetch(:mode)
      assert_equal false, preview.fetch(:submit_enabled)
      assert_equal false, preview.fetch(:order_submission)
      assert_equal "ethereal_eip712_trade_order", preview.fetch(:payload).fetch(:schema)
      assert_equal "cross", preview.fetch(:payload).fetch(:margin_mode)
      assert_includes preview.fetch(:blockers), "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true for Ethereal live submit."
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
      assert_equal true, state.fetch(:live_supported)
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

    test "ethereal read position treats negative raw size as short even when numeric side is present" do
      venue = HedgeVenues::Ethereal.new(env: ethereal_readonly_env, probe: ethereal_probe_with_position(raw_size: "-0.5607", raw_side: 1))

      position = venue.read_position(symbol: "ETH")
      state = venue.account_state

      assert_equal "short", position.fetch(:side)
      assert_equal "-0.5607", position.fetch(:size)
      assert_equal "0.5607", position.fetch(:short_size)
      assert_equal "cross", position.fetch(:margin_mode)
      assert_nil position[:warnings]
      assert_equal "0.5607", state.fetch(:current_short_eth)
      assert_equal "short", state.fetch(:current_side)
      assert_equal 1, state.fetch(:hedge_positions_count)
    end

    test "ethereal read position treats positive raw size as long and warns on side disagreement" do
      venue = HedgeVenues::Ethereal.new(env: ethereal_readonly_env, probe: ethereal_probe_with_position(raw_size: "0.5607", raw_side: 1))

      position = venue.read_position(symbol: "ETH")
      state = venue.account_state

      assert_equal "long", position.fetch(:side)
      assert_equal "0.5607", position.fetch(:size)
      assert_equal "0", position.fetch(:short_size)
      assert_match "disagrees with signed size", position.fetch(:warnings).first
      assert_equal "0", state.fetch(:current_short_eth)
      assert_equal "long", state.fetch(:current_side)
      assert_match "disagrees with signed size", state.fetch(:warnings).last
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

    test "nado isolated planner chooses no op increase and delta decrease" do
      service = NadoHedgeExecutionService.new(env: nado_live_env)

      no_op = service.plan_rebalance(
        target_size_eth: BigDecimal("0.9361"),
        current_position: { size: BigDecimal("-0.936"), symbol: "ETH-PERP", margin_mode: "isolated" },
        tolerance_eth: BigDecimal("0.001")
      )
      increase = service.plan_rebalance(
        target_size_eth: BigDecimal("1.1"),
        current_position: { size: BigDecimal("-0.936"), symbol: "ETH-PERP", margin_mode: "isolated" },
        tolerance_eth: BigDecimal("0.001")
      )
      decrease = service.plan_rebalance(
        target_size_eth: BigDecimal("0.794"),
        current_position: { size: BigDecimal("-0.936"), symbol: "ETH-PERP", margin_mode: "isolated" },
        tolerance_eth: BigDecimal("0.001")
      )

      assert_equal "no_op", no_op.fetch(:action)
      assert_equal "isolated_increase", increase.fetch(:action)
      assert_equal "isolated_decrease", decrease.fetch(:action)
      assert_equal true, decrease.fetch(:partial_isolated_reduce_supported)
      assert_equal "delta_reduce", decrease.fetch(:isolated_decrease_strategy)
      assert_equal "isolated_decrease", decrease.fetch(:strategy)
    end

    test "nado isolated planner can still choose close reopen fallback by env" do
      service = NadoHedgeExecutionService.new(env: nado_live_env.merge("AERODROME_NADO_ISOLATED_DECREASE_STRATEGY" => "close_reopen"))

      plan = service.plan_rebalance(
        target_size_eth: BigDecimal("0.794"),
        current_position: { size: BigDecimal("-0.936"), symbol: "ETH-PERP", margin_mode: "isolated" },
        tolerance_eth: BigDecimal("0.001")
      )

      assert_equal "isolated_full_close_then_reopen", plan.fetch(:action)
      assert_equal "close_reopen", plan.fetch(:isolated_decrease_strategy)
      assert_equal false, plan.fetch(:partial_isolated_reduce_supported)
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

    test "nado live rebalance partial decrease isolated short uses delta reduce only" do
      submitted = []
      venue = NadoPollingVenue.new([ { size: BigDecimal("-0.845"), short_size: BigDecimal("0.845"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" } ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
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

      assert_equal 1, submitted.size
      assert_equal "submitted_and_confirmed", result.status
      assert_equal "isolated_decrease", result.receipt.fetch(:action_plan).fetch(:action)
      assert_equal "delta_only", result.receipt.fetch(:action_plan).fetch(:strategy)
      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      summary = result.receipt.fetch(:submitted_order_summary)
      assert_equal "91000000000000000", order.fetch(:amount)
      assert_equal "2817", order.fetch(:appendix)
      assert_equal "buy", summary.fetch(:side)
      assert_equal true, summary.fetch(:reduce_only)
      assert_equal "default_1", summary.fetch(:order_sender_kind)
      assert_equal false, summary.fetch(:full_close)
      assert_equal false, summary.fetch(:close_reopen)
      assert_equal "0.845", summary.fetch(:expected_after_short_eth)
    end

    test "nado close reopen stops before reopen when close readback does not confirm flat" do
      submitted = []
      venue = NadoPollingVenue.new(
        Array.new(NadoHedgeExecutionService::POST_SUBMIT_CLOSE_READBACK_ATTEMPTS) {
          { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" }
        },
        env: nado_live_env
      )
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_ISOLATED_DECREASE_STRATEGY" => "close_reopen"),
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
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

      assert_equal 1, submitted.size
      assert_equal "submitted_but_not_confirmed", result.status
      assert_nil result.receipt.fetch(:reopen_leg)
      assert_match "reopen was not submitted", result.receipt.fetch(:final_message)
    end

    test "nado close reopen records reopen rejection after confirmed close" do
      submitted = []
      venue = NadoPollingVenue.new([ nil ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_ISOLATED_DECREASE_STRATEGY" => "close_reopen"),
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          if submitted.size == 1
            { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
          else
            { status: "failure", data: [ { error_code: 2006, error: "Insufficient account health." } ] }
          end
        },
        sleeper: ->(_seconds) { }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
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

      assert_equal 2, submitted.size
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", result.receipt.fetch(:reopen_leg).fetch(:submit_response_classification).fetch(:status)
      assert_match "error_code=2006", result.receipt.fetch(:final_message)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
    end

    test "nado close reopen waits for delayed flat before reopening" do
      submitted = []
      venue = NadoPollingVenue.new(
        [
          { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" },
          { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" },
          nil,
          { size: BigDecimal("-0.845"), short_size: BigDecimal("0.845"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" }
        ],
        env: nado_live_env
      )
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_ISOLATED_DECREASE_STRATEGY" => "close_reopen"),
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("-0.091"),
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

      assert_equal 2, submitted.size
      assert_equal "submitted_and_confirmed", result.status
      assert_equal 3, result.receipt.fetch(:close_leg).fetch(:post_submit_readback_poll_attempts).size
    end

    test "nado resume reopen after delayed flat only opens target when readback is flat" do
      submitted = []
      venue = NadoPollingVenue.new([ nil, { size: BigDecimal("-0.845"), short_size: BigDecimal("0.845"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" } ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"90" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.resume_reopen_after_close(
        position: mellow_position,
        target_size_eth: BigDecimal("0.845"),
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal 1, submitted.size
      assert_equal "resume_reopen_after_close", result.receipt.fetch(:action)
      assert_equal true, result.receipt.fetch(:resume_after_delayed_flat)
      assert_equal "submitted_and_confirmed", result.status
      assert_equal "-845000000000000000", submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order).fetch(:amount)
    end

    test "nado resume reopen after delayed flat blocks when short remains" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: NadoPollingVenue.new([ { size: BigDecimal("-0.1"), short_size: BigDecimal("0.1"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" } ], env: nado_live_env),
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.resume_reopen_after_close(
        position: mellow_position,
        target_size_eth: BigDecimal("0.845"),
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_match "requires flat readback", result.receipt.fetch(:final_message)
    end

    test "nado live close isolated short uses ui equivalent isolated reduce only appendix" do
      submitted = []
      signer_payloads = []
      isolated_sender = "0x#{"02" * 32}"
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, payload) {
          signer_payloads << payload
          { status: "signed", signature: "0x#{"ef" * 65}" }
        },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        }
      )

      service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.1"),
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
      appendix = order.fetch(:appendix).to_i
      assert_equal "0x#{"11" * 20}64656661756c745f31000000", order.fetch(:sender)
      assert_equal isolated_sender, summary.fetch(:current_position_subaccount)
      assert_equal true, summary.fetch(:full_close)
      assert_equal "ui_market_close_position_equivalent", summary.fetch(:close_strategy)
      assert_equal "default_1", summary.fetch(:order_sender_kind)
      assert_equal "0.936", summary.fetch(:current_short_size_eth)
      assert_equal "0.936", summary.fetch(:rounded_size_eth)
      assert_equal "936000000000000000", order.fetch(:amount)
      assert_equal "buy", summary.fetch(:side)
      assert_equal true, summary.fetch(:reduce_only)
      assert_equal "isolated_ui_equivalent_close", summary.fetch(:margin_mode)
      assert_equal "1909.0", summary.fetch(:isolated_margin_usd)
      assert_nil summary.fetch(:isolated_margin_x6)
      assert_equal 1_909_000_000, summary.fetch(:current_position_isolated_margin_x6)
      assert_equal true, decoded.fetch(:isolated)
      assert_equal true, decoded.fetch(:reduce_only)
      assert_equal "ioc", decoded.fetch(:order_type)
      assert_equal 0, appendix >> 64
      assert_equal 2817, appendix
      assert_equal 13, order.fetch(:expiration).length
    end

    test "nado live close isolated short blocks instead of rounding full close into partial close" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.1"),
        current_position: {
          size: BigDecimal("-0.9365"),
          short_size: BigDecimal("0.9365"),
          symbol: "ETH-PERP",
          side: "short",
          margin_mode: "isolated",
          isolated_margin_usd: BigDecimal("1909")
        },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "Nado isolated full close size is not divisible by size increment; refusing partial close."
    end

    test "nado isolated ui equivalent close does not require isolated margin readback" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.936"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_equal "submitted_and_confirmed", result.status
      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "2817", order.fetch(:appendix)
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
      assert_equal NadoHedgeExecutionService::POST_SUBMIT_READBACK_ATTEMPTS, result.receipt.fetch(:post_submit_readback_poll_attempts).size
      assert_nil result.receipt.fetch(:post_submit_readback)
      assert_no_match(/#{'ab' * 20}|private_key|authorization|cookie/i, result.receipt.to_json)
    end

    test "nado accepted submit can confirm after delayed readback polling" do
      readbacks = [ nil, nil, nil, nado_isolated_short(size: "0.955") ]
      venue = NadoPollingVenue.new(readbacks, env: nado_live_env)
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
      assert_equal 4, result.receipt.fetch(:post_submit_readback_poll_attempts).size
      assert_equal BigDecimal("0.955"), result.receipt.fetch(:post_submit_readback).fetch(:short_size)
    end

    test "nado pending result reconciles when later readback matches expected short" do
      pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
        final_status: "submitted_but_readback_pending",
        action_plan: { expected_after_short_eth: "0.814" },
        submitted_order_summary: { side: "sell", reduce_only: false, rounded_size_eth: "0.005" },
        post_submit_readback: nil
      })
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        venue: NadoPollingVenue.new([ nado_isolated_short(size: "0.814") ], env: nado_live_env)
      )

      result = service.reconcile_pending_result(pending)

      assert_equal "submitted_and_confirmed", result.status
      assert_equal true, result.receipt.fetch(:reconciled_after_pending)
      assert_equal "Nado submit confirmed by later readback.", result.receipt.fetch(:final_message)
      assert_equal BigDecimal("0.814"), result.receipt.fetch(:post_submit_readback).fetch(:short_size)
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

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.936"),
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

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.936"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated", isolated_margin_usd: BigDecimal("1909") },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", classification.fetch(:status)
      assert_match "error_code=2081", classification.fetch(:message)
      assert_match "isolated subaccount cannot place order", classification.fetch(:message)
      assert_equal "0x#{"11" * 20}64656661756c745f31000000", result.receipt.fetch(:submitted_order_summary).fetch(:sender)
    end

    test "nado insufficient account health rejection records exchange reason" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) {
          {
            status: "failure",
            data: [ { error_code: 2006, error: "Insufficient account health. The execution of this order would lower your account health below the required threshold." } ],
            request_type: "execute_place_orders"
          }
        }
      )

      result = service.close_short(
        position: mellow_position,
        size_eth: BigDecimal("0.936"),
        current_position: { size: BigDecimal("-0.936"), short_size: BigDecimal("0.936"), symbol: "ETH-PERP", side: "short", margin_mode: "isolated", isolated_margin_usd: BigDecimal("1909") },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      classification = result.receipt.fetch(:submit_response_classification)
      assert_equal "failed_before_submit", result.status
      assert_equal "rejected", classification.fetch(:status)
      assert_match "error_code=2006", classification.fetch(:message)
      assert_match "Insufficient account health", classification.fetch(:message)
      assert_no_match(/#{'ab' * 20}/, result.receipt.to_json)
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

      result = service.rebalance_short(
        position: mellow_position,
        delta_eth: BigDecimal("0.25"),
        current_position: { size: BigDecimal("-0.75"), symbol: "ETH-PERP", margin_mode: "isolated" },
        confirmation: "CONFIRM_NADO",
        max_slippage: "0.01"
      )

      assert_empty result.blockers
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

    test "nado delta probe dry-run decrease builds delta reduce-only payload not full close" do
      service = NadoHedgeExecutionService.new(env: nado_live_env)

      result = service.delta_probe(
        position: mellow_position,
        direction: "decrease",
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: nil,
        max_slippage: "0.01",
        dry_run: true
      )

      summary = result.receipt.fetch(:payload_summary)
      assert_equal "dry_run", result.status
      assert_equal "decrease", summary.fetch(:probe_direction)
      assert_equal "0.005", summary.fetch(:rounded_size_eth)
      assert_equal "5000000000000000", summary.fetch(:amount_x18)
      assert_equal "buy", summary.fetch(:side)
      assert_equal true, summary.fetch(:reduce_only)
      assert_equal false, summary.fetch(:full_close)
      assert_equal false, summary.fetch(:close_reopen)
      assert_equal true, summary.fetch(:partial_reduce_candidate)
      assert_equal "2817", summary.fetch(:appendix)
      assert_equal "default_1", summary.fetch(:order_sender_kind)
      assert_equal "0x#{"11" * 20}64656661756c745f31000000", summary.fetch(:sender)
      assert_equal "0.804", summary.fetch(:expected_after_short_eth)
      assert_no_match(/#{'ab' * 20}|private_key|authorization|cookie/i, result.receipt.to_json)
    end

    test "nado delta probe dry-run increase builds isolated sell delta payload" do
      service = NadoHedgeExecutionService.new(env: nado_live_env)

      result = service.delta_probe(
        position: mellow_position,
        direction: "increase",
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: nil,
        max_slippage: "0.01",
        dry_run: true
      )

      summary = result.receipt.fetch(:payload_summary)
      assert_equal "dry_run", result.status
      assert_equal "increase", summary.fetch(:probe_direction)
      assert_equal "-5000000000000000", summary.fetch(:amount_x18)
      assert_equal "sell", summary.fetch(:side)
      assert_equal false, summary.fetch(:reduce_only)
      assert_equal true, summary.fetch(:isolated)
      assert_equal "isolated", summary.fetch(:margin_mode)
      assert_equal "0.814", summary.fetch(:expected_after_short_eth)
      assert_match "appendix high bits", summary.fetch(:isolated_margin_handling)
    end

    test "nado delta probe live mode refuses without explicit env gate and confirmation" do
      service = NadoHedgeExecutionService.new(
        env: nado_live_env,
        signer_post: ->(*) { raise "signer should not be called" }
      )

      result = service.delta_probe(
        position: mellow_position,
        direction: "decrease",
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: "wrong",
        max_slippage: "0.01",
        dry_run: false
      )

      assert_equal "blocked_before_submit", result.status
      assert_includes result.blockers, "AERODROME_NADO_DELTA_PROBE_ENABLED must be true"
      assert_includes result.blockers, "submitted confirmation must equal #{NadoHedgeExecutionService::DELTA_PROBE_CONFIRMATION}"
    end

    test "nado delta probe round trip refuses non isolated short" do
      service = NadoHedgeExecutionService.new(env: nado_live_env)

      result = service.round_trip_delta_probe(
        position: mellow_position,
        size_eth: BigDecimal("0.005"),
        current_position: { size: BigDecimal("-0.809"), short_size: BigDecimal("0.809"), symbol: "ETH-PERP", side: "short", margin_mode: "cross" },
        confirmation: nil,
        max_slippage: "0.01",
        dry_run: true
      )

      assert_equal "dry_run", result.status
      assert_includes result.blockers, "current Nado position must be an isolated short"
      assert_nil result.receipt.fetch(:increase_leg)
    end

    test "nado delta probe decrease success requires readback before minus delta" do
      submitted = []
      venue = NadoPollingVenue.new([ nado_isolated_short(size: "0.804") ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_DELTA_PROBE_ENABLED" => "true"),
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "success", data: [ { digest: "0x#{"12" * 32}" } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.delta_probe(
        position: mellow_position,
        direction: "decrease",
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: NadoHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
        max_slippage: "0.01",
        dry_run: false
      )

      assert_equal "submitted_and_confirmed", result.status
      order = submitted.first.fetch(:place_orders).fetch(:orders).first.fetch(:order)
      assert_equal "5000000000000000", order.fetch(:amount)
      assert_equal "2817", order.fetch(:appendix)
      assert_equal "0.804", result.receipt.fetch(:expected_after_short_eth)
      assert_equal BigDecimal("0.804"), result.receipt.fetch(:after_readback).fetch(:short_size)
    end

    test "nado delta probe increase success requires readback before plus delta" do
      venue = NadoPollingVenue.new([ nado_isolated_short(size: "0.814") ], env: nado_live_env)
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_DELTA_PROBE_ENABLED" => "true"),
        venue: venue,
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, _payload) { { status: "success", data: [ { digest: "0x#{"34" * 32}" } ] } },
        sleeper: ->(_seconds) { }
      )

      result = service.delta_probe(
        position: mellow_position,
        direction: "increase",
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: NadoHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
        max_slippage: "0.01",
        dry_run: false
      )

      assert_equal "submitted_and_confirmed", result.status
      assert_equal "0.814", result.receipt.fetch(:expected_after_short_eth)
      assert_equal BigDecimal("0.814"), result.receipt.fetch(:after_readback).fetch(:short_size)
    end

    test "nado delta probe round trip does not run increase after failed decrease" do
      submitted = []
      service = NadoHedgeExecutionService.new(
        env: nado_live_env.merge("AERODROME_NADO_DELTA_PROBE_ENABLED" => "true"),
        venue: NadoPollingVenue.new([ nado_isolated_short(size: "0.809") ], env: nado_live_env),
        signer_post: ->(_uri, _payload) { { status: "signed", signature: "0x#{"ab" * 65}", signer_id: "test-signer" } },
        http_post: ->(_uri, payload) {
          submitted << payload
          { status: "failure", data: [ { error_code: 400, error: "Reduce only order increases position." } ] }
        },
        sleeper: ->(_seconds) { }
      )

      result = service.round_trip_delta_probe(
        position: mellow_position,
        size_eth: BigDecimal("0.005"),
        current_position: nado_isolated_short(size: "0.809"),
        confirmation: NadoHedgeExecutionService::DELTA_PROBE_CONFIRMATION,
        max_slippage: "0.01",
        dry_run: false
      )

      assert_equal 1, submitted.size
      assert_equal "failed_before_submit", result.status
      assert_nil result.receipt.fetch(:increase_leg)
      assert_match "increase leg was not submitted", result.receipt.fetch(:final_message)
      assert_no_match(/#{'ab' * 20}|private_key|authorization|cookie/i, result.receipt.to_json)
    end

    private

    def nado_live_env
      {
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_HEDGE_CONFIRMATION" => "CONFIRM_NADO",
        "NADO_API_BASE_URL" => "https://nado.example/v1",
        "NADO_ACCOUNT_ADDRESS" => "0x#{"11" * 20}",
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

    def ethereal_readonly_env
      {
        "ETHEREAL_READ_ONLY_ENABLED" => "true",
        "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
        "ETHEREAL_SUBACCOUNT_ID" => "primary"
      }
    end

    def ethereal_probe_with_position(raw_size:, raw_side:)
      account_health = HedgeBackends::AccountHealth.new(
        backend: "ethereal",
        collateral: "USD",
        account_value_usd: "2000",
        withdrawable_usd: "1500",
        margin_used_usd: "500",
        status: "ok"
      )
      raw = { "size" => raw_size, "side" => raw_side }
      snapshot = HedgeBackends::PositionSnapshot.new(
        backend: "ethereal",
        asset: "ETH",
        market: "ETHUSD",
        signed_size: raw_side.to_i == 1 ? BigDecimal(raw_size).abs : BigDecimal(raw_size),
        short_size: "0",
        mark_price: "2100",
        position_value: "1178.87",
        raw: raw,
        status: "ok"
      )
      Object.new.tap do |probe|
        probe.define_singleton_method(:get_position) { |_symbol| snapshot }
        probe.define_singleton_method(:account_health) { account_health }
      end
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

    def nado_isolated_short(size:)
      short = BigDecimal(size)
      {
        size: -short,
        short_size: short,
        symbol: "ETH-PERP",
        side: "short",
        margin_mode: "isolated",
        isolated_margin_usd: BigDecimal("1860.7"),
        metadata: { raw: { "subaccount" => "0x#{"02" * 32}" } }
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
