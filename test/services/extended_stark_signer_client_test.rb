require "test_helper"

class ExtendedStarkSignerClientTest < ActiveSupport::TestCase
  test "signer health is disabled by default without url" do
    client = ExtendedStarkSignerClient.new(env: {})

    health = client.health

    assert_equal false, health.fetch(:ok)
    assert_equal "EXTENDED_SIGNER_URL missing", health.fetch(:reason)
    assert_equal false, client.supports_extended_order_signing?
  end

  test "signer support requires Extended exchange and sign action" do
    client = ExtendedStarkSignerClient.new(
      env: { "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid" },
      http_get: ->(_uri) {
        Struct.new(:body).new({
          ok: true,
          supported_exchanges: [ "Extended" ],
          supported_actions: [ "sign_extended_order" ],
          verified_algorithm: true,
          signing_enabled: true
        }.to_json)
      }
    )

    assert_predicate client, :supports_extended_order_signing?
  end

  test "signer support rejects unverified algorithm" do
    client = ExtendedStarkSignerClient.new(
      env: { "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid" },
      http_get: ->(_uri) {
        Struct.new(:body).new({
          ok: true,
          supported_exchanges: [ "Extended" ],
          supported_actions: [ "sign_extended_order" ],
          verified_algorithm: false,
          signing_enabled: true
        }.to_json)
      }
    )

    assert_equal false, client.supports_extended_order_signing?
    assert_not client.verified_algorithm?
  end

  test "sign order posts to signer endpoint" do
    client = ExtendedStarkSignerClient.new(
      env: { "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid" },
      http_post: ->(uri, payload) {
        assert_equal "/sign/extended_order", uri.path
        assert_equal "ETH-USD", payload.dig(:order, "market")

        Struct.new(:body).new({ status: "signed", order_id: "123", settlement: { signature: { r: "0x1", s: "0x2" } } }.to_json)
      }
    )

    response = client.sign_order({ "market" => "ETH-USD" })

    assert_equal "signed", response.fetch(:status)
    assert_equal "123", response.fetch(:order_id)
  end
end
