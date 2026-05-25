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
          supported_actions: [ "sign_extended_order" ]
        }.to_json)
      }
    )

    assert_predicate client, :supports_extended_order_signing?
  end
end
