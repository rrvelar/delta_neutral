require "test_helper"

class ExtendedMainnetLifecycleCheckTest < ActiveSupport::TestCase
  FakeHedge = Struct.new(:target, keyword_init: true) do
    def id = 7
    def extended_execution? = true
  end
  FakePosition = Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
    def active? = true
    def mellow_autopilot? = true
    def hedge_ready? = true
    def mellow_weth_exposure = BigDecimal("0.5")
  end

  test "live mode refuses without probe gate and confirmation" do
    result = build_service.run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.005",
      confirmation: "wrong",
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_MAINNET_PROBE_ENABLED must be true"
    assert_includes result.blockers, "EXTENDED_LIVE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedMainnetLifecycleCheck::CONFIRMATION}"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_no_match(/api-secret|stark-private|authorization|cookie/i, result.receipt.to_json)
  end

  test "live mode refuses without signer health even when gates are present" do
    signer = Struct.new(:health, keyword_init: true) do
      def supports_extended_order_signing? = false
    end.new(health: { ok: false, reason: "disabled" })
    service = build_service(
      env: extended_env.merge(
        "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
        "EXTENDED_LIVE_ENABLED" => "true",
        "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid"
      ),
      signer_client: signer
    )

    result = service.run(
      position: fake_position,
      mode: "open_only",
      size_eth: "0.005",
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_includes result.blockers, "Extended Stark signer verified_algorithm=false"
    assert_includes result.blockers, "Extended submit endpoint integration not implemented."
  end

  test "dry run builds lifecycle payloads and submits nothing" do
    result = build_service.run(
      position: fake_position,
      mode: "delta_round_trip",
      size_eth: "0.005",
      confirmation: nil,
      dry_run: true
    )

    summaries = result.receipt.fetch(:order_payload_summaries)
    assert_equal "dry_run", result.status
    assert_equal [ "buy", "sell" ], summaries.map { |summary| summary.fetch(:side) }
    assert_equal [ true, false ], summaries.map { |summary| summary.fetch(:reduce_only) }
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  private

  def build_service(env: extended_env, signer_client: nil)
    venue = HedgeVenues::Extended.new(env: env, api_client: fake_api_client)
    signer_client ||= Struct.new(:health, keyword_init: true) do
      def supports_extended_order_signing? = false
      def verified_algorithm? = false
    end.new(health: { ok: false, reason: "not configured" })
    ExtendedMainnetLifecycleCheck.new(env: env, venue: venue, signer_client: signer_client)
  end

  def fake_position
    FakePosition.new(id: 3, hedge: FakeHedge.new(target: BigDecimal("1.0")), asset0_price_usd: BigDecimal("2100"))
  end

  def fake_api_client
    Class.new do
      def positions(market:)
        [ { market: market, side: "SHORT", size: "0.25", value: "525", openPrice: "2120", markPrice: "2100", unrealisedPnl: "5", status: "OPEN" } ]
      end

      def balance = { equity: "5000", balance: "5000" }
      def account_info = { status: "ACTIVE", accountId: "acct" }
      def market(market:) = { name: market, active: true }
      def open_orders(market:) = []
    end.new
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
      "EXTENDED_SIZE_INCREMENT" => "0.0001",
      "EXTENDED_PRICE_INCREMENT" => "0.1"
    }
  end
end
