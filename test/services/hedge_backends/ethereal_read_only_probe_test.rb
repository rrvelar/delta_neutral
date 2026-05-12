require "test_helper"

class HedgeBackendsEtherealReadOnlyProbeTest < ActiveSupport::TestCase
  API_BASE = "https://ethereal.example".freeze
  PRODUCT_ID = "9036443a-441a-4a66-87f2-bd5c44cdca7a".freeze
  SUBACCOUNT_ID = "c25c39d9-ce2b-4753-960c-c5ad558aace8".freeze

  test "disabled probe is blocked without HTTP calls" do
    probe = HedgeBackends::EtherealReadOnlyProbe.new(env: { "ETHEREAL_READ_ONLY_ENABLED" => "false" })

    result = probe.run_probe.to_h

    assert_equal "BLOCKED", result.fetch(:status)
    assert_equal false, result.fetch(:orders_enabled)
    assert_equal false, result.fetch(:hyperliquid_execution)
    assert_empty WebMock::RequestRegistry.instance.requested_signatures.hash
  end

  test "enabled probe without api base is blocked with configuration error" do
    probe = HedgeBackends::EtherealReadOnlyProbe.new(env: { "ETHEREAL_READ_ONLY_ENABLED" => "true" })

    result = probe.run_probe.to_h

    assert_equal "BLOCKED", result.fetch(:status)
    assert_match "ETHEREAL_API_BASE_URL", result.fetch(:errors).first.fetch(:message)
  end

  test "market metadata normalizes documented product fields" do
    stub_product
    probe = enabled_probe

    metadata = probe.market_metadata

    assert_equal "ok", metadata.result_status
    assert_equal "ACTIVE", metadata.status
    assert_equal BigDecimal("0.001"), metadata.lot_size
    assert_equal BigDecimal("0.1"), metadata.tick_size
    assert_equal BigDecimal("0.01"), metadata.min_order_size
    assert_nil metadata.min_notional_usd
    assert_equal "USDe", metadata.collateral
  end

  test "mark price normalizes oracle price" do
    stub_product
    stub_market_price
    probe = enabled_probe

    price = probe.get_mark_price

    assert_equal "ok", price.fetch(:status)
    assert_equal "2500.5", price.fetch(:mark_price)
  end

  test "position normalizes short side as negative signed size" do
    stub_product
    stub_market_price
    stub_request(:get, "#{API_BASE}/v1/position/active")
      .with(query: { subaccountId: SUBACCOUNT_ID, productId: PRODUCT_ID })
      .to_return(status: 200, body: { data: {
        id: "pos-1",
        size: "0.42",
        side: 1,
        cost: "-1050",
        unrealizedPnl: "12.5",
        liquidationPrice: "4000"
      } }.to_json)

    position = enabled_probe.get_position

    assert_equal "ok", position.status
    assert_equal BigDecimal("-0.42"), position.signed_size
    assert_equal BigDecimal("0.42"), position.short_size
    assert_equal BigDecimal("2500.5"), position.mark_price
  end

  test "position returns unsupported without subaccount id" do
    probe = enabled_probe("ETHEREAL_SUBACCOUNT_ID" => nil)

    position = probe.get_position

    assert_equal "unsupported", position.status
    assert_match "ETHEREAL_SUBACCOUNT_ID", position.raw.fetch(:message)
  end

  test "empty active position returns zero position" do
    stub_product
    stub_request(:get, "#{API_BASE}/v1/position/active")
      .with(query: { subaccountId: SUBACCOUNT_ID, productId: PRODUCT_ID })
      .to_return(status: 200, body: { data: nil }.to_json)

    position = enabled_probe.get_position

    assert_equal BigDecimal("0"), position.signed_size
    assert_equal BigDecimal("0"), position.short_size
  end

  test "account health normalizes documented subaccount balance fields" do
    stub_request(:get, "#{API_BASE}/v1/subaccount/balance")
      .with(query: { subaccountId: SUBACCOUNT_ID })
      .to_return(status: 200, body: { data: [
        { subaccountId: SUBACCOUNT_ID, tokenName: "USDe", amount: "1000", available: "700", totalUsed: "300" }
      ] }.to_json)

    health = enabled_probe.account_health

    assert_equal "ok", health.status
    assert_equal "USDe", health.collateral
    assert_equal BigDecimal("1000"), health.account_value_usd
    assert_equal BigDecimal("300"), health.margin_used_usd
  end

  test "timeout raises typed network error" do
    stub_request(:get, "#{API_BASE}/v1/product")
      .with(query: { ticker: "ETHUSD", limit: "100" })
      .to_timeout

    assert_raises(HedgeBackends::NetworkError) { enabled_probe.market_metadata }
  end

  test "rate limit raises typed rate limit error" do
    stub_request(:get, "#{API_BASE}/v1/product")
      .with(query: { ticker: "ETHUSD", limit: "100" })
      .to_return(status: 429, body: "rate limited")

    assert_raises(HedgeBackends::RateLimitError) { enabled_probe.market_metadata }
  end

  test "invalid JSON raises typed parse error" do
    stub_request(:get, "#{API_BASE}/v1/product")
      .with(query: { ticker: "ETHUSD", limit: "100" })
      .to_return(status: 200, body: "not json")

    assert_raises(HedgeBackends::ParseError) { enabled_probe.market_metadata }
  end

  test "unknown product shape stays unsupported instead of success" do
    stub_request(:get, "#{API_BASE}/v1/product")
      .with(query: { ticker: "ETHUSD", limit: "100" })
      .to_return(status: 200, body: { data: [] }.to_json)

    metadata = enabled_probe.market_metadata

    assert_equal "unsupported", metadata.result_status
  end

  test "ethereal probe is not referenced by production execution files" do
    production_files = %w[
      app/services/hyperliquid_service.rb
      app/jobs/hedge_sync_job.rb
      app/services/aerodrome_production_live_runner.rb
      app/services/aerodrome_live_emergency_close.rb
      app/services/aerodrome_approved_open_position.rb
      app/services/aerodrome_watchdog_check.rb
    ]

    production_files.each do |path|
      assert_no_match "EtherealReadOnlyProbe", Rails.root.join(path).read, "#{path} must not wire Ethereal into production"
    end
  end

  private

  def enabled_probe(overrides = {})
    env = {
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => API_BASE,
      "ETHEREAL_MARKET_SYMBOL" => "ETH-USD",
      "ETHEREAL_SUBACCOUNT_ID" => SUBACCOUNT_ID
    }.merge(overrides).compact
    HedgeBackends::EtherealReadOnlyProbe.new(env: env)
  end

  def stub_product
    stub_request(:get, "#{API_BASE}/v1/product")
      .with(query: { ticker: "ETHUSD", limit: "100" })
      .to_return(status: 200, body: { data: [ {
        id: PRODUCT_ID,
        ticker: "ETHUSD",
        displayTicker: "ETH-USD",
        baseTokenName: "ETH",
        quoteTokenName: "USDe",
        status: "ACTIVE",
        minQuantity: "0.01",
        lotSize: "0.001",
        tickSize: "0.1",
        maxLeverage: "20"
      } ] }.to_json)
  end

  def stub_market_price
    stub_request(:get, "#{API_BASE}/v1/product/market-price")
      .with(query: { productIds: PRODUCT_ID })
      .to_return(status: 200, body: { data: [ {
        productId: PRODUCT_ID,
        oraclePrice: "2500.5",
        bestBidPrice: "2500.4",
        bestAskPrice: "2500.6"
      } ] }.to_json)
  end
end
