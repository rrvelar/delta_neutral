require "test_helper"

class ExtendedSetLeverageCheckTest < ActiveSupport::TestCase
  test "dry run reads leverage and does not patch" do
    api_client = fake_api_client(leverage_sequence: [ "10" ])
    result = build_service(api_client: api_client).run(dry_run: true)

    assert_equal "dry_run", result.status
    assert_equal "10.0", result.receipt.fetch(:current_leverage)
    assert_equal "1.0", result.receipt.fetch(:target_leverage)
    assert_equal "ETH-USD", result.receipt.fetch(:market)
    assert_equal 0, api_client.patch_calls
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live blocks without set leverage gate" do
    api_client = fake_api_client(leverage_sequence: [ "10" ])
    result = build_service(api_client: api_client, env: extended_env).run(dry_run: false, confirmation: ExtendedSetLeverageCheck::CONFIRMATION)

    assert_equal "blocked_before_patch", result.status
    assert_includes result.blockers, "EXTENDED_SET_LEVERAGE_ENABLED must be true"
    assert_equal 0, api_client.patch_calls
  end

  test "live blocks without confirmation" do
    api_client = fake_api_client(leverage_sequence: [ "10" ])
    result = build_service(api_client: api_client, env: live_env).run(dry_run: false, confirmation: "wrong")

    assert_equal "blocked_before_patch", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedSetLeverageCheck::CONFIRMATION}"
    assert_equal 0, api_client.patch_calls
  end

  test "live blocks when current Extended position exists" do
    api_client = fake_api_client(
      leverage_sequence: [ "10" ],
      positions: [ { market: "ETH-USD", side: "SHORT", size: "0.01", value: "21.2" } ]
    )
    result = build_service(api_client: api_client, env: live_env).run(dry_run: false, confirmation: ExtendedSetLeverageCheck::CONFIRMATION)

    assert_equal "blocked_before_patch", result.status
    assert_includes result.blockers, "Extended set leverage requires no current Extended position"
    assert_equal 0, api_client.patch_calls
  end

  test "live blocks when open orders exist" do
    api_client = fake_api_client(leverage_sequence: [ "10" ], open_orders: [ { id: "order-1" } ])
    result = build_service(api_client: api_client, env: live_env).run(dry_run: false, confirmation: ExtendedSetLeverageCheck::CONFIRMATION)

    assert_equal "blocked_before_patch", result.status
    assert_includes result.blockers, "Extended set leverage requires open_orders_count=0"
    assert_equal 0, api_client.patch_calls
  end

  test "successful mocked patch reads back leverage 1" do
    api_client = fake_api_client(leverage_sequence: [ "10", "1" ], patch_response: { "status" => "OK", "apiKey" => "secret" })
    result = build_service(api_client: api_client, env: live_env).run(dry_run: false, confirmation: ExtendedSetLeverageCheck::CONFIRMATION)

    assert_equal "success", result.status
    assert_equal 1, api_client.patch_calls
    assert_equal({ market: "ETH-USD", leverage: "1.0" }, api_client.patch_payload)
    assert_equal "1.0", result.receipt.dig(:readback_after_patch, :current_leverage)
    assert_equal "<redacted>", result.receipt.fetch(:patch_response).fetch("apiKey")
    assert_no_match(/secret|authorization|cookie|private/i, result.receipt.to_json)
  end

  test "failed readback remains unconfirmed" do
    api_client = fake_api_client(leverage_sequence: [ "10", "10" ])
    result = build_service(api_client: api_client, env: live_env).run(dry_run: false, confirmation: ExtendedSetLeverageCheck::CONFIRMATION)

    assert_equal "patch_submitted_but_readback_unconfirmed", result.status
    assert_equal 1, api_client.patch_calls
    assert_equal "10.0", result.receipt.dig(:readback_after_patch, :current_leverage)
  end

  private

  FakeApiClient = Struct.new(:leverage_sequence, :position_rows, :order_rows, :patch_response, :patch_calls, :patch_payload, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ position_rows: [], order_rows: [], patch_calls: 0 }.merge(kwargs))
    end

    def leverage(market:)
      value = leverage_sequence.size > 1 && patch_calls.positive? ? leverage_sequence.last : leverage_sequence.first
      { "data" => [ { "market" => market, "leverage" => value } ] }
    end

    def update_leverage(market:, leverage:)
      self.patch_calls += 1
      self.patch_payload = { market: market, leverage: leverage.to_s("F") }
      patch_response || { "status" => "OK" }
    end

    def positions(market:) = position_rows
    def open_orders(market:) = order_rows
    def balance = { "data" => { "equity" => "1999.79", "balance" => "1999.79" } }
    def account_info = { "status" => "ACTIVE" }
    def market(market:) = { "data" => { "name" => market, "tradingConfig" => { "minOrderSizeChange" => "0.001", "minPriceChange" => "0.1" } } }
    def fees(market:) = { "data" => [ { "market" => market, "takerFeeRate" => "0.0005" } ] }
  end

  def build_service(env: extended_env, api_client:)
    venue = HedgeVenues::Extended.new(env: env, api_client: api_client)
    ExtendedSetLeverageCheck.new(env: env, venue: venue)
  end

  def live_env
    extended_env.merge("EXTENDED_SET_LEVERAGE_ENABLED" => "true")
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
      "EXTENDED_REQUIRED_LEVERAGE" => "1"
    }
  end

  def fake_api_client(**kwargs)
    kwargs[:position_rows] = kwargs.delete(:positions) if kwargs.key?(:positions)
    kwargs[:order_rows] = kwargs.delete(:open_orders) if kwargs.key?(:open_orders)
    FakeApiClient.new(**kwargs)
  end
end
