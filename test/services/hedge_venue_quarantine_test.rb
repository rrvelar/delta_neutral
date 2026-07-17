require "test_helper"

# 2026-07-17: while Extended is quarantined, autonomous/random production must
# not open new Extended exposure and the runner must refuse to start unless the
# enabled route subset excludes Extended.
class HedgeVenueQuarantineTest < ActiveSupport::TestCase
  READY = MigrationRouteProofRegistry::STATUSES[:ready]

  test "extended is not quarantined by default and unknown venues never are" do
    assert_equal false, HedgeVenueQuarantine.quarantined?("extended", env: {})
    assert_equal false, HedgeVenueQuarantine.quarantined?("ethereal", env: {})
    assert_empty HedgeVenueQuarantine.quarantined_venues(env: {})
  end

  test "quarantine flag is read from operational settings" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    assert_equal true, HedgeVenueQuarantine.quarantined?("extended", env: {})
    assert_equal [ "extended" ], HedgeVenueQuarantine.quarantined_venues(env: {})
  end

  test "random production route selection skips routes targeting a quarantined venue" do
    position = quarantine_position(execution_venue: "nado")
    registry = fake_registry(
      route("nado", "extended"),
      route("nado", "ethereal")
    )
    runner = burn_in_runner(position: position, registry: registry)

    selected = runner.send(:select_route)
    assert_equal "extended", selected[:to_venue], "without quarantine the daily-coverage preference picks extended"

    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    selected = runner.send(:select_route)
    assert_equal "ethereal", selected[:to_venue], "quarantine must exclude extended as a target"
  end

  test "random production route selection returns no route when only quarantined targets remain" do
    position = quarantine_position(execution_venue: "nado")
    registry = fake_registry(route("nado", "extended"))
    runner = burn_in_runner(position: position, registry: registry)
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    assert_nil runner.send(:select_route)
  end

  test "runner start is blocked while extended is quarantined and routes still target it" do
    position = quarantine_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    blockers = production_runner(position).send(:quarantine_blockers)

    assert blockers.any? { |blocker| blocker.include?("enabled routes still target it") }, blockers.inspect
  end

  test "runner start is blocked while extended is quarantined and is the production venue" do
    position = quarantine_position(execution_venue: "extended")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    blockers = production_runner(position).send(:quarantine_blockers)

    assert blockers.any? { |blocker| blocker.include?("is the current production venue") }, blockers.inspect
  end

  test "runner start is allowed while quarantined when the approved route subset excludes extended" do
    position = quarantine_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    policy = MigrationRouteOperationalPolicy.new(env: {})
    [ %w[nado extended], %w[ethereal extended] ].each do |from, to|
      result = policy.set_route!(from: from, to: to, enabled: false, strategy: "manual_only", confirmation: MigrationRouteOperationalPolicy::CHANGE_CONFIRMATION)
      assert result.ok, result.errors.inspect
    end

    assert_empty production_runner(position).send(:quarantine_blockers)
  end

  test "runner start has no quarantine blockers when nothing is quarantined" do
    position = quarantine_position(execution_venue: "extended")

    assert_empty production_runner(position).send(:quarantine_blockers)
  end

  private

  def route(from, to)
    { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: READY, migration_sequence: "target_first" }
  end

  def fake_registry(*routes)
    Class.new do
      def initialize(routes) = @routes = routes
      def report(position:) = { routes: @routes }
    end.new(routes)
  end

  def burn_in_runner(position:, registry:)
    MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: 0,
      interval_seconds: 0,
      max_cycles: 1,
      env: {},
      proof_registry: registry,
      log_dir: Rails.root.join("tmp/test-quarantine-burnin-#{SecureRandom.hex(4)}")
    )
  end

  def production_runner(position)
    MigrationRandomProductionRunner.new(
      position: position,
      live: false,
      env: {},
      log_dir: Rails.root.join("tmp/test-quarantine-runner-#{SecureRandom.hex(4)}"),
      trap_signals: false
    )
  end

  def quarantine_position(execution_venue:)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.61",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: execution_venue)
    position
  end
end
