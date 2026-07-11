require "test_helper"

class MigrationRouteProofRegistryTest < ActiveSupport::TestCase
  test "readback reconciliation receipt marks route ready with zero safety counters" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "extended",
      to_venue: "ethereal",
      final_status: "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "extended", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal "ethereal", route.fetch(:final_venue)
    assert_equal 0, route.fetch(:orders_submitted)
    assert_equal 0, route.fetch(:orders_placed)
    assert_equal 0, route.fetch(:signatures_created)
    assert_empty route.fetch(:blockers)
  end

  test "target_first canary certified by authoritative fill and readback agreement is READY_FOR_RANDOM" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary", timestamp: 2.hours.ago.utc.iso8601, position_id: position.id,
      from_venue: "ethereal", to_venue: "extended", final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true, source_leg_readback_confirmed: true, final_inside_tolerance: true,
      source_flat_after: true, target_holds_expected_short: true, open_orders_after: 0, production_venue_finalized: true,
      # window ended on the authoritative fill (~2s), not the slow position readback
      double_exposure_seconds: "2", double_exposure_end_source: "authoritative_fill",
      source_close_confirmation_source: "ethereal_order_list_fill", source_close_fill_readback_agreement: true,
      route_production_safe: true, orders_submitted: 1, orders_placed: 1, signatures_created: 1, cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "extended")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  end

  test "target_first canary whose fill disagrees with final readback is not READY_FOR_RANDOM" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary", timestamp: 2.hours.ago.utc.iso8601, position_id: position.id,
      from_venue: "ethereal", to_venue: "extended", final_status: "FAILED_NEEDS_REPAIR",
      live: true, manual_action_required: true,
      source_close_fill_readback_agreement: false, double_exposure_end_source: "position_readback",
      source_flat_after: false, target_holds_expected_short: false, final_inside_tolerance: false,
      production_venue_finalized: false, orders_submitted: 1, orders_placed: 1, signatures_created: 1
    )

    route = registry.route_status(position: position, from: "ethereal", to: "extended")

    refute_equal "READY_FOR_RANDOM", route.fetch(:status)
  end

  test "readback reconciliation receipt without source flat proof is not ready" do
    position = position_with_snapshot("nado")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "extended",
      to_venue: "nado",
      final_status: "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: false,
      final_inside_tolerance: true,
      source_flat_after: false,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "extended", to: "nado")

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_includes route.fetch(:blockers), "extended->nado temporarily disabled pending latency fix/proof."
  end

  test "safe finalized Nado target recovery still requires latency proof for random" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("recoveries")).write(
      action: "recover_target_first_source_close",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      production_venue: "nado",
      source_already_flat: true,
      target_confirmed: true,
      other_venues_flat: true,
      third_venue_flat: true,
      open_orders_clear_after: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      cancels_submitted: 0
    )

    report = registry.report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "ethereal->nado" }

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_includes route.fetch(:blockers), "ethereal->nado temporarily disabled pending latency fix/proof."
    assert_equal true, route.fetch(:route_enabled)
    assert_equal "source_first", route.fetch(:route_strategy)
    assert_nil route[:route_disabled_reason]
    assert_not_includes report.fetch(:completed_route_proofs).map { |entry| entry[:route] }, "ethereal->nado"
    assert report.fetch(:missing_route_proofs).any? { |entry| entry[:route] == "ethereal->nado" }
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "source first Nado late readback finalization can mark route ready when latency proof is safe" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      manual_action_required: false,
      route_production_safe: true,
      source_flat_to_nado_submit_started_seconds: "0.02",
      source_flat_to_nado_submit_finished_seconds: "0.15",
      nado_accept_to_confirmed_seconds: "8",
      underhedge_seconds: "8",
      double_exposure_seconds: "0",
      total_migration_latency_seconds: "12",
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "source first Nado proof ignores non-risk total latency when source flat to target confirmed is safe" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      migration_sequence: "source_first",
      final_status: "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      manual_action_required: false,
      route_production_safe: true,
      source_flat_to_target_confirmed_seconds: "4",
      source_flat_to_finalized_seconds: "4",
      underhedge_seconds: "4",
      double_exposure_seconds: "0",
      total_migration_latency_seconds: "96",
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "source first Nado proof can use fast execution confirmation when final readback later matches" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      migration_sequence: "source_first",
      final_status: "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_complete_by_readback: true,
      manual_action_required: false,
      route_production_safe: true,
      target_confirmation_source: "archive_order",
      target_execution_confirmed_at: Time.current.utc.iso8601,
      source_flat_to_execution_confirmed_seconds: "4",
      source_flat_to_target_confirmed_seconds: "27",
      source_flat_to_position_confirmed_seconds: "27",
      underhedge_seconds: "4",
      double_exposure_seconds: "0",
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2,
      cancels_submitted: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "newer archive backed source first Nado latency proof overrides older recovery latency blocker" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("recoveries")).write(
      action: "recover_target_first_source_close",
      timestamp: 2.days.ago.utc.change(hour: 20, min: 34, sec: 48).iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      final_status: "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK",
      production_venue: "nado",
      source_already_flat: true,
      target_confirmed: true,
      other_venues_flat: true,
      third_venue_flat: true,
      open_orders_clear_after: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      route_production_safe: false,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )
    latency_path = write_latency_proof(
      dir: dir,
      position: position,
      from: "ethereal",
      timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601,
      source_flat_to_execution_confirmed_seconds: "4.511719"
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal true, route.fetch(:route_production_safe)
    assert_equal "passed", route.fetch(:latency_proof_status)
    assert_equal "nado", route.fetch(:final_venue)
    assert_equal "archive_order", route.fetch(:target_confirmation_source)
    assert_equal "4.511719", route.fetch(:source_flat_to_execution_confirmed_seconds)
    assert_equal latency_path.to_s, route.fetch(:latency_proof_receipt)
    assert_equal latency_path.to_s, route.fetch(:finalization_receipt)
    assert_equal 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601, route.fetch(:proof_timestamp)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "failed latency proof remains not production safe" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_latency_proof(
      dir: dir,
      position: position,
      from: "ethereal",
      timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601,
      source_flat_to_execution_confirmed_seconds: "14",
      route_production_safe: false,
      latency_proof_status: "failed_latency_threshold"
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", route.fetch(:status)
    assert_equal false, route.fetch(:route_production_safe)
    assert_equal "failed_latency_threshold", route.fetch(:latency_proof_status)
    assert_match(/ethereal->nado temporarily disabled pending latency fix\/proof/, route.fetch(:blockers).join(" "))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "dry run latency proof receipt does not downgrade ready route" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_latency_proof(dir: dir, position: position, from: "ethereal", timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("latency_proofs")).write(
      action: "prove_route_latency",
      timestamp: 1.day.ago.utc.change(hour: 13, min: 0, sec: 0).iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      strategy: "source_first",
      migration_sequence: "source_first",
      final_status: "dry_run",
      route_latency_proof: false,
      dry_run: true,
      route_production_safe: false,
      production_safe: false,
      double_exposure_seconds: "0",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal true, route.fetch(:route_production_safe)
    assert_empty route.fetch(:blockers)
    assert_equal 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601, route.fetch(:proof_timestamp)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "dry run source first Nado receipt with zero double exposure does not create latency blocker" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("latency_proofs")).write(
      action: "prove_route_latency",
      timestamp: 1.day.ago.utc.change(hour: 13, min: 0, sec: 0).iso8601,
      position_id: position.id,
      from_venue: "ethereal",
      to_venue: "nado",
      strategy: "source_first",
      migration_sequence: "source_first",
      final_status: "dry_run",
      route_latency_proof: false,
      dry_run: true,
      double_exposure_seconds: "0",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )

    route = registry.route_status(position: position, from: "ethereal", to: "nado")

    assert_equal "NOT_STARTED", route.fetch(:status)
    assert_no_match(/double_exposure_seconds=0/, route.fetch(:blockers).join(" "))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "later non proof manual canary does not downgrade existing ready route" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "LIVE_CANARY_CONFIRMED",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_production_safe: true,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: 1.day.ago.utc.change(hour: 13, min: 0, sec: 0).iso8601,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "LIVE_CANARY_CONFIRMED",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_production_safe: false,
      total_migration_latency_seconds: "96",
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )

    route = registry.route_status(position: position, from: "nado", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
    assert_equal 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601, route.fetch(:proof_timestamp)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "stale no submit failed needs repair receipt does not override older ready proof" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    ready_timestamp = 3.days.ago.utc.iso8601
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: ready_timestamp,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "LIVE_CANARY_CONFIRMED",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_production_safe: true,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )
    ignored_path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: (3.days.ago + 1.hour).utc.iso8601,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "FAILED_NEEDS_REPAIR",
      production_venue: "nado",
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    )

    route = registry.route_status(position: position, from: "nado", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
    assert_equal ignored_path.to_s, route.fetch(:ignored_failed_receipt)
    assert_equal "no_submit_no_final_readback", route.fetch(:ignored_failed_reason)
    assert_equal ready_timestamp, route.fetch(:proof_timestamp)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "real failed live proof with unsafe readback can downgrade ready route" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    earlier = 3.days.ago.utc.iso8601
    later = (3.days.ago + 1.hour).utc.iso8601
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: earlier,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "LIVE_CANARY_CONFIRMED",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_production_safe: true,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: later,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "FAILED_NEEDS_REPAIR",
      live: true,
      manual_action_required: true,
      final_inside_tolerance: false,
      source_flat_after: false,
      target_holds_expected_short: false,
      production_venue_finalized: false,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1
    )

    route = registry.route_status(position: position, from: "nado", to: "ethereal")

    assert_equal "FAILED_NEEDS_REPAIR", route.fetch(:status)
    assert_includes route.fetch(:blockers), "nado->ethereal latest proof failed and needs repair."
    assert_nil route.fetch(:ignored_failed_reason)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "clean live canary after failed production proof restores ready" do
    position = position_with_snapshot("ethereal")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    earlier = 3.days.ago.utc.iso8601
    later = (3.days.ago + 1.hour).utc.iso8601
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: earlier,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "FAILED_NEEDS_REPAIR",
      live: true,
      manual_action_required: true,
      final_inside_tolerance: false,
      source_flat_after: false,
      target_holds_expected_short: false,
      production_venue_finalized: false,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1
    )
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary",
      timestamp: later,
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "LIVE_CANARY_CONFIRMED",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      production_venue_finalized: true,
      route_production_safe: true,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2
    )

    route = registry.route_status(position: position, from: "nado", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
    assert_equal later, route.fetch(:proof_timestamp)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "ethereal Nado latency proof does not make extended Nado route ready" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_ETHEREAL_TO_NADO_STRATEGY", enabled: "source_first")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_EXTENDED_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_EXTENDED_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_latency_proof(dir: dir, position: position, from: "ethereal", timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601)
    write_latency_proof(
      dir: dir,
      position: position,
      from: "extended",
      timestamp: 1.day.ago.utc.change(hour: 11, min: 0, sec: 0).iso8601,
      source_flat_to_execution_confirmed_seconds: "18",
      route_production_safe: false,
      latency_proof_status: "failed_latency_threshold"
    )

    ethereal_route = registry.route_status(position: position, from: "ethereal", to: "nado")
    extended_route = registry.route_status(position: position, from: "extended", to: "nado")

    assert_equal "READY_FOR_RANDOM", ethereal_route.fetch(:status)
    assert_equal "NOT_PRODUCTION_SAFE_LATENCY", extended_route.fetch(:status)
    assert_match(/extended->nado temporarily disabled pending latency fix\/proof/, extended_route.fetch(:blockers).join(" "))
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "extended Nado archive backed latency proof is ready with same generic source first logic" do
    position = position_with_snapshot("nado")
    OperationalSettings.set!(key: "MIGRATION_ROUTE_EXTENDED_TO_NADO_ENABLED", enabled: true)
    OperationalSettings.set!(key: "MIGRATION_ROUTE_EXTENDED_TO_NADO_STRATEGY", enabled: "source_first")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_latency_proof(dir: dir, position: position, from: "extended", timestamp: 1.day.ago.utc.change(hour: 12, min: 0, sec: 0).iso8601)

    route = registry.route_status(position: position, from: "extended", to: "nado")

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal true, route.fetch(:route_production_safe)
    assert_equal "nado", route.fetch(:final_venue)
    assert_equal "archive_order", route.fetch(:target_confirmation_source)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "route proof report diagnoses all route policies disabled" do
    position = position_with_snapshot("ethereal")
    OperationalSettings::ROUTE_KEYS.each { |key| OperationalSettings.set!(key: key, enabled: false) }
    report = registry_for(Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")).report(position: position)

    assert_equal "all_disabled", report.fetch(:route_policy_health)
    assert_equal "Route policies are disabled. Use migration:route_policy_restore_defaults.", report.fetch(:route_policy_blocker)

    MigrationRouteOperationalPolicy.new.restore_defaults!(confirmation: MigrationRouteOperationalPolicy::RESTORE_CONFIRMATION)
    repaired = registry_for(Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")).report(position: position)

    assert_equal "ok", repaired.fetch(:route_policy_health)
    assert_nil repaired.fetch(:route_policy_blocker)
  end

  # --- Production random cycle proof ingestion ---

  test "successful production cycle marks each rotation route ready from cycle evidence" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    [ [ "extended", "ethereal" ], [ "ethereal", "nado" ], [ "nado", "extended" ] ].each do |from, to|
      write_production_cycle(dir: dir, position: position, from: from, to: to, timestamp: 2.hours.ago.utc.iso8601)
    end

    [ [ "extended", "ethereal" ], [ "ethereal", "nado" ], [ "nado", "extended" ] ].each do |from, to|
      route = registry.route_status(position: position, from: from, to: to)
      assert_equal "READY_FOR_RANDOM", route.fetch(:status), "#{from}->#{to} should be ready"
      assert_equal "production_random_cycle", route.fetch(:proof_source)
      assert_equal to, route.fetch(:final_venue)
      assert_empty route.fetch(:blockers)
      assert route.fetch(:proof_timestamp).present?
    end
  end

  test "newer production cycle overrides an older stale legacy canary receipt" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
      action: "manual_live_canary", timestamp: 45.days.ago.utc.iso8601, position_id: position.id,
      from_venue: "extended", to_venue: "ethereal", final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true, source_leg_readback_confirmed: true, final_inside_tolerance: true,
      source_flat_after: true, target_holds_expected_short: true, open_orders_after: 0, production_venue_finalized: true,
      orders_submitted: 2, orders_placed: 2, signatures_created: 2, cancels_submitted: 0
    )
    stale = registry.route_status(position: position, from: "extended", to: "ethereal")
    assert_equal "STALE", stale.fetch(:status)

    write_production_cycle(dir: dir, position: position, from: "extended", to: "ethereal", timestamp: 1.hour.ago.utc.iso8601)
    refreshed = registry_for(dir).route_status(position: position, from: "extended", to: "ethereal")

    assert_equal "READY_FOR_RANDOM", refreshed.fetch(:status)
    assert_equal "production_random_cycle", refreshed.fetch(:proof_source)
  end

  test "blocked production cycle does not refresh proof" do
    assert_production_cycle_not_ready(status: "blocked", blockers: [ "route result is partial" ])
  end

  test "production cycle with blockers does not refresh proof" do
    assert_production_cycle_not_ready(blockers: [ "target venue does not hold expected short" ])
  end

  test "production cycle with final_inside_tolerance false does not refresh proof" do
    assert_production_cycle_not_ready(execution: { final_inside_tolerance: false })
  end

  test "production cycle with nonzero open orders does not refresh proof" do
    assert_production_cycle_not_ready(execution: { open_orders_after: 2 })
  end

  test "production cycle with unknown open orders does not refresh proof" do
    assert_production_cycle_not_ready(execution: { open_orders_clear_after: nil, open_orders_after: nil })
  end

  test "production cycle with source not flat does not refresh proof" do
    assert_production_cycle_not_ready(execution: { source_flat_after: false, source_flat_confirmed: false })
  end

  test "production cycle with manual intervention does not refresh proof" do
    assert_production_cycle_not_ready(execution: { manual_action_required: true })
  end

  test "production cycle with target venue not finalized does not refresh proof" do
    assert_production_cycle_not_ready(execution: { production_venue_finalized: false })
  end

  test "production cycle finalized to the wrong venue does not refresh proof" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_production_cycle(dir: dir, position: position, from: "extended", to: "ethereal", timestamp: 1.hour.ago.utc.iso8601)
    # Corrupt the post_cycle_hedge production_venue via a second, wrong-venue cycle would
    # differ; here we assert the happy path already matched, then a mismatch is rejected.
    path = dir.join("production", "wrongvenue_position_#{position.id}.jsonl")
    File.write(path, JSON.generate(
      "event" => "cycle", "cycle" => 9, "started_at" => 30.minutes.ago.utc.iso8601,
      "from_venue" => "extended", "to_venue" => "nado", "route" => "extended->nado", "status" => "success", "blockers" => [],
      "execution" => { "status" => "MIGRATION_FINALIZED", "source_flat_after" => true, "target_holds_expected_short" => true,
        "third_venue_flat" => true, "open_orders_clear_after" => true, "open_orders_after" => 0, "final_inside_tolerance" => true,
        "production_venue_finalized" => true, "manual_action_required" => false },
      "post_cycle_hedge" => { "production_venue" => "ethereal" }
    ) + "\n")

    route = registry.route_status(position: position, from: "extended", to: "nado")
    refute_equal "READY_FOR_RANDOM", route.fetch(:status)
  end

  test "stale production cycle outside the freshness window does not refresh proof" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_production_cycle(dir: dir, position: position, from: "extended", to: "ethereal", timestamp: 45.days.ago.utc.iso8601)

    route = registry.route_status(position: position, from: "extended", to: "ethereal")

    assert_equal "STALE", route.fetch(:status)
  end

  # Regression for the real production scenario: legacy June canary receipts have
  # gone stale, but the runner has newer successful production cycles for the
  # rotation routes. Those routes must report READY_FOR_RANDOM from the cycle.
  test "regression: stale legacy receipts do not block routes with fresh production cycle evidence" do
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    rotation = [ [ "extended", "ethereal" ], [ "ethereal", "nado" ], [ "nado", "extended" ] ]
    rotation.each do |from, to|
      HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("canaries")).write(
        action: "manual_live_canary", timestamp: 31.days.ago.utc.iso8601, position_id: position.id,
        from_venue: from, to_venue: to, final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
        target_leg_readback_confirmed: true, source_leg_readback_confirmed: true, final_inside_tolerance: true,
        source_flat_after: true, target_holds_expected_short: true, open_orders_after: 0, production_venue_finalized: true,
        orders_submitted: 2, orders_placed: 2, signatures_created: 2, cancels_submitted: 0
      )
      write_production_cycle(dir: dir, position: position, from: from, to: to, timestamp: 3.hours.ago.utc.iso8601)
    end

    report = registry_for(dir).report(position: position)
    ready_routes = report.fetch(:completed_route_proofs).map { |route| route[:route] }

    rotation.each { |from, to| assert_includes ready_routes, "#{from}->#{to}" }
    report.fetch(:completed_route_proofs).each do |route|
      next unless rotation.include?([ route[:from_venue], route[:to_venue] ])

      assert_equal "production_random_cycle", route[:proof_source]
    end
  end

  private

  def assert_production_cycle_not_ready(status: "success", execution: {}, blockers: [])
    position = position_with_snapshot("extended")
    dir = Rails.root.join("tmp/route-proof-registry-#{SecureRandom.hex(4)}")
    registry = registry_for(dir)
    write_production_cycle(dir: dir, position: position, from: "extended", to: "ethereal",
      timestamp: 1.hour.ago.utc.iso8601, status: status, execution: execution, blockers: blockers)

    route = registry.route_status(position: position, from: "extended", to: "ethereal")

    refute_equal "READY_FOR_RANDOM", route.fetch(:status)
    refute_equal "production_random_cycle", route.fetch(:proof_source)
  end

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

  # Writes a production runner "cycle" JSONL event (the real shape the runner
  # emits, with readback evidence nested under "execution" and stamped with
  # "started_at"). Overrides let negative tests corrupt a single field.
  def write_production_cycle(dir:, position:, from:, to:, timestamp:, status: "success", execution: {}, blockers: [])
    FileUtils.mkdir_p(dir.join("production"))
    default_execution = {
      "status" => "MIGRATION_FINALIZED",
      "source_flat_after" => true,
      "target_holds_expected_short" => true,
      "third_venue_flat" => true,
      "open_orders_clear_after" => true,
      "open_orders_after" => 0,
      "final_inside_tolerance" => true,
      "production_venue_finalized" => true,
      "manual_action_required" => false,
      "orders_submitted" => 1,
      "orders_placed" => 1,
      "signatures_created" => 1
    }
    event = {
      "event" => "cycle",
      "cycle" => 7,
      "started_at" => timestamp,
      "from_venue" => from,
      "to_venue" => to,
      "route" => "#{from}->#{to}",
      "status" => status,
      "blockers" => blockers,
      "execution" => default_execution.merge(execution.transform_keys(&:to_s)),
      "post_cycle_hedge" => { "production_venue" => to }
    }
    path = dir.join("production", "#{timestamp.tr(':-', '').tr('TZ', '_')}_position_#{position.id}.jsonl")
    File.open(path, "a") { |file| file.puts(JSON.generate(event)) }
    path
  end

  def write_latency_proof(dir:, position:, from:, timestamp:, source_flat_to_execution_confirmed_seconds: "4", route_production_safe: true, latency_proof_status: "passed")
    HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir.join("latency_proofs")).write(
      action: "prove_route_latency",
      timestamp: timestamp,
      position_id: position.id,
      from_venue: from,
      to_venue: "nado",
      strategy: "source_first",
      migration_sequence: "source_first",
      route_latency_proof: true,
      final_status: "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      manual_action_required: false,
      production_venue_finalized: true,
      route_complete_by_readback: true,
      source_flat_after: true,
      source_close_confirmed: true,
      target_holds_expected_short: true,
      target_confirmed: true,
      third_venue_flat: true,
      other_venues_flat: true,
      combined_inside_tolerance: true,
      final_inside_tolerance: true,
      open_orders_clear: true,
      open_orders_clear_after: true,
      open_orders_after: 0,
      route_production_safe: route_production_safe,
      production_safe_route: route_production_safe,
      production_safe: route_production_safe,
      latency_proof_status: latency_proof_status,
      target_confirmation_source: "archive_order",
      target_execution_confirmed_at: timestamp,
      source_flat_to_execution_confirmed_seconds: source_flat_to_execution_confirmed_seconds,
      source_flat_to_target_confirmed_seconds: "27",
      source_flat_to_position_confirmed_seconds: "27",
      source_flat_to_finalized_seconds: "28",
      double_exposure_seconds: "0",
      underhedge_seconds: source_flat_to_execution_confirmed_seconds,
      orders_submitted: 2,
      orders_placed: 2,
      signatures_created: 2,
      cancels_submitted: 0
    )
  end

  def position_with_snapshot(venue)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "500",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(6),
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: venue)
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: venue,
      selected_venue: venue,
      target_short_eth: "1",
      tolerance_abs_eth: "0.05",
      combined_short_eth: "1",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: venue == "nado" ? "1" : "0",
      signer_status: "ok"
    )
    position
  end
end
