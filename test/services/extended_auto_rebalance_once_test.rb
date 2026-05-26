require "test_helper"

class ExtendedAutoRebalanceOnceTest < ActiveSupport::TestCase
  FakeHedge = Struct.new(:id, :target, :tolerance, :execution_venue, keyword_init: true)
  FakePosition = Struct.new(:id, :hedge, :asset0_price_usd, keyword_init: true) do
    def active? = true
    def mellow_autopilot? = true
    def hedge_ready? = true
    def position_source = Position::SOURCE_MELLOW_AUTOPILOT
    def mellow_metadata_hash = { "hedge_ready" => true, "last_probe_confidence" => "high" }
    def mellow_current_value_usd = BigDecimal("1000")
    def entry_value_usd = BigDecimal("1000")
    def mellow_weth_exposure = BigDecimal("0.25")
    def mellow_usdc_exposure = BigDecimal("470")
  end

  test "dry-run no-ops when drift is within tolerance" do
    result = build_service(api_client: api_client(before_positions: [ extended_short("0.245") ])).run(position: fake_position, dry_run: true)

    assert_equal "dry_run", result.status
    assert_equal "no_op", result.receipt.fetch(:intended_action)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  test "dry-run increase builds sell non reduce-only order" do
    result = build_service(api_client: api_client(before_positions: [ extended_short("0.20") ])).run(position: fake_position, dry_run: true)

    order = result.receipt.fetch(:intended_order)
    assert_equal "increase_short", result.receipt.fetch(:intended_action)
    assert_equal "SELL", order.fetch(:extended_side)
    assert_equal "sell", order.fetch(:side)
    assert_equal false, order.fetch(:reduce_only)
    assert_equal "0.05", order.fetch(:rounded_size_eth)
  end

  test "dry-run decrease builds buy reduce-only order" do
    result = build_service(api_client: api_client(before_positions: [ extended_short("0.3") ])).run(position: fake_position, dry_run: true)

    order = result.receipt.fetch(:intended_order)
    assert_equal "decrease_short", result.receipt.fetch(:intended_action)
    assert_equal "BUY", order.fetch(:extended_side)
    assert_equal "buy", order.fetch(:side)
    assert_equal true, order.fetch(:reduce_only)
    assert_equal "0.05", order.fetch(:rounded_size_eth)
  end

  test "live one-shot blocks without one-shot gate before signing" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env.except("EXTENDED_ONE_SHOT_REBALANCE_ENABLED"), api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_ONE_SHOT_REBALANCE_ENABLED must be true"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks without exact confirmation" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(position: fake_position, dry_run: false, confirmation: "wrong")

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedAutoRebalanceOnce::CONFIRMATION}"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when leverage is not one" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], leverage_payload: { "data" => [ { "market" => "ETH-USD", "leverage" => "10" } ] })

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended current leverage 10.0 does not match required 1.0x. Run extended:set_leverage dry_run=true."
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when isolated-equivalent is not confirmed" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env.merge("EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "false"), api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED must be true"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when signer is unhealthy" do
    signer = CountingSigner.new(ok: false, verified_algorithm: false, signing_enabled: false)
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when open orders exist" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], open_orders: [ { "id" => "order-1" } ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended one-shot requires open_orders_count=0"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "flat Extended with large target blocks full one-shot above cap before signing" do
    signer = CountingSigner.new
    client = api_client(before_positions: [])

    result = build_service(env: live_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH"), api_client: client, signer_client: signer).run(
      position: fake_position(target: "2.4"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_equal "0.6", result.receipt.fetch(:target_short_eth)
    assert_equal "0.6", result.receipt.fetch(:requested_order_size_eth)
    assert_equal "0.02", result.receipt.fetch(:cap_eth)
    assert_equal true, result.receipt.fetch(:cap_exceeded)
    assert_equal false, result.receipt.fetch(:partial_probe)
    assert_includes result.blockers, "EXTENDED_MIGRATION_REBALANCE_ENABLED must be true for full-target Extended one-shot migration"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "probe mode caps a large one-shot order and marks partial probe" do
    result = build_service(env: extended_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH"), api_client: api_client(before_positions: [])).run(
      position: fake_position(target: "2.4"),
      dry_run: true,
      mode: "probe_rebalance",
      max_size_eth: "0.01"
    )

    order = result.receipt.fetch(:intended_order)
    assert_equal "dry_run", result.status
    assert_equal "0.6", result.receipt.fetch(:raw_delta_eth)
    assert_equal "0.6", result.receipt.fetch(:requested_order_size_eth)
    assert_equal "0.01", result.receipt.fetch(:capped_order_size_eth)
    assert_equal "0.01", order.fetch(:rounded_size_eth)
    assert_equal true, result.receipt.fetch(:cap_exceeded)
    assert_equal true, result.receipt.fetch(:partial_probe)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  test "full migration requires migration gate and selected Extended venue" do
    signer = CountingSigner.new
    client = api_client(before_positions: [], after_positions: [ extended_short("0.6") ])

    result = build_service(
      env: live_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH").merge("EXTENDED_MIGRATION_REBALANCE_ENABLED" => "true"),
      api_client: client,
      signer_client: signer
    ).run(
      position: fake_position(target: "2.4"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal true, result.receipt.fetch(:migration_mode)
    assert_equal "0.6", client.submitted_payload.fetch("qty")
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
  end

  test "live one-shot blocks when Nado still has a short" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(
      env: live_env,
      api_client: client,
      signer_client: signer,
      nado_position: { short_size: "0.01", side: "short" }
    ).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Current Nado position must be flat before Extended live rebalance"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when hedge selected venue is not Extended" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position(execution_venue: "ethereal"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Position hedge execution_venue must be extended for Extended live rebalance"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "full one-shot with selected Ethereal venue remains blocked" do
    signer = CountingSigner.new
    client = api_client(before_positions: [])

    result = build_service(env: live_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH"), api_client: client, signer_client: signer).run(
      position: fake_position(target: "2.4", execution_venue: "ethereal"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_equal true, result.receipt.fetch(:cap_exceeded)
    assert_equal false, result.receipt.fetch(:partial_probe)
    assert_includes result.blockers, "Position hedge execution_venue must be extended for Extended live rebalance"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "probe rebalance with selected Ethereal venue passes selected venue gate and submits one capped order" do
    signer = CountingSigner.new
    client = api_client(before_positions: [], after_positions: [ extended_short("0.01") ])
    position = fake_position(target: "2.4", execution_venue: "ethereal")

    result = build_service(env: live_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH"), api_client: client, signer_client: signer).run(
      position: position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION,
      mode: "probe_rebalance",
      max_size_eth: "0.01"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_not_includes result.blockers, "Position hedge execution_venue must be extended for Extended live rebalance"
    assert_equal "ethereal", position.hedge.execution_venue
    assert_equal true, result.receipt.fetch(:probe_mode)
    assert_equal true, result.receipt.fetch(:partial_probe)
    assert_equal false, result.receipt.fetch(:migration_mode)
    assert_equal "ethereal", result.receipt.fetch(:selected_hedge_venue)
    assert_equal "0.01", result.receipt.fetch(:capped_order_size_eth)
    assert_equal "0.01", result.receipt.fetch(:cap_eth)
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
    assert_equal "0.01", client.submitted_payload.fetch("qty")
  end

  test "probe rebalance blocks without signer before submit" do
    signer = CountingSigner.new(ok: false, verified_algorithm: true, signing_enabled: false)
    client = api_client(before_positions: [])

    result = build_service(env: live_env.except("EXTENDED_ONE_SHOT_MAX_SIZE_ETH"), api_client: client, signer_client: signer).run(
      position: fake_position(target: "2.4", execution_venue: "ethereal"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION,
      mode: "probe_rebalance",
      max_size_eth: "0.01"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_not_includes result.blockers, "Position hedge execution_venue must be extended for Extended live rebalance"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "probe rebalance blocks if target order is not partial" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position(tolerance: "0.001", execution_venue: "ethereal"),
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION,
      mode: "probe_rebalance",
      max_size_eth: "0.1"
    )

    assert_equal "blocked_before_submit", result.status
    assert_equal true, result.receipt.fetch(:probe_mode)
    assert_equal false, result.receipt.fetch(:partial_probe)
    assert_includes result.blockers, "Extended probe_rebalance must be a capped partial probe; full target orders require migration mode"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "live one-shot blocks when order size is below Extended min size" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.245") ])
    position = fake_position(tolerance: "0.001")

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "requested size 0.005 is below Extended min order size 0.01"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "mocked live one-shot submits exactly one order and requires readback confirmation" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], after_positions: [ extended_short("0.25") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal "SELL", client.submitted_payload.fetch("side")
    assert_equal false, client.submitted_payload.fetch("reduceOnly")
    assert_equal true, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "continuous auto with Extended venue submits full sell under auto cap" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], after_positions: [ extended_short("0.26") ])

    result = build_service(env: continuous_env.merge("EXTENDED_ONE_SHOT_MAX_SIZE_ETH" => "0.02"), api_client: client, signer_client: signer).run(
      position: fake_position(target: "1.04"),
      dry_run: false,
      one_shot: false
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal "continuous_auto", result.receipt.fetch(:source)
    assert_equal "0.06", result.receipt.fetch(:requested_order_size_eth)
    assert_equal "0.06", result.receipt.fetch(:capped_order_size_eth)
    assert_equal "0.1", result.receipt.fetch(:auto_max_rebalance_size_eth)
    assert_equal false, result.receipt.fetch(:partial_auto_rebalance)
    assert_not_includes result.blockers, "EXTENDED_MIGRATION_REBALANCE_ENABLED must be true for full-target Extended one-shot migration"
    assert_equal "SELL", client.submitted_payload.fetch("side")
    assert_equal false, client.submitted_payload.fetch("reduceOnly")
    assert_equal "0.06", client.submitted_payload.fetch("qty")
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
  end

  test "continuous auto caps large drift when partial auto is allowed" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], after_positions: [ extended_short("0.3") ])

    result = build_service(env: continuous_env, api_client: client, signer_client: signer).run(
      position: fake_position(target: "2.0"),
      dry_run: false,
      one_shot: false
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal true, result.receipt.fetch(:cap_exceeded)
    assert_equal true, result.receipt.fetch(:partial_auto_rebalance)
    assert_equal "0.3", result.receipt.fetch(:raw_delta_eth)
    assert_equal "0.1", result.receipt.fetch(:capped_order_size_eth)
    assert_equal "0.1", client.submitted_payload.fetch("qty")
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
  end

  test "continuous auto blocks large drift when partial auto is disabled" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: continuous_env.merge("EXTENDED_AUTO_ALLOW_PARTIAL_REBALANCE" => "false"), api_client: client, signer_client: signer).run(
      position: fake_position(target: "2.0"),
      dry_run: false,
      one_shot: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended continuous auto order size 0.3 exceeds EXTENDED_AUTO_MAX_REBALANCE_SIZE_ETH 0.1 and EXTENDED_AUTO_ALLOW_PARTIAL_REBALANCE is false"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "continuous auto blocks when selected venue is not Extended" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: continuous_env, api_client: client, signer_client: signer).run(
      position: fake_position(target: "1.04", execution_venue: "ethereal"),
      dry_run: false,
      one_shot: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Position hedge execution_venue must be extended for Extended live rebalance"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "continuous auto blocks when signer is unhealthy" do
    signer = CountingSigner.new(ok: false)
    client = api_client(before_positions: [ extended_short("0.20") ])

    result = build_service(env: continuous_env, api_client: client, signer_client: signer).run(
      position: fake_position(target: "1.04"),
      dry_run: false,
      one_shot: false
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_equal 0, signer.sign_calls
    assert_equal 0, client.submit_calls
  end

  test "mocked live one-shot remains pending when readback does not confirm and does not retry" do
    signer = CountingSigner.new
    client = api_client(before_positions: [ extended_short("0.20") ], after_positions: [ extended_short("0.20") ])

    result = build_service(env: live_env, api_client: client, signer_client: signer, sleeper: ->(_) { }).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "submitted_but_readback_pending", result.status, result.blockers.inspect
    assert_equal 1, signer.sign_calls
    assert_equal 1, client.submit_calls
    assert_equal false, result.receipt.fetch(:readback_attempts).any? { |attempt| attempt.fetch(:confirmed) }
  end

  test "receipts redact signatures api keys auth headers and private keys" do
    signer = CountingSigner.new
    client = api_client(
      before_positions: [ extended_short("0.20") ],
      after_positions: [ extended_short("0.25") ],
      submit_response: {
        "status" => "OK",
        "data" => {
          "id" => "abc123",
          "signature" => "0xechoed-signature",
          "apiKey" => "echoed-api-key",
          "authorization" => "Bearer secret",
          "cookie" => "session=secret",
          "privateKey" => "0xprivate"
        }
      }
    )

    result = build_service(env: live_env, api_client: client, signer_client: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedAutoRebalanceOnce::CONFIRMATION
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_no_match(/0xechoed-signature|echoed-api-key|Bearer secret|session=secret|0xprivate|0xsignature|api-secret/i, result.receipt.to_json)
  end

  private

  CountingSigner = Struct.new(:ok, :verified_algorithm, :signing_enabled, :sign_calls, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ ok: true, verified_algorithm: true, signing_enabled: true, sign_calls: 0 }.merge(kwargs))
    end

    def health
      {
        ok: ok,
        reason: ok ? "ok" : "disabled",
        supported_exchanges: ok ? [ "Extended" ] : [],
        supported_actions: ok ? [ "sign_extended_order" ] : [],
        verified_algorithm: verified_algorithm,
        signing_enabled: signing_enabled,
        stark_public_key: "0x1234...abcd"
      }.with_indifferent_access
    end

    def sign_order(order)
      self.sign_calls += 1
      {
        status: "signed",
        order_id: "signed-order-id",
        settlement: { signature: "0xsignature", starkKey: order.fetch("starkPublicKey"), collateralPosition: order.fetch("vault") },
        debuggingAmounts: { collateralAmount: "21200000", feeAmount: "10600", syntheticAmount: "-10000" }
      }.with_indifferent_access
    end
  end

  FakeNadoVenue = Struct.new(:position, keyword_init: true) do
    def read_position(symbol:)
      position
    end
  end

  def build_service(env: extended_env, api_client:, signer_client: CountingSigner.new, nado_position: nil, sleeper: ->(_) { })
    venue = HedgeVenues::Extended.new(env: env, api_client: api_client)
    ExtendedAutoRebalanceOnce.new(
      env: env,
      venue: venue,
      signer_client: signer_client,
      nado_venue: FakeNadoVenue.new(position: nado_position),
      sleeper: sleeper
    )
  end

  def fake_position(target: "1.0", tolerance: "0.05", execution_venue: "extended")
    hedge = FakeHedge.new(id: 3, target: BigDecimal(target), tolerance: BigDecimal(tolerance), execution_venue: execution_venue)
    FakePosition.new(id: 3, hedge: hedge, asset0_price_usd: BigDecimal("2120"))
  end

  def extended_short(size)
    { market: "ETH-USD", side: "SHORT", size: size, value: (BigDecimal(size) * BigDecimal("2120")).to_s("F"), openPrice: "2120", markPrice: "2120", status: "OPEN" }
  end

  def api_client(before_positions:, after_positions: before_positions, open_orders: [], leverage_payload: nil, submit_response: nil)
    Class.new do
      attr_reader :submit_calls, :submitted_payload

      define_method(:initialize) do |before_rows, after_rows, orders, leverage_response, response|
        @before_rows = before_rows
        @after_rows = after_rows
        @orders = orders
        @leverage_payload = leverage_response
        @submit_response = response
        @submit_calls = 0
      end

      def positions(market:)
        @submit_calls.positive? ? @after_rows : @before_rows
      end

      def balance = { "status" => "OK", "data" => { "equity" => "1999.79", "balance" => "1999.79" } }
      def account_info = { "status" => "ACTIVE", "data" => { "equity" => "1999.79", "balance" => "1999.79" } }
      def open_orders(market:) = @orders
      def leverage(market:) = @leverage_payload || { "data" => [ { "market" => market, "leverage" => "1" } ] }
      def fees(market:) = { "data" => [ { "market" => market, "takerFeeRate" => "0.0005" } ] }

      def market(market:)
        {
          data: {
            name: market,
            tradingConfig: { minOrderSize: "0.01", minOrderSizeChange: "0.001", minPriceChange: "0.1" },
            marketStats: { markPrice: "2120" },
            l2Config: {
              collateralId: "0x31857064564ed0ff978e687456963cba09c2c6985d8f9300a1de4962fafa054",
              syntheticId: "0x4554482d3800000000000000000000",
              collateralResolution: 1000000,
              syntheticResolution: 1000000
            }
          }
        }
      end

      def submit_order(payload)
        @submit_calls += 1
        @submitted_payload = payload
        @submit_response || { "status" => "OK", "data" => { "id" => "abc123" } }
      end
    end.new(before_positions, after_positions, open_orders, leverage_payload, submit_response)
  end

  def live_env
    extended_env.merge(
      "EXTENDED_ONE_SHOT_REBALANCE_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_REQUIRED_LEVERAGE" => "1",
      "EXTENDED_REQUIRED_MARGIN_MODE" => "isolated",
      "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true",
      "EXTENDED_SIGNER_URL" => "http://extended-signer.invalid",
      "EXTENDED_STARK_PUBLIC_KEY" => "0x1234...abcd",
      "EXTENDED_ONE_SHOT_MAX_SIZE_ETH" => "0.1"
    ).except("EXTENDED_SIZE_INCREMENT", "EXTENDED_PRICE_INCREMENT")
  end

  def continuous_env
    live_env.merge(
      "EXTENDED_ONE_SHOT_REBALANCE_ENABLED" => "false",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "true",
      "EXTENDED_AUTO_MAX_REBALANCE_SIZE_ETH" => "0.1"
    )
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
