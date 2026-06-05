require "test_helper"

class MigrationRandomReadinessTest < ActiveSupport::TestCase
  test "recovery-finalized Ethereal to Nado suppresses pending continuation and recommends Nado to Ethereal" do
    canary_dir = Rails.root.join("tmp/test-readiness-canaries-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-readiness-recoveries-#{SecureRandom.hex(4)}")
    random_dir = Rails.root.join("tmp/test-readiness-random-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_ready_canary(canary_dir, position: position, from: "extended", to: "ethereal")
    write_ready_canary(canary_dir, position: position, from: "ethereal", to: "extended")
    write_ready_canary(canary_dir, position: position, from: "extended", to: "nado")
    write_ready_canary(canary_dir, position: position, from: "nado", to: "extended")
    write_pending_nado_canary(canary_dir, position: position, from: "ethereal", timestamp: 10.minutes.ago)
    write_recovery(recovery_dir, position: position, from: "ethereal", to: "nado", timestamp: 5.minutes.ago)
    write_dry_run(random_dir, position: position, from: "nado", to: "ethereal")
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: random_dir)

    report = MigrationRandomReadiness.new(position: position, proof_registry: registry, canary_dir: canary_dir).report

    assert_equal "READY_FOR_RANDOM", report.fetch(:route_proof_statuses).find { |route| route[:route] == "ethereal->nado" }.fetch(:status)
    assert_nil report.fetch(:pending_nado_target_continuation)
    assert_equal false, report.fetch(:pending_nado_target_continuation_blocking)
    assert_equal true, report.fetch(:stale_pending_continuation_ignored)
    assert_not_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
    assert_equal "nado->ethereal", report.fetch(:next_recommended_canary).fetch(:route)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
    FileUtils.rm_rf(random_dir) if random_dir
  end

  private

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
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "1.18",
      extended_status: "flat",
      ethereal_status: "flat",
      nado_status: "active",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 0
    )
    position
  end

  def write_ready_canary(dir, position:, from:, to:)
    write_event(dir, {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: Time.current.iso8601
    })
  end

  def write_pending_nado_canary(dir, position:, from:, timestamp:)
    write_event(dir, {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: "nado",
      final_status: "TARGET_ACCEPTED_AWAITING_CONTINUATION",
      target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
      continuation_pending: true,
      nado_target_digest: "0xnado-target",
      exchange_order_ids: [ "0xnado-target" ],
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: timestamp.iso8601
    })
  end

  def write_recovery(dir, position:, from:, to:, timestamp:)
    write_event(dir, {
      action: "recover_target_first_source_close",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      lifecycle_state: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      readback_confirmed: true,
      target_confirmed: true,
      source_already_flat: true,
      other_venues_flat: true,
      third_venue_flat: true,
      open_orders_clear_after: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      manual_action_required: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      timestamp: timestamp.iso8601
    })
  end

  def write_dry_run(dir, position:, from:, to:)
    write_event(dir, {
      action: "random_migration_rehearsal",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: "dry_run",
      timestamp: Time.current.iso8601,
      orders_submitted: 0,
      signatures_created: 0
    })
  end

  def write_event(dir, event)
    FileUtils.mkdir_p(dir)
    File.open(Pathname(dir).join("20260601.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end
end
