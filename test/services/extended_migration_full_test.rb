require "test_helper"

class ExtendedMigrationFullTest < ActiveSupport::TestCase
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

  test "dry-run full migration plans Extended sell then Ethereal reduce-only buy" do
    result = build_service.run(position: fake_position, dry_run: true)

    assert_equal "dry_run", result.status
    assert_equal "sell", result.receipt.fetch(:planned_extended_leg).fetch(:side)
    assert_equal false, result.receipt.fetch(:planned_extended_leg).fetch(:reduce_only)
    assert_equal "buy", result.receipt.fetch(:planned_ethereal_leg).fetch(:side)
    assert_equal true, result.receipt.fetch(:planned_ethereal_leg).fetch(:reduce_only)
    assert_equal "0.25", result.receipt.fetch(:extended_add_size)
    assert_equal "0.25", result.receipt.fetch(:ethereal_reduce_size)
    assert_equal "0.25", result.receipt.fetch(:extended_short_expected_after)
    assert_equal "0.0", result.receipt.fetch(:ethereal_short_expected_after)
    assert_equal "0.25", result.receipt.fetch(:combined_short_expected_after)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:submitted)
  end

  test "live blocks without full migration gate" do
    signer = FakeSigner.new
    extended = FakeExtendedVenue.new(short: "0")
    result = build_service(env: live_env.except("EXTENDED_MIGRATION_FULL_ENABLED"), extended_venue: extended, signer: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "EXTENDED_MIGRATION_FULL_ENABLED must be true"
    assert_equal 0, signer.sign_calls
    assert_equal 0, extended.submit_calls
  end

  test "live blocks if Ethereal auto is enabled" do
    signer = FakeSigner.new
    result = build_service(env: live_env.merge("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "true"), signer: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Disable Ethereal auto-rebalance before full migration; otherwise Ethereal may fight the migration."
    assert_equal true, result.receipt.fetch(:ethereal_auto_enabled)
    assert_equal 0, signer.sign_calls
  end

  test "live blocks without confirmation" do
    signer = FakeSigner.new
    result = build_service(signer: signer).run(position: fake_position, dry_run: false, confirmation: "wrong")

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{ExtendedMigrationFull::CONFIRMATION}"
    assert_equal 0, signer.sign_calls
  end

  test "live blocks if Nado position exists" do
    signer = FakeSigner.new
    result = build_service(nado_position: { side: "short", short_size: "0.01" }, signer: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "current Nado position must be flat before migration_full"
    assert_equal 0, signer.sign_calls
  end

  test "live blocks if Extended leverage gate fails" do
    extended = FakeExtendedVenue.new(short: "0", margin_blockers: [ "Extended current leverage 10.0 does not match required 1.0x. Run extended:set_leverage dry_run=true." ])
    signer = FakeSigner.new
    result = build_service(extended_venue: extended, signer: signer).run(position: fake_position, dry_run: false, confirmation: ExtendedMigrationFull::CONFIRMATION)

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended current leverage 10.0 does not match required 1.0x. Run extended:set_leverage dry_run=true."
    assert_equal 0, signer.sign_calls
  end

  test "live blocks if signer is unhealthy" do
    signer = FakeSigner.new(ok: false)
    result = build_service(signer: signer).run(position: fake_position, dry_run: false, confirmation: ExtendedMigrationFull::CONFIRMATION)

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "Extended signer health must advertise Extended/sign_extended_order support"
    assert_equal 0, signer.sign_calls
  end

  test "mocked live success submits exactly two orders" do
    signer = FakeSigner.new
    extended = FakeExtendedVenue.new(short: "0")
    ethereal = FakeEtherealService.new(short: "0.25")
    result = build_service(extended_venue: extended, ethereal_service: ethereal, signer: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 1, signer.sign_calls
    assert_equal 1, extended.submit_calls
    assert_equal 1, ethereal.submit_calls
    assert_equal 2, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal "0.25", result.receipt.fetch(:extended_short_after)
    assert_equal "0.0", result.receipt.fetch(:ethereal_short_after)
    assert_equal "0.25", result.receipt.fetch(:combined_short_after)
    assert_equal "0.0", result.receipt.fetch(:combined_delta_after)
  end

  test "if Extended leg fails Ethereal leg is not submitted" do
    signer = FakeSigner.new
    extended = FakeExtendedVenue.new(short: "0")
    ethereal = FakeEtherealService.new(short: "0.25")
    result = build_service(extended_venue: extended, ethereal_service: ethereal, signer: signer, lifecycle_status: "submitted_but_readback_pending").run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "blocked_or_extended_not_confirmed", result.status
    assert_equal 1, signer.sign_calls
    assert_equal 1, extended.submit_calls
    assert_equal 0, ethereal.submit_calls
  end

  test "Ethereal failure after Extended success requires manual action" do
    signer = FakeSigner.new
    extended = FakeExtendedVenue.new(short: "0")
    ethereal = FakeEtherealService.new(short: "0.25", status: "submitted_but_readback_pending")
    result = build_service(extended_venue: extended, ethereal_service: ethereal, signer: signer).run(
      position: fake_position,
      dry_run: false,
      confirmation: ExtendedMigrationFull::CONFIRMATION
    )

    assert_equal "partial_migration_manual_action_required", result.status
    assert_equal 1, extended.submit_calls
    assert_equal 1, ethereal.submit_calls
    assert_includes result.receipt.fetch(:warnings), "Extended leg confirmed but Ethereal leg did not; total hedge may be temporarily over target by the Ethereal reduce size."
  end

  test "receipts redact secrets" do
    result = build_service(signer: FakeSigner.new).run(position: fake_position, dry_run: false, confirmation: ExtendedMigrationFull::CONFIRMATION)

    assert_no_match(/0xsignature|api-secret|authorization|cookie|private/i, result.receipt.to_json)
  end

  test "finalize remains separate after full migration success" do
    position = fake_position
    result = build_service.run(position: position, dry_run: false, confirmation: ExtendedMigrationFull::CONFIRMATION)

    assert_equal "success", result.status
    assert_equal "ethereal", position.hedge.execution_venue
  end

  private

  FakeSigner = Struct.new(:ok, :verified_algorithm, :signing_enabled, :sign_calls, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ ok: true, verified_algorithm: true, signing_enabled: true, sign_calls: 0 }.merge(kwargs))
    end

    def health
      {
        ok: ok,
        supported_exchanges: ok ? [ "Extended" ] : [],
        supported_actions: ok ? [ "sign_extended_order" ] : [],
        verified_algorithm: verified_algorithm,
        signing_enabled: signing_enabled
      }.with_indifferent_access
    end
  end

  class FakeExtendedVenue
    attr_reader :submit_calls

    def initialize(short:, margin_blockers: [])
      @short = BigDecimal(short.to_s)
      @margin_blockers = margin_blockers
      @submit_calls = 0
    end

    def read_position(symbol:)
      return nil if @short.zero?

      { side: "short", short_size: @short.to_s("F"), size: -@short }
    end

    def account_state
      {
        open_orders_count: 0,
        market_metadata_available: true,
        margin_gate: { status: @margin_blockers.empty? ? "pass" : "blocked", blockers: @margin_blockers },
        account_value_usd: "1999",
        collateral_usd: "1999"
      }
    end

    def market_metadata_diagnostics = { min_size: "0.01" }

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      payload("open_short", "sell", "SELL", false, size_eth)
    end

    def rebalance_preview(symbol:, delta_eth:, max_slippage:)
      payload("increase_short", "sell", "SELL", false, delta_eth)
    end

    def apply_extended_size(size)
      @submit_calls += 1
      @short += BigDecimal(size.to_s)
    end

    private

    def payload(action, side, extended_side, reduce_only, size)
      { payload: { action: action, side: side, extended_side: extended_side, reduce_only: reduce_only, requested_size_eth: BigDecimal(size.to_s).to_s("F"), rounded_size_eth: BigDecimal(size.to_s).to_s("F"), validation_blockers: [] }, blockers: [] }
    end
  end

  class FakeEtherealService
    attr_reader :submit_calls

    def initialize(short:, status: "submitted_and_confirmed")
      @short = BigDecimal(short.to_s)
      @status = status
      @submit_calls = 0
    end

    def read_position
      return nil if @short.zero?

      { side: "short", short_size: @short.to_s("F"), size: -@short, margin_mode: "cross" }
    end

    def build_order_preview(position:, action:, size_eth:, current_position:, max_slippage:)
      size = BigDecimal(size_eth.to_s).abs
      { summary: { side: "buy", reduce_only: true, rounded_size_eth: size.to_s("F"), expected_after_short_eth: [ @short - size, BigDecimal("0") ].max.to_s("F"), estimated_notional_usd: "20" }, blockers: [], warnings: [] }
    end

    def auto_rebalance_short(position:, delta_eth:, current_position:, max_slippage:)
      @submit_calls += 1
      size = BigDecimal(delta_eth.to_s).abs
      @short = [ @short - size, BigDecimal("0") ].max if @status == "submitted_and_confirmed"
      EtherealHedgeExecutionService::Result.new(@status, [], [], {
        final_status: @status,
        submitted_order_summary: { side: "buy", reduce_only: true, rounded_size_eth: size.to_s("F") },
        exchange_order_id: "ethereal-order",
        post_submit_readback: read_position
      })
    end
  end

  FakeNadoVenue = Struct.new(:position, keyword_init: true) do
    def read_position(symbol:)
      position
    end
  end

  class FakeExtendedLifecycle
    def initialize(venue, signer, status)
      @venue = venue
      @signer = signer
      @status = status
    end

    def run(position:, mode:, size_eth:, delta_eth:, confirmation:, dry_run:, max_slippage:)
      @signer.sign_calls += 1
      @venue.apply_extended_size(size_eth)
      ExtendedMainnetLifecycleCheck::Result.new(@status, [], [], {
        final_status: @status,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "extended-order",
        readback_attempts: [ { attempt: 1, short_size: BigDecimal(size_eth.to_s).to_s("F"), confirmed: @status == "success" } ],
        submit_payload: { "settlement" => { "signature" => "0xsignature" } },
        submit_response: { "data" => { "apiKey" => "api-secret" } },
        signer_response: { "settlement" => { "signature" => "0xsignature" } }
      })
    end
  end

  def build_service(env: live_env, extended_venue: FakeExtendedVenue.new(short: "0"), ethereal_service: FakeEtherealService.new(short: "0.25"), nado_position: nil, signer: FakeSigner.new, lifecycle_status: "success")
    ExtendedMigrationFull.new(
      env: env,
      extended_venue: extended_venue,
      nado_venue: FakeNadoVenue.new(position: nado_position),
      ethereal_service: ethereal_service,
      signer_client: signer,
      extended_lifecycle_factory: ->(_) { FakeExtendedLifecycle.new(extended_venue, signer, lifecycle_status) },
      sleeper: ->(_) { }
    )
  end

  def fake_position(execution_venue: "ethereal")
    hedge = FakeHedge.new(id: 3, target: BigDecimal("1.0"), tolerance: BigDecimal("0.05"), execution_venue: execution_venue)
    FakePosition.new(id: 3, hedge: hedge, asset0_price_usd: BigDecimal("2120"))
  end

  def live_env
    {
      "EXTENDED_MIGRATION_FULL_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true"
    }
  end
end
