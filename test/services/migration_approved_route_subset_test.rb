require "test_helper"

# Path A (2026-07-18): explicit approved-route subset so production can restart
# with Extended excluded while it is quarantined.
class MigrationApprovedRouteSubsetTest < ActiveSupport::TestCase
  READY = MigrationRouteProofRegistry::STATUSES[:ready]
  SUBSET = "nado->ethereal,ethereal->nado".freeze

  test "no subset key means subset mode off and every route allowed" do
    subset = MigrationApprovedRouteSubset.new(env: {})

    assert_equal false, subset.active?
    assert_equal true, subset.route_allowed?(from: "nado", to: "extended")
    assert_empty subset.start_blockers(proof_report: proof_report)
    assert_equal({ subset_mode: false, key: "MIGRATION_ALLOWED_ROUTES" }, subset.report)
  end

  test "nado<->ethereal subset validates clean when both routes are proven and enabled" do
    set_subset!(SUBSET)
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    subset = MigrationApprovedRouteSubset.new(env: {})

    assert_equal true, subset.active?
    assert_equal %w[nado->ethereal ethereal->nado], subset.allowed_routes
    assert_empty subset.start_blockers(proof_report: proof_report)
    assert_equal true, subset.route_allowed?(from: "nado", to: "ethereal")
    assert_equal false, subset.route_allowed?(from: "nado", to: "extended")
  end

  test "subset including an Extended route is rejected while quarantine is true" do
    set_subset!("nado->ethereal,nado->extended")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    blockers = MigrationApprovedRouteSubset.new(env: {}).start_blockers(proof_report: proof_report)

    assert blockers.any? { |b| b.include?("nado->extended") && b.include?("quarantined") }, blockers.inspect
  end

  test "subset including an unproven route is rejected" do
    set_subset!("nado->ethereal,extended->ethereal")

    blockers = MigrationApprovedRouteSubset.new(env: {}).start_blockers(
      proof_report: proof_report(overrides: { "extended->ethereal" => "NOT_PRODUCTION_SAFE_LATENCY" })
    )

    assert blockers.any? { |b| b.include?("extended->ethereal") && b.include?("NOT_PRODUCTION_SAFE_LATENCY") }, blockers.inspect
  end

  test "subset including a policy-disabled route is rejected" do
    set_subset!(SUBSET)
    policy = MigrationRouteOperationalPolicy.new(env: {})
    result = policy.set_route!(from: "nado", to: "ethereal", enabled: false, strategy: "manual_only", confirmation: MigrationRouteOperationalPolicy::CHANGE_CONFIRMATION)
    assert result.ok, result.errors.inspect

    blockers = MigrationApprovedRouteSubset.new(env: {}).start_blockers(proof_report: proof_report)

    assert blockers.any? { |b| b.include?("nado->ethereal") && b.include?("disabled by route policy") }, blockers.inspect
  end

  test "malformed or effectively-empty subset fails closed" do
    # set! validation rejects unknown routes outright
    result = OperationalSettings.set!(key: "MIGRATION_ALLOWED_ROUTES", enabled: "foo->bar", reason: "test")
    assert_equal false, result.ok

    # a malformed value arriving via env still fails closed at the runner layer
    subset = MigrationApprovedRouteSubset.new(env: { "MIGRATION_ALLOWED_ROUTES" => "foo->bar, ," })
    assert_equal true, subset.active?
    assert_empty subset.allowed_routes
    assert_equal false, subset.route_allowed?(from: "nado", to: "ethereal"), "malformed subset must allow nothing"
    blockers = subset.start_blockers(proof_report: proof_report)
    assert blockers.any? { |b| b.include?("no valid routes") }, blockers.inspect
    assert blockers.any? { |b| b.include?("unknown route") }, blockers.inspect
  end

  test "set! accepts a valid subset and blank clears it" do
    result = set_subset!(SUBSET)
    assert result.ok, result.errors.inspect
    assert_equal SUBSET, OperationalSetting.find_by(key: "MIGRATION_ALLOWED_ROUTES").value

    cleared = OperationalSettings.set!(key: "MIGRATION_ALLOWED_ROUTES", enabled: "", reason: "test clear")
    assert cleared.ok, cleared.errors.inspect
    assert_equal false, MigrationApprovedRouteSubset.new(env: {}).active?
  end

  test "runner route selection never chooses a route excluded by the subset" do
    set_subset!("nado->ethereal")
    position = subset_position(execution_venue: "nado")
    registry = fake_registry(
      { route: "nado->extended", from_venue: "nado", to_venue: "extended", status: READY, migration_sequence: "target_first" },
      { route: "nado->ethereal", from_venue: "nado", to_venue: "ethereal", status: READY, migration_sequence: "target_first" }
    )
    runner = MigrationRandomBurnInRunner.new(
      position: position, duration_minutes: 0, interval_seconds: 0, max_cycles: 1,
      env: {}, proof_registry: registry,
      log_dir: Rails.root.join("tmp/test-subset-burnin-#{SecureRandom.hex(4)}")
    )

    selected = runner.send(:select_route)

    assert_equal "nado->ethereal", selected[:route], "subset must exclude nado->extended even though the daily-coverage preference would pick it"
  end

  test "quarantine start blocker clears when the active subset excludes all extended routes" do
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")
    position = subset_position(execution_venue: "nado")
    runner = MigrationRandomProductionRunner.new(
      position: position, live: false, env: {}, trap_signals: false,
      log_dir: Rails.root.join("tmp/test-subset-runner-#{SecureRandom.hex(4)}")
    )

    assert runner.send(:quarantine_blockers).any?, "without a subset the enabled extended routes block the start"

    set_subset!(SUBSET)
    assert_empty runner.send(:quarantine_blockers), "subset excluding extended satisfies the quarantine route condition"
  end

  # --- subset-aware aggregate proof gate (STOP finding fix) ---

  test "aggregate proof gate ignores subset-excluded unproven routes" do
    set_subset!(SUBSET)
    position = subset_position(execution_venue: "nado")
    report = proof_gate_report(overrides: { "extended->ethereal" => "NOT_PRODUCTION_SAFE_LATENCY" })

    [ preflight(position), readiness(position) ].each do |service|
      missing = service.send(:enabled_missing_route_proofs, report)
      assert_empty missing, "#{service.class}: subset-excluded extended->ethereal must not require a proof"
    end
  end

  test "aggregate proof gate still blocks on unproven routes without a subset" do
    position = subset_position(execution_venue: "nado")
    report = proof_gate_report(overrides: { "extended->ethereal" => "NOT_PRODUCTION_SAFE_LATENCY" })

    [ preflight(position), readiness(position) ].each do |service|
      missing = service.send(:enabled_missing_route_proofs, report)
      assert missing.any? { |route| route[:route] == "extended->ethereal" }, "#{service.class}: without a subset the unproven route must stay in scope"
    end
  end

  test "aggregate proof gate still blocks when an allowed subset route is unproven" do
    set_subset!(SUBSET)
    position = subset_position(execution_venue: "nado")
    report = proof_gate_report(overrides: { "nado->ethereal" => "NOT_PRODUCTION_SAFE_LATENCY" })

    [ preflight(position), readiness(position) ].each do |service|
      missing = service.send(:enabled_missing_route_proofs, report)
      assert missing.any? { |route| route[:route] == "nado->ethereal" }, "#{service.class}: an allowed-but-unproven route must block"
    end
  end

  test "malformed subset does not silently ignore proofs (fail closed)" do
    position = subset_position(execution_venue: "nado")
    report = proof_gate_report(overrides: { "extended->ethereal" => "NOT_PRODUCTION_SAFE_LATENCY" })
    env = { "MIGRATION_ALLOWED_ROUTES" => "foo->bar" }

    [ MigrationExecutionPreflight.new(position: position, env: env), MigrationRandomReadiness.new(position: position, env: env) ].each do |service|
      missing = service.send(:enabled_missing_route_proofs, report)
      assert missing.any? { |route| route[:route] == "extended->ethereal" }, "#{service.class}: a malformed subset must keep every proof in scope"
    end
  end

  test "stale proof blocker is also subset-aware" do
    set_subset!(SUBSET)
    position = subset_position(execution_venue: "nado")
    stale = [ { route: "extended->ethereal", from_venue: "extended", to_venue: "ethereal", status: "STALE" } ]

    [ preflight(position), readiness(position) ].each do |service|
      assert_empty service.send(:subset_selectable_routes, stale), "#{service.class}: subset-excluded stale route must not block"
    end

    stale_allowed = [ { route: "nado->ethereal", from_venue: "nado", to_venue: "ethereal", status: "STALE" } ]
    [ preflight(position), readiness(position) ].each do |service|
      assert_equal 1, service.send(:subset_selectable_routes, stale_allowed).size, "#{service.class}: an allowed stale route must still block"
    end
  end

  test "report surfaces subset mode, allowed and excluded routes with reasons" do
    set_subset!(SUBSET)

    report = MigrationApprovedRouteSubset.new(env: {}).report(proof_report: proof_report)

    assert_equal true, report[:subset_mode]
    assert_equal %w[nado->ethereal ethereal->nado], report[:allowed_routes]
    excluded = report[:excluded_routes].map { |r| r[:route] }
    assert_includes excluded, "nado->extended"
    assert_includes excluded, "extended->ethereal"
    assert(report[:excluded_routes].all? { |r| r[:reason] == "not in approved subset" })
    assert_empty report[:blockers]
  end

  private

  def set_subset!(value)
    OperationalSettings.set!(key: "MIGRATION_ALLOWED_ROUTES", enabled: value, reason: "test subset")
  end

  def proof_report(overrides: {})
    routes = OperationalSettings::ROUTE_KEYS_BY_ROUTE.keys.map do |route|
      { route: route, status: overrides.fetch(route, READY) }
    end
    { routes: routes }
  end

  # Shape used by the preflight/readiness aggregate proof gates.
  def proof_gate_report(overrides: {})
    routes = OperationalSettings::ROUTE_KEYS_BY_ROUTE.keys.map do |route|
      from, to = route.split("->")
      { route: route, from_venue: from, to_venue: to, status: overrides.fetch(route, READY) }
    end
    {
      routes: routes,
      missing_route_proofs: routes.reject { |route| route[:status] == READY },
      stale_route_proofs: []
    }
  end

  def preflight(position)
    MigrationExecutionPreflight.new(position: position, env: {})
  end

  def readiness(position)
    MigrationRandomReadiness.new(position: position, env: {})
  end

  def fake_registry(*routes)
    Class.new do
      def initialize(routes) = @routes = routes
      def report(position:) = { routes: @routes }
    end.new(routes)
  end

  def subset_position(execution_venue:)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.54",
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
