require "test_helper"

class MigrationExecutionPreflightTest < ActiveSupport::TestCase
  test "ready when source holds expected short and target and third venue are flat" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado").report

    assert_equal "ready", report.fetch(:status)
    assert_equal true, report.fetch(:can_submit)
    assert_empty report.fetch(:hard_blockers)
    assert_equal BigDecimal("1.18"), report.dig(:venues, "ethereal", :short_eth)
    assert_equal BigDecimal("0"), report.dig(:venues, "nado", :short_eth)
  end

  test "blocks when source direct readback is missing" do
    position = migration_position("ethereal")
    report = preflight(
      position,
      from: "ethereal",
      to: "nado",
      venues: { "ethereal" => FakeVenue.new(position_error: "timeout") }
    ).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "Ethereal position readback failed: RuntimeError: timeout"
    assert_includes report.fetch(:hard_blockers), "source current position must exist."
  end

  test "blocks when source short is zero" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado", venues: { "ethereal" => FakeVenue.new(short: "0") }).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "source current position must exist."
  end

  test "blocks when target venue has unexpected exposure" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado", venues: { "nado" => FakeVenue.new(short: "0.2") }).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "Nado target venue must be flat before migration"
  end

  test "blocks when third venue is non-flat" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado", venues: { "extended" => FakeVenue.new(short: "0.2") }).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "Extended third venue must be flat before migration"
  end

  test "blocks when relevant venue open orders are non-zero" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado", venues: { "nado" => FakeVenue.new(open_orders_count: 1) }).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "nado open orders must be zero"
  end

  test "blocks when LP target is stale or unavailable" do
    position = migration_position("ethereal")
    report = preflight(position, from: "ethereal", to: "nado", target: FakeTarget.new(status: "blocked", fresh: false, target: nil)).report

    assert_equal "blocked", report.fetch(:status)
    assert_includes report.fetch(:hard_blockers), "fresh LP target is unavailable"
  end

  test "warns but does not block on optional third venue account timeout when critical readbacks are ok" do
    position = migration_position("ethereal")
    position.position_dashboard_snapshot.update!(
      refresh_status: "partial",
      source_errors: [ "extended optional account state timed_out=true timeout_seconds=8.0" ],
      extended_optional_read_status: "timed_out",
      extended_critical_read_status: "ok"
    )

    report = preflight(position, from: "ethereal", to: "nado").report

    assert_equal "warning", report.fetch(:status)
    assert_equal true, report.fetch(:can_submit)
    assert_empty report.fetch(:hard_blockers)
    assert_includes report.fetch(:warnings), "dashboard snapshot refresh_status=partial treated as diagnostic; direct migration preflight readbacks are authoritative"
    assert report.fetch(:warnings).any? { |warning| warning.include?("optional dashboard diagnostic ignored") }
  end

  test "ethereal to nado source first ignores Extended optional timeout but blocks if Ethereal direct short is flat" do
    position = migration_position("ethereal")
    position.position_dashboard_snapshot.update!(
      refresh_status: "partial",
      source_errors: [ "extended optional account state timed_out=true timeout_seconds=8.0" ]
    )

    ready = preflight(position, from: "ethereal", to: "nado", strategy: "source_first").report
    blocked = preflight(position, from: "ethereal", to: "nado", strategy: "source_first", venues: { "ethereal" => FakeVenue.new(short: "0") }).report

    assert_equal true, ready.fetch(:can_submit)
    assert_not_includes ready.fetch(:hard_blockers), "Position dashboard snapshot refresh_status=partial; refresh read-only data before planning migration."
    assert_equal "blocked", blocked.fetch(:status)
    assert_includes blocked.fetch(:hard_blockers), "source current position must exist."
  end

  private

  def preflight(position, from:, to:, strategy: "source_first", venues: {}, target: FakeTarget.new)
    MigrationExecutionPreflight.new(
      position: position,
      from: from,
      to: to,
      strategy: strategy,
      env: {},
      venue_builder: FakeVenueBuilder.new(venues),
      signer_client: FakeSigner.new,
      fresh_target_factory: ->(_) { target }
    )
  end

  def migration_position(venue)
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
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: venue)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: venue,
      selected_venue: venue,
      target_short_eth: "1.18",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.0354",
      combined_short_eth: "1.18",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: venue == "extended" ? "1.18" : "0",
      ethereal_short_eth: venue == "ethereal" ? "1.18" : "0",
      nado_short_eth: venue == "nado" ? "1.18" : "0",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      signer_status: "ok",
      open_orders_count_extended: 0,
      extended_critical_read_status: "ok",
      extended_optional_read_status: "ok"
    )
    position
  end

  class FakeVenueBuilder
    def initialize(overrides)
      @overrides = overrides
    end

    def build(venue, **)
      @overrides.fetch(venue) { FakeVenue.new(short: venue == "ethereal" ? "1.18" : "0") }
    end
  end

  class FakeVenue
    def initialize(short: "0", open_orders_count: 0, position_error: nil)
      @short = short
      @open_orders_count = open_orders_count
      @position_error = position_error
    end

    def read_position(symbol:)
      raise @position_error if @position_error

      { short_size: @short }
    end

    def account_state
      { open_orders_count: @open_orders_count }
    end
  end

  class FakeTarget
    def initialize(status: "ok", fresh: true, target: "1.18")
      @status = status
      @fresh = fresh
      @target = target
    end

    def resolve(refresh_if_stale:)
      {
        status: @status,
        target_short_eth: @target,
        target_source: "test",
        target_fresh: @fresh,
        exposure_source: "test",
        exposure_refreshed_at: Time.current.utc.iso8601,
        blockers: @status == "ok" ? [] : [ "target unavailable" ],
        orders_submitted: 0,
        signatures_created: 0
      }
    end
  end

  class FakeSigner
    def health
      { ok: true }
    end
  end
end
