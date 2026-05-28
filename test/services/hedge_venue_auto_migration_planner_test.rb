require "test_helper"

class HedgeVenueAutoMigrationPlannerTest < ActiveSupport::TestCase
  test "random planner excludes current venue" do
    result = planner.plan(position: migration_position)

    assert_equal "extended", result.receipt.fetch(:current_venue)
    assert_not_includes result.receipt.fetch(:eligible_target_venues), "extended"
    assert_equal false, result.receipt.fetch(:would_migrate)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "random planner only selects ready dry run routes" do
    result = planner(random_seed: "pick").plan(position: migration_position)
    selected = result.receipt.fetch(:selected_route)

    assert_equal "READY_FOR_DRY_RUN", selected.fetch(:route_status)
    assert_equal true, selected.fetch(:preview_available)
    assert_equal %w[ethereal nado].sort, result.receipt.fetch(:eligible_target_venues).sort
  end

  test "random planner does not carry economics funding or pnl fields" do
    result = planner(route_matrix: route_matrix_with_economics).plan(position: migration_position)
    payload = result.receipt.to_json

    assert_no_match(/funding|fee|pnl|profit|score|carry/i, payload)
  end

  test "random planner blocks when cooldown not passed" do
    now = Time.zone.local(2026, 5, 28, 12, 0, 0)
    events = [ { timestamp: (now - 1.hour).iso8601 } ]
    result = planner(now: -> { now }, migration_events: events, env: { "MIGRATION_MIN_COOLDOWN_HOURS" => "24" }).plan(position: migration_position)

    assert result.receipt.fetch(:cooldown_status).fetch(:remaining_hours).positive?
    assert result.blockers.any? { |blocker| blocker.start_with?("migration cooldown remaining") }
    assert_nil result.receipt.fetch(:selected_route)
  end

  test "random planner blocks when daily limit reached" do
    now = Time.zone.local(2026, 5, 28, 12, 0, 0)
    events = [ { timestamp: (now - 1.hour).iso8601 } ]
    result = planner(now: -> { now }, migration_events: events, env: { "MIGRATION_MAX_PER_DAY" => "1", "MIGRATION_MIN_COOLDOWN_HOURS" => "0" }).plan(position: migration_position)

    assert_includes result.blockers, "daily migration limit reached"
    assert_nil result.receipt.fetch(:selected_route)
  end

  test "random planner returns no eligible route when all routes are blocked" do
    result = planner(route_matrix: blocked_route_matrix).plan(position: migration_position)

    assert_equal "NO_ELIGIBLE_ROUTE", result.receipt.fetch(:status)
    assert_nil result.receipt.fetch(:selected_route)
    assert_includes result.blockers, "no eligible random rotation route"
  end

  test "random planner reports incomplete proof when snapshot critical fields are missing" do
    result = planner(route_matrix: incomplete_route_matrix).plan(position: migration_position)

    assert_equal "NO_ELIGIBLE_ROUTE", result.receipt.fetch(:status)
    assert_includes result.blockers, "route proof incomplete because snapshot critical fields are missing"
    assert_nil result.receipt.fetch(:selected_route)
  end

  test "random planner can include Nado in decision only when route proof is ready" do
    result = planner(env: { "MIGRATION_ALLOWED_ROUTES" => "extended->nado" }).plan(position: migration_position)

    assert_equal [ "nado" ], result.receipt.fetch(:eligible_target_venues)
    assert_equal "nado", result.receipt.fetch(:selected_target_venue)
    assert_equal false, result.receipt.fetch(:live_available)
    assert_equal false, result.receipt.fetch(:would_migrate)
  end

  test "random planner excludes Nado from live while Nado live is unavailable" do
    result = planner(env: { "MIGRATION_AUTO_ENABLED" => "true", "MIGRATION_AUTO_DRY_RUN_ONLY" => "false", "MIGRATION_ALLOW_NADO_LIVE" => "false", "MIGRATION_ALLOWED_ROUTES" => "extended->nado" }).plan(position: migration_position)

    assert_equal "nado", result.receipt.fetch(:selected_target_venue)
    assert_equal false, result.receipt.fetch(:live_execution_enabled)
    assert_equal false, result.receipt.fetch(:live_available)
    assert_equal false, result.receipt.fetch(:would_migrate)
  end

  test "random planner is deterministic with seed" do
    first = planner(random_seed: "same-seed").plan(position: migration_position).receipt
    second = planner(random_seed: "same-seed").plan(position: migration_position).receipt

    assert_equal first.fetch(:selected_route), second.fetch(:selected_route)
    assert_equal first.fetch(:selection_id), second.fetch(:selection_id)
    assert_equal "same-seed", first.fetch(:random_seed)
  end

  private

  def planner(env: {}, route_matrix: ready_route_matrix, now: -> { Time.zone.local(2026, 5, 28, 12, 0, 0) }, migration_events: [], random_seed: "seed")
    HedgeVenueAutoMigrationPlanner.new(
      env: default_env.merge(env),
      route_matrix: route_matrix,
      now: now,
      migration_events: migration_events,
      random_seed: random_seed
    )
  end

  def default_env
    {
      "MIGRATION_ALLOWED_VENUES" => "extended,ethereal,nado",
      "MIGRATION_MAX_PER_DAY" => "1",
      "MIGRATION_MIN_COOLDOWN_HOURS" => "0",
      "MIGRATION_REQUIRE_ROUTE_PROOF" => "true"
    }
  end

  def migration_position
    position = Position.create!(
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
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok"
    )
    position
  end

  def ready_route_matrix
    {
      routes: [
        route("extended", "ethereal", "READY_FOR_DRY_RUN"),
        route("extended", "nado", "READY_FOR_DRY_RUN", blockers: [ "Nado live migration path not implemented." ]),
        route("nado", "extended", "PREVIEW_BLOCKED", blockers: [ "source venue Nado has no current short to migrate." ])
      ]
    }
  end

  def route_matrix_with_economics
    {
      routes: [
        route("extended", "ethereal", "READY_FOR_DRY_RUN").merge(funding_rate: "-100", fee_score: "bad", unrealized_pnl: "999"),
        route("extended", "nado", "READY_FOR_DRY_RUN", blockers: [ "Nado live migration path not implemented." ]).merge(funding_rate: "100", fee_score: "best", pnl_score: "best")
      ]
    }
  end

  def blocked_route_matrix
    { routes: [ route("extended", "ethereal", "PREVIEW_BLOCKED", blockers: [ "open orders present" ]) ] }
  end

  def incomplete_route_matrix
    { routes: [ route("extended", "ethereal", "PREVIEW_BLOCKED", blockers: [ "target short is unavailable in dashboard snapshot" ]) ] }
  end

  def route(from, to, status, blockers: [])
    {
      from_venue: from,
      to_venue: to,
      route_status: status,
      preview_available: status == "READY_FOR_DRY_RUN",
      live_available: false,
      blockers: blockers,
      last_proof_time: Time.current.utc.iso8601
    }
  end
end
