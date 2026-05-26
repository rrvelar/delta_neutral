require "test_helper"

class ExtendedAutoReadinessTest < ActiveSupport::TestCase
  FakeHedge = Struct.new(:id, :target, :tolerance, :execution_venue, keyword_init: true)
  FakePosition = Struct.new(:id, :hedge, keyword_init: true) do
    def active? = true
    def mellow_autopilot? = true
    def hedge_ready? = true
    def position_source = Position::SOURCE_MELLOW_AUTOPILOT
    def mellow_metadata_hash = { "hedge_ready" => true, "last_probe_confidence" => "high" }
    def mellow_weth_exposure = BigDecimal("0.5")
    def mellow_usdc_exposure = BigDecimal("500")
    def mellow_current_value_usd = BigDecimal("1500")
    def entry_value_usd = BigDecimal("1500")
  end

  test "readiness passes only when post-migration gates are clear" do
    result = build_service.report(position: fake_position)

    assert_equal true, result.fetch(:continuous_auto_ready), result.fetch(:blockers).inspect
    assert_equal "extended", result.fetch(:execution_venue)
    assert_equal "0.5", result.fetch(:target_short_eth)
    assert_equal "0.5", result.fetch(:extended_current_short_eth)
    assert_equal "0.0", result.fetch(:ethereal_short_eth)
    assert_equal "0.0", result.fetch(:nado_short_eth)
    assert_equal true, result.fetch(:ethereal_flat)
    assert_equal true, result.fetch(:nado_flat)
    assert_equal true, result.fetch(:extended_auto_rebalance_enabled)
    assert_equal true, result.fetch(:extended_live_enabled)
    assert_equal "no_op", result.fetch(:planned_auto_action)
    assert_equal "0.1", result.fetch(:auto_max_rebalance_size_eth)
    assert_equal false, result.fetch(:partial_auto_rebalance)
    assert_equal false, result.fetch(:auto_can_act)
  end

  test "readiness reports planned auto action and size when drift is outside tolerance" do
    result = build_service(extended_short: "0.44").report(position: fake_position)

    assert_equal true, result.fetch(:continuous_auto_ready), result.fetch(:blockers).inspect
    assert_equal true, result.fetch(:drift_outside_tolerance)
    assert_equal "increase_short", result.fetch(:planned_auto_action)
    assert_equal "0.06", result.fetch(:planned_auto_order_size_eth)
    assert_equal "0.1", result.fetch(:auto_max_rebalance_size_eth)
    assert_equal false, result.fetch(:partial_auto_rebalance)
    assert_equal true, result.fetch(:auto_can_act)
  end

  test "readiness blocks if Ethereal position exists" do
    result = build_service(ethereal_short: "0.01").report(position: fake_position)

    assert_equal false, result.fetch(:continuous_auto_ready)
    assert_includes result.fetch(:blockers), "Ethereal must be flat before Extended continuous auto"
  end

  test "readiness blocks if Nado position exists" do
    result = build_service(nado_short: "0.01").report(position: fake_position)

    assert_equal false, result.fetch(:continuous_auto_ready)
    assert_includes result.fetch(:blockers), "Nado must be flat before Extended continuous auto"
  end

  test "readiness blocks if signer is down" do
    result = build_service(signer: FakeSigner.new(ok: false)).report(position: fake_position)

    assert_equal false, result.fetch(:continuous_auto_ready)
    assert_includes result.fetch(:blockers), "Extended signer health must advertise Extended/sign_extended_order support"
  end

  test "readiness blocks if execution venue is not Extended" do
    result = build_service.report(position: fake_position(execution_venue: "ethereal"))

    assert_equal false, result.fetch(:continuous_auto_ready)
    assert_includes result.fetch(:blockers), "Position hedge execution_venue must be extended for Extended continuous auto"
  end

  private

  FakeSigner = Struct.new(:ok, :verified_algorithm, :signing_enabled, keyword_init: true) do
    def initialize(**kwargs)
      super(**{ ok: true, verified_algorithm: true, signing_enabled: true }.merge(kwargs))
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
    def initialize(short: "0.5", margin_blockers: [])
      @short = BigDecimal(short.to_s)
      @margin_blockers = margin_blockers
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
  end

  FakeVenue = Struct.new(:short, keyword_init: true) do
    def read_position(symbol: nil)
      value = BigDecimal(short.to_s)
      return nil if value.zero?

      { side: "short", short_size: value.to_s("F"), size: -value }
    end
  end

  def build_service(env: readiness_env, extended_short: "0.5", ethereal_short: "0", nado_short: "0", signer: FakeSigner.new)
    ExtendedAutoReadiness.new(
      env: env,
      extended_venue: FakeExtendedVenue.new(short: extended_short),
      ethereal_service: FakeVenue.new(short: ethereal_short),
      nado_venue: FakeVenue.new(short: nado_short),
      signer_client: signer
    )
  end

  def fake_position(execution_venue: "extended")
    hedge = FakeHedge.new(id: 3, target: BigDecimal("1.0"), tolerance: BigDecimal("0.05"), execution_venue: execution_venue)
    FakePosition.new(id: 3, hedge: hedge)
  end

  def readiness_env
    {
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "true",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED" => "true"
    }
  end
end
