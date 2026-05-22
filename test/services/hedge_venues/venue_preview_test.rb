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
  end
end
