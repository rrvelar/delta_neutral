require "test_helper"

class ExtendedApiClientTest < ActiveSupport::TestCase
  test "balance parses successful response" do
    client = ExtendedApiClient.new(
      env: extended_env,
      http_get: ->(uri, headers) {
        assert_equal "/api/v1/user/balance", uri.path
        assert_equal "redacted-test-key", headers.fetch("X-Api-Key")

        http_response(Net::HTTPOK, "200", { status: "OK", data: { equity: "12000", balance: "13500" } }.to_json)
      }
    )

    payload = client.balance

    assert_equal "OK", payload.fetch("status")
    assert_equal "12000", payload.dig("data", "equity")
  end

  test "balance 404 returns structured error without leaking api key" do
    client = ExtendedApiClient.new(
      env: extended_env,
      http_get: ->(_uri, _headers) {
        http_response(Net::HTTPNotFound, "404", { status: "ERROR", message: "balance not found", apiKey: "must-not-leak" }.to_json)
      }
    )

    payload = client.balance

    assert_equal "HTTP 404", payload.fetch("error")
    assert_equal 404, payload.fetch("http_status")
    assert_equal "balance not found", payload.fetch("message")
    assert_no_match(/redacted-test-key|must-not-leak|apiKey/i, payload.to_json)
  end

  test "submit order posts documented endpoint with api key header" do
    client = ExtendedApiClient.new(
      env: extended_env,
      http_post: ->(uri, headers, payload) {
        assert_equal "/api/v1/user/order", uri.path
        assert_equal "redacted-test-key", headers.fetch("X-Api-Key")
        assert_equal "ETH-USD", payload.fetch("market")

        http_response(Net::HTTPOK, "200", { status: "OK", data: { id: 12345 } }.to_json)
      }
    )

    payload = client.submit_order({ "market" => "ETH-USD" })

    assert_equal 12345, payload.dig("data", "id")
  end

  test "order_by_id GETs the documented order-by-id endpoint with api key" do
    client = ExtendedApiClient.new(
      env: extended_env,
      http_get: ->(uri, headers) {
        assert_equal "/api/v1/user/orders/2074738406414946304", uri.path
        assert_equal "redacted-test-key", headers.fetch("X-Api-Key")

        http_response(Net::HTTPOK, "200", { status: "OK", data: { id: 2074738406414946304, status: "FILLED", qty: "1.816", filledQty: "1.816", reduceOnly: false, side: "SELL", market: "ETH-USD" } }.to_json)
      }
    )

    payload = client.order_by_id("2074738406414946304")

    assert_equal "OK", payload.fetch("status")
    assert_equal "FILLED", payload.dig("data", "status")
  end

  test "order_by_id 404 returns structured error without leaking api key" do
    client = ExtendedApiClient.new(
      env: extended_env,
      http_get: ->(_uri, _headers) { http_response(Net::HTTPNotFound, "404", { status: "ERROR", message: "order not found", apiKey: "must-not-leak" }.to_json) }
    )

    payload = client.order_by_id("missing")

    assert_equal "HTTP 404", payload.fetch("error")
    assert_no_match(/redacted-test-key|must-not-leak/i, payload.to_json)
  end

  test "order_history and trades GET the documented market-scoped endpoints" do
    paths = []
    client = ExtendedApiClient.new(
      env: extended_env,
      http_get: ->(uri, _headers) {
        paths << "#{uri.path}?#{uri.query}"
        http_response(Net::HTTPOK, "200", { status: "OK", data: [] }.to_json)
      }
    )

    client.order_history(market: "ETH-USD")
    client.trades(market: "ETH-USD")

    assert_equal "/api/v1/user/orders/history?market=ETH-USD", paths[0]
    assert_equal "/api/v1/user/trades?market=ETH-USD", paths[1]
  end

  private

  def extended_env
    {
      "EXTENDED_API_BASE_URL" => "https://api.starknet.extended.exchange/api/v1",
      "EXTENDED_API_KEY" => "redacted-test-key",
      "EXTENDED_ACCOUNT_ID" => "acct",
      "EXTENDED_VAULT_NUMBER" => "123",
      "EXTENDED_CLIENT_ID" => "client",
      "EXTENDED_STARK_PUBLIC_KEY" => "0xpublic"
    }
  end

  def http_response(klass, code, body)
    response = klass.new("1.1", code, "status")
    response.instance_variable_set(:@read, true)
    response.instance_variable_set(:@body, body)
    response
  end
end
