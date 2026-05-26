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
