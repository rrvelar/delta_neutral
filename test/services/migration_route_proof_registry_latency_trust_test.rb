require "test_helper"

# 2026-07-12 latency-trust hardening: READY_FOR_RANDOM / production_safe require
# a live event carrying the modern latency measurement for the route's sequence.
# Blank-latency wrapper events (production cycles, continuations, reconciliation
# receipts) refresh freshness but can no longer certify production-safe.
class MigrationRouteProofRegistryLatencyTrustTest < ActiveSupport::TestCase
  test "legacy blank-latency production cycle no longer qualifies production_safe" do
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "nado", to: "extended", execution_overrides: {
      "double_exposure_seconds" => nil, "underhedge_seconds" => nil, "total_route_seconds" => nil, "route_production_safe" => nil
    })

    route = registry.route_status(position: position, from: "nado", to: "extended")

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_equal false, route.fetch(:route_production_safe)
    assert_equal "legacy_missing_latency_fields", route.fetch(:latency_untrusted_reason)
    assert_equal "failed_latency_threshold", route.fetch(:latency_proof_status)
  end

  test "modern passing cycle measurement qualifies production_safe" do
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "nado", to: "extended")

    route = registry.route_status(position: position, from: "nado", to: "extended")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal true, route.fetch(:route_production_safe)
    assert_nil route.fetch(:latency_untrusted_reason)
    assert_equal "2", route.fetch(:measured_double_exposure_seconds)
  end

  test "modern failing measurement does not qualify and explains why" do
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "nado", to: "extended", execution_overrides: {
      "double_exposure_seconds" => "28.5", "route_production_safe" => false, "latency_incident" => true
    })

    route = registry.route_status(position: position, from: "nado", to: "extended")

    refute_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal false, route.fetch(:route_production_safe)
    assert_equal "production_safe_false", route.fetch(:latency_untrusted_reason)
  end

  test "stale proof still blocks and reports stale even with a passing old measurement" do
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "nado", to: "extended", timestamp: 45.days.ago.utc.iso8601)

    route = registry.route_status(position: position, from: "nado", to: "extended")

    assert_equal "STALE", route.fetch(:status)
    assert_equal "stale", route.fetch(:latency_untrusted_reason)
  end

  test "source_first cycle with high total_route_seconds but passing underhedge stays production_safe" do
    # Regression (2026-07-14): production-cycle events do not carry migration_sequence,
    # so a source_first route (ethereal->nado) was mis-judged by the target_first
    # total-route bar. Underhedge 4.54s (< 10) must qualify regardless of a 34.7s
    # total_route_seconds, which is not the source_first metric.
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "ethereal", to: "nado", execution_overrides: {
      "status" => "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      "double_exposure_seconds" => "0", "underhedge_seconds" => "4.54",
      "total_route_seconds" => "34.74", "route_production_safe" => true
      # deliberately NO migration_sequence key
    })

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal true, route.fetch(:route_production_safe)
    assert_nil route.fetch(:latency_untrusted_reason)
    assert_equal "4.54", route.fetch(:measured_underhedge_seconds)
  end

  test "target_first cycle is still gated by total_route_seconds over the bar" do
    # The same 34.7s total-route on a TARGET_FIRST route (nado->extended) must
    # still fail: the sequence-correct fix must not weaken target_first gating.
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_cycle(dir: dir, position: position, from: "nado", to: "extended", execution_overrides: {
      "double_exposure_seconds" => "1", "underhedge_seconds" => nil,
      "total_route_seconds" => "34.74", "route_production_safe" => true
    })

    route = registry.route_status(position: position, from: "nado", to: "extended")

    assert_equal false, route.fetch(:route_production_safe)
    assert_equal "production_safe_false", route.fetch(:latency_untrusted_reason)
  end

  test "source_first route requires underhedge measurement" do
    position = nado_position
    dir = Rails.root.join("tmp/latency-trust-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    # ethereal->nado is source_first by policy: a proof with only double_exposure
    # (and no underhedge) is not modern evidence for that family.
    write_cycle(dir: dir, position: position, from: "ethereal", to: "nado", execution_overrides: {
      "underhedge_seconds" => nil, "status" => "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK"
    })

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal false, route.fetch(:route_production_safe)
    assert_equal "legacy_missing_latency_fields", route.fetch(:latency_untrusted_reason)
  end

  private

  def registry_for(dir)
    MigrationRouteProofRegistry.new(
      route_proof_dir: dir.join("route_proofs"),
      canary_dir: dir.join("canaries"),
      recovery_dir: dir.join("recoveries"),
      continuation_dir: dir.join("continuations"),
      random_dir: dir.join("random"),
      latency_proof_dir: dir.join("latency_proofs"),
      production_dir: dir.join("production")
    )
  end

  def write_cycle(dir:, position:, from:, to:, timestamp: 1.hour.ago.utc.iso8601, execution_overrides: {})
    FileUtils.mkdir_p(dir.join("production"))
    execution = {
      "status" => "MIGRATION_FINALIZED",
      "source_flat_after" => true,
      "target_holds_expected_short" => true,
      "third_venue_flat" => true,
      "open_orders_clear_after" => true,
      "open_orders_after" => 0,
      "final_inside_tolerance" => true,
      "production_venue_finalized" => true,
      "double_exposure_seconds" => "2",
      "underhedge_seconds" => "3",
      "total_route_seconds" => "20",
      "route_production_safe" => true,
      "orders_submitted" => 2,
      "orders_placed" => 2,
      "signatures_created" => 2
    }.merge(execution_overrides).compact
    event = {
      "event" => "cycle",
      "status" => "success",
      "started_at" => timestamp,
      "from_venue" => from,
      "to_venue" => to,
      "route" => "#{from}->#{to}",
      "cycle" => 1,
      "blockers" => [],
      "execution" => execution,
      "post_cycle_hedge" => { "production_venue" => to }
    }
    File.open(dir.join("production", "20260712_000000_position_#{position.id}.jsonl"), "a") do |file|
      file.puts(JSON.generate(event))
    end
  end

  def nado_position
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH", asset1: "USDC", asset0_amount: "1", asset1_amount: "500",
      asset0_price_usd: "2000", asset1_price_usd: "1",
      external_id: SecureRandom.hex(6), pool_address: "0x#{SecureRandom.hex(20)}", active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "nado")
    position
  end
end
