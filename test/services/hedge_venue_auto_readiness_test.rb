require "test_helper"

class HedgeVenueAutoReadinessTest < ActiveSupport::TestCase
  test "chooses Extended adapter when execution venue is extended" do
    readiness = HedgeVenueAutoReadiness.new(adapters: { "extended" => StaticAdapter.new("extended") }).report(position: position("extended"))

    assert_equal "extended", readiness.fetch(:active_auto_venue)
  end

  test "chooses Ethereal adapter when execution venue is ethereal" do
    readiness = HedgeVenueAutoReadiness.new(adapters: { "ethereal" => StaticAdapter.new("ethereal") }).report(position: position("ethereal"))

    assert_equal "ethereal", readiness.fetch(:active_auto_venue)
  end

  test "chooses Nado adapter when execution venue is nado" do
    readiness = HedgeVenueAutoReadiness.new(adapters: { "nado" => StaticAdapter.new("nado") }).report(position: position("nado"))

    assert_equal "nado", readiness.fetch(:active_auto_venue)
  end

  test "blocks unknown venue" do
    readiness = HedgeVenueAutoReadiness.new(adapters: {}).report(position: position("unknown"))

    assert_equal false, readiness.fetch(:continuous_auto_ready)
    assert_includes readiness.fetch(:blockers), "Unsupported hedge execution_venue \"hyperliquid\""
  end

  test "Ethereal adapter computes no-op inside tolerance" do
    report = ethereal_adapter(current_short: "0.99", target: "1.0").readiness(position: position("ethereal"))

    assert_equal "no_op", report.fetch(:planned_auto_action)
    assert_equal true, report.fetch(:within_tolerance)
  end

  test "Ethereal adapter computes increase short sell non reduce-only" do
    report = ethereal_adapter(current_short: "0.90", target: "1.0").readiness(position: position("ethereal"))

    assert_equal "increase_short", report.fetch(:planned_auto_action)
    assert_equal "sell", report.fetch(:side)
    assert_equal false, report.fetch(:reduce_only)
  end

  test "Ethereal adapter computes decrease short buy reduce-only" do
    report = ethereal_adapter(current_short: "1.10", target: "1.0").readiness(position: position("ethereal"))

    assert_equal "decrease_short", report.fetch(:planned_auto_action)
    assert_equal "buy", report.fetch(:side)
    assert_equal true, report.fetch(:reduce_only)
  end

  test "Ethereal blocks when Extended is not flat" do
    report = ethereal_adapter(current_short: "1.0", extended_short: "0.1").readiness(position: position("ethereal"))

    assert_includes report.fetch(:blockers), "Extended must be flat before Ethereal continuous auto"
  end

  test "Ethereal blocks when migration gate is enabled" do
    report = ethereal_adapter(env: ready_env.merge("MIGRATION_LIVE_ENABLED" => "true")).readiness(position: position("ethereal"))

    assert_includes report.fetch(:blockers), "MIGRATION_LIVE_ENABLED must be false during continuous auto"
  end

  test "Ethereal blocks live when auto gate disabled but reports inside tolerance" do
    report = ethereal_adapter(env: ready_env.merge("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"), current_short: "1.0").readiness(position: position("ethereal"))

    assert_equal true, report.fetch(:within_tolerance)
    assert_includes report.fetch(:blockers), "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true"
  end

  test "Nado adapter fails closed with missing capabilities" do
    report = HedgeVenueAutoAdapters::Nado.new(
      env: ready_env,
      nado_venue: FakeVenue.new(short: "1.0"),
      extended_venue: FakeVenue.new(short: "0"),
      ethereal_service: FakeService.new(short: "0"),
      fresh_target_factory: ->(_position) { FreshTarget.new("1.0") }
    ).readiness(position: position("nado"))

    assert_equal false, report.fetch(:continuous_auto_ready)
    assert report.fetch(:blockers).any? { |blocker| blocker.include?("Nado isolated live auto open/increase submit path") }
  end

  private

  def ethereal_adapter(env: ready_env, current_short: "1.0", target: "1.0", extended_short: "0", nado_short: "0")
    HedgeVenueAutoAdapters::Ethereal.new(
      env: env,
      ethereal_service: FakeService.new(short: current_short),
      extended_venue: FakeVenue.new(short: extended_short),
      nado_venue: FakeVenue.new(short: nado_short),
      fresh_target_factory: ->(_position) { FreshTarget.new(target) }
    )
  end

  def ready_env
    {
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def position(venue)
    current = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    hedge = current.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    hedge.update_column(:execution_venue, venue) unless venue == "extended"
    current
  end

  class StaticAdapter
    def initialize(venue)
      @venue = venue
    end

    def readiness(position:)
      { active_auto_venue: @venue, continuous_auto_ready: true, blockers: [], orders_submitted: 0, signatures_created: 0 }
    end
  end

  class FreshTarget
    def initialize(target)
      @target = target
    end

    def resolve(refresh_if_stale:)
      {
        status: "ok",
        target_short_eth: BigDecimal(@target),
        target_source: "test",
        exposure_source: "test",
        exposure_stale: false,
        blockers: []
      }
    end
  end

  class FakeService
    def initialize(short:)
      @venue = FakeVenue.new(short: short)
    end

    def read_position
      @venue.read_position(symbol: "ETH")
    end
  end

  class FakeVenue
    def initialize(short:)
      @short = BigDecimal(short)
    end

    def read_position(symbol:)
      return nil if @short.zero?

      { side: "short", short_size: @short.to_s("F"), margin_mode: "cross" }
    end

    def account_state
      { open_orders_count: 0 }
    end
  end
end
