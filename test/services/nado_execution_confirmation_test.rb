require "test_helper"

class NadoExecutionConfirmationTest < ActiveSupport::TestCase
  test "confirms digest from archive order fill" do
    post_calls = []
    result = NadoExecutionConfirmation.confirm_digest(
      digest: "0xabc",
      product_id: 4,
      env: { "NADO_ARCHIVE_ENDPOINT" => "https://archive.nado.example" },
      venue: UnavailableQueryVenue.new,
      http_post: ->(uri, payload) {
        post_calls << [ uri.to_s, payload ]
        {
          "orders" => [
            {
              "digest" => "0xabc",
              "product_id" => 4,
              "base_filled" => "1000000000000000000",
              "submission_idx" => "123"
            }
          ]
        }
      },
      now: -> { Time.zone.parse("2026-06-06T12:00:01Z") }
    )

    assert_equal true, result.fetch(:confirmed)
    assert_equal "archive_order", result.fetch(:source)
    assert_equal "2026-06-06T12:00:01.000000Z", result.fetch(:confirmed_at)
    assert_equal 1, post_calls.size
    assert_equal({ orders: { digests: [ "0xabc" ], limit: 1 } }, post_calls.first.last)
  end

  test "confirms sell digest from negative archive base filled" do
    result = NadoExecutionConfirmation.confirm_digest(
      digest: "0xsell",
      product_id: 4,
      env: { "NADO_ARCHIVE_ENDPOINT" => "https://archive.nado.example" },
      venue: UnavailableQueryVenue.new,
      http_post: ->(_uri, _payload) {
        {
          "orders" => [
            {
              "digest" => "0xsell",
              "product_id" => 4,
              "amount" => "-2461000000000000000",
              "base_filled" => "-2461000000000000000",
              "quote_filled" => "5640000000000000000000"
            }
          ]
        }
      }
    )

    assert_equal true, result.fetch(:confirmed)
    assert_equal "archive_order", result.fetch(:source)
    assert_equal "-2461000000000000000", result.fetch(:order).fetch("base_filled")
  end

  test "confirms digest from gateway order when fill fields are present" do
    venue = GatewayVenue.new(
      "status" => "success",
      "data" => {
        "digest" => "0xabc",
        "product_id" => 4,
        "amount" => "-1000000000000000000",
        "unfilled_amount" => "0",
        "submission_idx" => "123"
      }
    )

    result = NadoExecutionConfirmation.confirm_digest(
      digest: "0xabc",
      product_id: 4,
      env: {},
      venue: venue,
      now: -> { Time.zone.parse("2026-06-06T12:00:02Z") }
    )

    assert_equal true, result.fetch(:confirmed)
    assert_equal "gateway_order", result.fetch(:source)
    assert_equal({ type: "order", product_id: 4, digest: "0xabc" }, venue.last_query)
  end

  test "does not confirm gateway status ok with empty order digest and no fill fields" do
    venue = GatewayVenue.new(
      "status" => "success",
      "data" => {
        "digest" => "",
        "product_id" => 4,
        "base_filled" => "0",
        "amount" => "0",
        "unfilled_amount" => "0"
      }
    )

    result = NadoExecutionConfirmation.confirm_digest(digest: "0xabc", product_id: 4, env: {}, venue: venue)
    gateway_attempt = result.fetch(:attempts).find { |attempt| attempt.fetch(:source) == "gateway_order" }

    assert_equal false, result.fetch(:confirmed)
    assert_equal "unconfirmed", result.fetch(:status)
    assert_equal "ok", gateway_attempt.fetch(:status)
    assert_equal "", gateway_attempt.fetch(:order_digest)
    assert_equal "0.0", gateway_attempt.fetch(:base_filled)
    assert_equal "NADO_ARCHIVE_ENDPOINT is not configured", result.fetch(:blockers).first
  end

  test "reports archive endpoint missing as diagnostic only" do
    result = NadoExecutionConfirmation.confirm_digest(
      digest: "0xabc",
      product_id: 4,
      env: {},
      venue: UnavailableQueryVenue.new
    )

    assert_equal false, result.fetch(:confirmed)
    assert_equal "unconfirmed", result.fetch(:status)
    assert_includes result.fetch(:blockers), "NADO_ARCHIVE_ENDPOINT is not configured"
    assert_equal({ orders: { digests: [ "0xabc" ], limit: 1 } }, result.fetch(:archive_order_request).fetch(:payload))
  end

  test "does not confirm unfilled gateway order" do
    venue = GatewayVenue.new(
      "status" => "success",
      "data" => {
        "digest" => "0xabc",
        "product_id" => 4,
        "amount" => "-1000000000000000000",
        "unfilled_amount" => "-1000000000000000000"
      }
    )

    result = NadoExecutionConfirmation.confirm_digest(digest: "0xabc", product_id: 4, env: {}, venue: venue)

    assert_equal false, result.fetch(:confirmed)
    assert_equal "unconfirmed", result.fetch(:status)
  end

  class UnavailableQueryVenue
    def query_available? = false
  end

  class GatewayVenue
    attr_reader :last_query

    def initialize(response)
      @response = response
    end

    def query_available? = true

    def query(params)
      @last_query = params
      @response
    end
  end
end
