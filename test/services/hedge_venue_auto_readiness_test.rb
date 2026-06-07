require "test_helper"

class HedgeVenueAutoReadinessTest < ActiveSupport::TestCase
  setup do
    OperationalSetting.delete_all
  end

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
    assert_includes readiness.fetch(:blockers), "Unsupported hedge execution_venue \"unknown\""
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

  test "Ethereal blocks while migration execution lock is held" do
    current_position = position("ethereal")

    MigrationExecutionLock.with_lock(current_position) do
      report = ethereal_adapter(env: ready_env.merge("MIGRATION_LIVE_ENABLED" => "true")).readiness(position: current_position)

      assert_includes report.fetch(:blockers), "migration is in progress for this position; continuous auto is paused"
      assert_not_includes report.fetch(:blockers), "MIGRATION_LIVE_ENABLED must be false during continuous auto"
    end
  end

  test "Ethereal blocks live when auto gate disabled but reports inside tolerance" do
    report = ethereal_adapter(env: ready_env.merge("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"), current_short: "1.0").readiness(position: position("ethereal"))

    assert_equal true, report.fetch(:within_tolerance)
    assert_includes report.fetch(:blockers), "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true"
  end

  test "Ethereal readiness uses DB auto override over env" do
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true)
    report = ethereal_adapter(env: ready_env.merge("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false"), current_short: "1.0").readiness(position: position("ethereal"))

    assert_equal true, report.fetch(:active_auto_enabled)
    assert_equal true, report.fetch(:continuous_auto_ready)
    assert_empty report.fetch(:blockers)
  end

  test "Ethereal blocks live auto when open orders readback is unavailable" do
    report = ethereal_adapter(open_orders_count: nil).readiness(position: position("ethereal"))

    assert_nil report[:open_orders_count]
    assert_includes report.fetch(:blockers), "Ethereal open orders readback unavailable; live auto fails closed"
  end

  test "Ethereal zero open orders clears unavailable blocker" do
    report = ethereal_adapter(open_orders_count: 0).readiness(position: position("ethereal"))

    assert_equal 0, report.fetch(:open_orders_count)
    assert_not_includes report.fetch(:blockers), "Ethereal open orders readback unavailable; live auto fails closed"
    assert_not report.fetch(:blockers).any? { |blocker| blocker.include?("open_orders_count=0") }
  end

  test "Ethereal open orders count greater than zero blocks" do
    report = ethereal_adapter(open_orders_count: 2).readiness(position: position("ethereal"))

    assert_equal 2, report.fetch(:open_orders_count)
    assert_includes report.fetch(:blockers), "Ethereal auto requires open_orders_count=0"
  end

  test "Nado adapter computes no-op inside tolerance" do
    report = nado_adapter(current_short: "0.99", target: "1.0").readiness(position: position("nado"))

    assert_equal "no_op", report.fetch(:planned_auto_action)
    assert_equal true, report.fetch(:within_tolerance)
    assert_empty report.fetch(:blockers)
  end

  test "Nado adapter computes increase short sell non reduce-only" do
    report = nado_adapter(current_short: "0.90", target: "1.0").readiness(position: position("nado"))

    assert_equal "increase_short", report.fetch(:planned_auto_action)
    assert_equal "sell", report.fetch(:side)
    assert_equal false, report.fetch(:reduce_only)
    assert_equal "0.1", report.fetch(:requested_size_eth)
  end

  test "Nado adapter computes decrease short buy reduce-only" do
    report = nado_adapter(current_short: "1.10", target: "1.0").readiness(position: position("nado"))

    assert_equal "decrease_short", report.fetch(:planned_auto_action)
    assert_equal "buy", report.fetch(:side)
    assert_equal true, report.fetch(:reduce_only)
    assert_equal "0.1", report.fetch(:requested_size_eth)
  end

  test "Nado adapter blocks when execution venue is not nado" do
    report = nado_adapter.readiness(position: position("ethereal"))

    assert_includes report.fetch(:blockers), "Position hedge execution_venue must be nado for Nado continuous auto"
  end

  test "Nado manual one-shot readiness does not require continuous auto gate" do
    env = nado_ready_env.merge("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false")
    report = nado_adapter(env: env, current_short: "1.10", target: "1.0").readiness(position: position("nado"), mode: :manual_one_shot)

    assert_equal "manual_one_shot", report.fetch(:readiness_mode)
    assert_equal false, report.fetch(:nado_auto_rebalance_enabled)
    assert_equal true, report.fetch(:nado_live_enabled)
    assert_equal "decrease_short", report.fetch(:planned_auto_action)
    assert_not_includes report.fetch(:blockers), "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true"
    assert_equal true, report.fetch(:manual_one_shot_ready)
  end

  test "Nado continuous auto readiness still requires continuous auto gate" do
    env = nado_ready_env.merge("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false")
    report = nado_adapter(env: env, current_short: "1.10", target: "1.0").readiness(position: position("nado"))

    assert_equal "continuous_auto", report.fetch(:readiness_mode)
    assert_includes report.fetch(:blockers), "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true"
  end

  test "Nado adapter blocks when Ethereal is not flat" do
    report = nado_adapter(ethereal_short: "0.1").readiness(position: position("nado"))

    assert_includes report.fetch(:blockers), "Ethereal must be flat before Nado continuous auto"
  end

  test "Nado adapter blocks when Extended is not flat" do
    report = nado_adapter(extended_short: "0.1").readiness(position: position("nado"))

    assert_includes report.fetch(:blockers), "Extended must be flat before Nado continuous auto"
  end

  test "Nado adapter blocks when open orders exist" do
    report = nado_adapter(open_orders_count: 2).readiness(position: position("nado"))

    assert_equal 2, report.fetch(:open_orders_count)
    assert_includes report.fetch(:blockers), "Nado auto requires open_orders_count=0"
  end

  test "Nado adapter uses market price metadata" do
    report = nado_adapter(market_price: "2345.67").readiness(position: position("nado"))

    assert_equal "ok", report.fetch(:nado_market_metadata_status)
    assert_equal "2345.67", report.fetch(:nado_market_price)
    assert_equal "nado_market_price", report.fetch(:nado_market_price_source)
    assert_equal "GET /query?type=market_price", report.fetch(:nado_market_metadata_source)
    assert_not report.fetch(:blockers).any? { |blocker| blocker.include?("market metadata") }
  end

  private

  def ethereal_adapter(env: ready_env, current_short: "1.0", target: "1.0", extended_short: "0", nado_short: "0", open_orders_count: 0)
    HedgeVenueAutoAdapters::Ethereal.new(
      env: env,
      ethereal_service: FakeService.new(short: current_short, open_orders_count: open_orders_count),
      extended_venue: FakeVenue.new(short: extended_short),
      nado_venue: FakeVenue.new(short: nado_short),
      fresh_target_factory: ->(_position) { FreshTarget.new(target) }
    )
  end

  def nado_adapter(env: nado_ready_env, current_short: "1.0", target: "1.0", extended_short: "0", ethereal_short: "0", open_orders_count: 0, market_price: "2300")
    HedgeVenueAutoAdapters::Nado.new(
      env: env,
      nado_venue: FakeVenue.new(short: current_short, open_orders_count: open_orders_count),
      extended_venue: FakeVenue.new(short: extended_short),
      ethereal_service: FakeService.new(short: ethereal_short),
      nado_service: FakeNadoService.new(market_price: market_price),
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

  def nado_ready_env
    ready_env.merge(
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true"
    )
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
    def initialize(short:, open_orders_count: 0)
      @venue = FakeVenue.new(short: short, open_orders_count: open_orders_count)
    end

    def read_position
      @venue.read_position(symbol: "ETH")
    end
  end

  class FakeVenue
    def initialize(short:, open_orders_count: 0)
      @short = BigDecimal(short)
      @open_orders_count = open_orders_count
    end

    def read_position(symbol:)
      return nil if @short.zero?

      { side: "short", short_size: @short.to_s("F"), margin_mode: "cross" }
    end

    def account_state
      {
        open_orders_read_attempted: true,
        open_orders_read_status: @open_orders_count.nil? ? "unavailable" : "ok",
        open_orders_count: @open_orders_count,
        open_orders_diagnostics: { source: "test" }
      }
    end
  end

  class FakeNadoService
    def initialize(market_price:)
      @market_price = market_price
    end

    def market_metadata(position:)
      {
        status: "ok",
        source: "GET /query?type=market_price",
        market_price: @market_price,
        market_price_source: "nado_market_price",
        price_increment: "0.1",
        size_increment: "0.001",
        blockers: [],
        warnings: []
      }
    end
  end
end
