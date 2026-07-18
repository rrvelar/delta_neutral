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
    assert_equal "normal", HedgeVenueQuarantine.state("extended", env: {})
    assert_equal false, HedgeVenueQuarantine.autonomous_blocked?("extended", env: {})
  end

  test "quarantine flag is read from operational settings" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    assert_equal true, HedgeVenueQuarantine.quarantined?("extended", env: {})
    assert_equal [ "extended" ], HedgeVenueQuarantine.quarantined_venues(env: {})
    assert_equal "quarantined", HedgeVenueQuarantine.state("extended", env: {})
    assert_equal true, HedgeVenueQuarantine.autonomous_blocked?("extended", env: {})
  end

  test "probation state blocks autonomous production and quarantine wins over probation" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    assert_equal "probation", HedgeVenueQuarantine.state("extended", env: {})
    assert_equal true, HedgeVenueQuarantine.autonomous_blocked?("extended", env: {})
    assert_equal [ "extended" ], HedgeVenueQuarantine.autonomous_blocked_venues(env: {})

    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    assert_equal "quarantined", HedgeVenueQuarantine.state("extended", env: {}), "quarantine wins when both flags are set"
  end

  test "supervised canary targeting is refused in quarantine, gated in probation, open in normal" do
    # normal
    assert_empty HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "extended", env: {})

    # probation without the per-run gate
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")
    blockers = HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "extended", env: {})
    assert blockers.any? { |b| b.include?("EXTENDED_PROBATION_CANARY_ALLOWED") }, blockers.inspect

    # probation WITH the per-run env gate
    assert_empty HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "extended", env: { "EXTENDED_PROBATION_CANARY_ALLOWED" => "true" })

    # quarantine refuses outright, even with the gate
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    blockers = HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "extended", env: { "EXTENDED_PROBATION_CANARY_ALLOWED" => "true" })
    assert blockers.any? { |b| b.include?("quarantined") }, blockers.inspect
  end

  test "migrate-out canaries (extended as source) are never blocked by venue admission" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    assert_empty HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "nado", env: {})
    assert_empty HedgeVenueQuarantine.supervised_canary_blockers(to_venue: "ethereal", env: {})
  end

  test "status_report surfaces state, canary policy, gate and submit health" do
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-quarantine-health-#{SecureRandom.hex(4)}.json")
    ExtendedSubmitHealth.record_success!
    ExtendedSubmitHealth.record_success!
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    report = HedgeVenueQuarantine.status_report(venue: "extended", env: {})

    assert_equal "PROBATION", report[:state]
    assert_equal true, report[:autonomous_production_blocked]
    assert_match(/requires_EXTENDED_PROBATION_CANARY_ALLOWED/, report[:supervised_canary_targeting])
    assert_equal false, report[:probation_canary_gate_set]
    assert_equal "always_allowed", report[:recovery_and_migrate_out]
    assert_equal 2, report.dig(:submit_health, :successes_since_last_failure)
    assert report.dig(:submit_health, :last_success_at).present?

    gated = HedgeVenueQuarantine.status_report(venue: "extended", env: { "EXTENDED_PROBATION_CANARY_ALLOWED" => "true" })
    assert_equal "allowed_with_per_run_gate", gated[:supervised_canary_targeting]
    assert_equal true, gated[:probation_canary_gate_set]
  ensure
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-extended-submit-health-default.json")
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

  test "runner start is blocked while extended is quarantined and routes still involve it" do
    position = quarantine_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    blockers = production_runner(position).send(:quarantine_blockers)

    assert blockers.any? { |blocker| blocker.include?("enabled routes involve it") }, blockers.inspect
  end

  test "runner start is blocked in probation the same as quarantine for autonomous production" do
    position = quarantine_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    blockers = production_runner(position).send(:quarantine_blockers)

    assert blockers.any? { |blocker| blocker.include?("extended is in probation") }, blockers.inspect
  end

  test "random production route selection skips routes FROM a blocked venue too" do
    position = quarantine_position(execution_venue: "extended")
    registry = fake_registry(route("extended", "nado"), route("extended", "ethereal"))
    runner = burn_in_runner(position: position, registry: registry)

    refute_nil runner.send(:select_route)

    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")
    assert_nil runner.send(:select_route), "autonomous production must not run extended routes even as source while blocked"
  end

  test "runner start is blocked while extended is quarantined and is the production venue" do
    position = quarantine_position(execution_venue: "extended")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    blockers = production_runner(position).send(:quarantine_blockers)

    assert blockers.any? { |blocker| blocker.include?("is the current production venue") }, blockers.inspect
  end

  test "runner start is allowed while quarantined when the approved route subset excludes extended entirely" do
    position = quarantine_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    policy = MigrationRouteOperationalPolicy.new(env: {})
    [ %w[nado extended], %w[ethereal extended], %w[extended nado], %w[extended ethereal] ].each do |from, to|
      result = policy.set_route!(from: from, to: to, enabled: false, strategy: "manual_only", confirmation: MigrationRouteOperationalPolicy::CHANGE_CONFIRMATION)
      assert result.ok, result.errors.inspect
    end

    assert_empty production_runner(position).send(:quarantine_blockers)
  end

  test "manual live canary runner refuses a canary targeting extended per venue admission state" do
    runner = MigrationManualLiveCanaryRunner.new(env: {}, receipt_dir: Rails.root.join("tmp/test-canary-admission-#{SecureRandom.hex(4)}"))

    assert_empty runner.send(:venue_admission_blockers, { to_venue: "extended", from_venue: "nado" })

    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    blockers = runner.send(:venue_admission_blockers, { to_venue: "extended", from_venue: "nado" })
    assert blockers.any? { |b| b.include?("quarantined") }, blockers.inspect
    # migrate-out (extended as source) never blocked
    assert_empty runner.send(:venue_admission_blockers, { to_venue: "nado", from_venue: "extended" })
  end

  test "manual live canary runner gates a probation target on the per-run env flag" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    ungated = MigrationManualLiveCanaryRunner.new(env: {}, receipt_dir: Rails.root.join("tmp/test-canary-admission-#{SecureRandom.hex(4)}"))
    blockers = ungated.send(:venue_admission_blockers, { to_venue: "extended", from_venue: "nado" })
    assert blockers.any? { |b| b.include?("EXTENDED_PROBATION_CANARY_ALLOWED") }, blockers.inspect

    gated = MigrationManualLiveCanaryRunner.new(env: { "EXTENDED_PROBATION_CANARY_ALLOWED" => "true" }, receipt_dir: Rails.root.join("tmp/test-canary-admission-#{SecureRandom.hex(4)}"))
    assert_empty gated.send(:venue_admission_blockers, { to_venue: "extended", from_venue: "nado" })
  end

  test "recovery and revert paths carry no venue admission blockers in any state" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    OperationalSettings.set!(key: "EXTENDED_VENUE_PROBATION", enabled: true, reason: "test")

    # Neither recovery service consults venue admission — closing/moving off a
    # venue must stay available in every state. Assert the modules do not wire
    # HedgeVenueQuarantine at all.
    refute_match(/HedgeVenueQuarantine/, File.read(Rails.root.join("app/services/migration_target_first_source_recovery.rb")))
    refute_match(/HedgeVenueQuarantine/, File.read(Rails.root.join("app/services/migration_target_first_target_revert.rb")))
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
