require "test_helper"

class MigrationRandomSystemTest < ActiveSupport::TestCase
  test "random planner from Nado selects only Nado source routes" do
    result = random_planner.plan(position: migration_position("nado"))

    assert_empty result.blockers
    assert_equal %w[nado->ethereal nado->extended], result.receipt.fetch(:eligible_routes).map { |route| route.fetch(:route) }.sort
    assert result.receipt.fetch(:selected_route).fetch(:route).in?(%w[nado->ethereal nado->extended])
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "random planner excludes current source routes when source is flat or preview missing" do
    matrix = {
      routes: [
        route("nado", "ethereal", route_status: "READY_FOR_DRY_RUN", preview_available: true),
        route("nado", "extended", route_status: "PREVIEW_BLOCKED", preview_available: false),
        route("ethereal", "nado", route_status: "READY_FOR_DRY_RUN", preview_available: true)
      ]
    }
    result = random_planner(route_matrix: matrix).plan(position: migration_position("nado"))

    assert_equal [ "nado->ethereal" ], result.receipt.fetch(:eligible_routes).map { |candidate| candidate.fetch(:route) }
    excluded = result.receipt.fetch(:excluded_routes)
    assert excluded.any? { |candidate| candidate.fetch(:route) == "nado->extended" && candidate.fetch(:reasons).include?("route preview unavailable") }
    assert_empty excluded.select { |candidate| candidate.fetch(:route) == "ethereal->nado" }
  end

  test "random rehearsal builds target-first plan and writes no-live receipt" do
    position = migration_position("nado")
    result = MigrationRandomRehearsal.new(planner: random_planner(selector: ->(_) { "nado->ethereal" })).run(position: position)

    assert_equal "dry_run", result.status, result.blockers.inspect
    assert_equal "nado->ethereal", result.receipt.fetch(:route)
    assert_equal "ethereal", result.receipt.fetch(:target_leg_preview).fetch(:venue)
    assert_equal "nado", result.receipt.fetch(:source_close_preview).fetch(:venue)
    assert_equal "target_first", result.receipt.fetch(:migration_sequence)
    assert_match %r{storage/hedge_migration_random_rehearsals}, result.receipt.fetch(:receipt_path)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "route proof registry tracks all six statuses" do
    route_dir = Rails.root.join("tmp/test-route-proofs-#{SecureRandom.hex(4)}")
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(route_dir, {
      action: "random_migration_rehearsal",
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "dry_run",
      timestamp: Time.current.iso8601,
      orders_submitted: 0,
      signatures_created: 0
    })
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended"))

    report = MigrationRouteProofRegistry.new(route_proof_dir: route_dir, canary_dir: canary_dir, recovery_dir: route_dir, random_dir: route_dir).report(position: position)

    assert_equal 6, report.fetch(:routes).size
    assert_equal "READY_FOR_RANDOM", report.fetch(:routes).find { |route| route[:route] == "nado->extended" }.fetch(:status)
    assert_equal "NOT_STARTED", report.fetch(:routes).find { |route| route[:route] == "extended->ethereal" }.fetch(:status)
  ensure
    FileUtils.rm_rf(route_dir) if route_dir
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "partial live canary without recovery remains failed needs repair" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended"))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "FAILED_NEEDS_REPAIR", route.fetch(:status)
    assert_equal true, route.fetch(:manual_intervention)
    assert_includes route.fetch(:blockers), "nado->extended latest proof failed and needs repair."
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "partial canary plus source close recovery finalization becomes ready for random" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago))
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", source_already_flat: false, source_close_confirmed: true))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal false, route.fetch(:manual_intervention)
    assert_match(%r{test-recovery-proofs}, route.fetch(:recovery_receipt))
    assert_match(%r{test-recovery-proofs}, route.fetch(:finalization_receipt))
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "incident partial canary plus source already flat recovery finalization is not failed" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago, orders_submitted: 2))
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", source_already_flat: true, orders_submitted: 0, signatures_created: 0))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_not_equal "FAILED_NEEDS_REPAIR", route.fetch(:status)
    assert_equal "extended", route.fetch(:final_venue)
    assert_equal 0, route.fetch(:orders_submitted)
    assert_equal 0, route.fetch(:signatures_created)
    assert_equal true, route.fetch(:final_readback_summary).fetch(:production_venue_finalized)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "old recovery receipt plus later clean live canary becomes ready for random" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", timestamp: 20.minutes.ago))
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago, production_venue: "extended", orders_submitted: 2, signatures_created: 2))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal "extended", route.fetch(:final_venue)
    assert_match(%r{test-canary-proofs}, route.fetch(:finalization_receipt))
    assert_empty route.fetch(:blockers)
    assert_equal 2, route.fetch(:orders_submitted)
    assert_equal 2, route.fetch(:signatures_created)
    assert_includes report.fetch(:completed_route_proofs).map { |entry| entry[:route] }, "nado->extended"
    assert_not report.fetch(:missing_route_proofs).any? { |entry| entry[:route] == "nado->extended" }
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "nado extended clean live canary fixture is ready and finalizes to extended" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended", final_status: "LIVE_CANARY_CONFIRMED", production_venue: "nado", orders_submitted: 2, signatures_created: 2))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_equal "extended", route.fetch(:final_venue)
    assert_match(%r{test-canary-proofs}, route.fetch(:live_canary_receipt))
    assert_match(%r{test-canary-proofs}, route.fetch(:finalization_receipt))
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "clean live canary final venue is route target for every route" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    MigrationLiveRouteCapability::ROUTES.each do |from, to|
      write_event(canary_dir, live_canary_event(position: position, from: from, to: to, production_venue: from))
    end

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)

    MigrationLiveRouteCapability::ROUTES.each do |from, to|
      route = report.fetch(:routes).find { |entry| entry[:route] == "#{from}->#{to}" }
      assert_equal "READY_FOR_RANDOM", route.fetch(:status)
      assert_equal to, route.fetch(:final_venue), "#{from}->#{to} final venue should be route target"
    end
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "recovery-only route is ready when recovery finalization is safe" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended"))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "failed live receipt after recovery does not override recovery proof" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", timestamp: 20.minutes.ago))
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_match(%r{test-recovery-proofs}, route.fetch(:finalization_receipt))
    assert_not_includes route.fetch(:blockers), "nado->extended latest proof failed and needs repair."
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "manual exchange intervention recovery receipt does not mark route recovery proven" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago))
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended").merge(manual_exchange_intervention: true))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "FAILED_NEEDS_REPAIR", route.fetch(:status)
    assert_nil route.fetch(:recovery_receipt)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness counts safe recovery proof as completed route" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(canary_dir, partial_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago))
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", source_already_flat: true))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry).report
    route = report.fetch(:route_proof_statuses).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert report.fetch(:completed_route_proofs).any? { |entry| entry[:route] == "nado->extended" }
    assert_not report.fetch(:missing_route_proofs).any? { |entry| entry[:route] == "nado->extended" }
    assert_not_includes route.fetch(:blockers), "nado->extended latest proof failed and needs repair."
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness treats later clean canary as completed route proof" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(recovery_dir, recovery_event(position: position, from: "nado", to: "extended", timestamp: 20.minutes.ago))
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended", timestamp: 5.minutes.ago, production_venue: "extended"))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry).report
    route = report.fetch(:route_proof_statuses).find { |entry| entry[:route] == "nado->extended" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert report.fetch(:completed_route_proofs).any? { |entry| entry[:route] == "nado->extended" }
    assert_not report.fetch(:missing_route_proofs).any? { |entry| entry[:route] == "nado->extended" }
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "route proof registry treats completed Nado target continuation as ready for random" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    continuation_dir = Rails.root.join("tmp/test-continuation-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "ethereal", timestamp: 10.minutes.ago))
    write_event(continuation_dir, continuation_event(position: position, from: "ethereal", timestamp: 5.minutes.ago))

    report = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, continuation_dir: continuation_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir).report(position: position)
    route = report.fetch(:routes).find { |entry| entry[:route] == "ethereal->nado" }

    assert_equal "READY_FOR_RANDOM", route.fetch(:status)
    assert_match(%r{test-continuation-proofs}, route.fetch(:finalization_receipt))
    assert_equal "nado", route.fetch(:final_venue)
    assert_empty route.fetch(:blockers)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
    FileUtils.rm_rf(continuation_dir) if continuation_dir
  end

  test "random readiness blocks while Nado target continuation is pending and shows command" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("ethereal")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "ethereal"))

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, canary_dir: canary_dir).report

    assert_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
    pending = report.fetch(:pending_nado_target_continuation)
    assert_equal "ethereal->nado", pending.fetch(:route)
    assert_match "migration:continue_target_first_after_nado_confirmed", pending.fetch(:continuation_command)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "random readiness suppresses pending Nado continuation when route proof is ready by continuation" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    continuation_dir = Rails.root.join("tmp/test-continuation-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "extended"))
    write_event(continuation_dir, continuation_event(position: position, from: "extended"))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, continuation_dir: continuation_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report

    assert_equal "READY_FOR_RANDOM", report.fetch(:route_proof_statuses).find { |route| route[:route] == "extended->nado" }.fetch(:status)
    assert_nil report.fetch(:pending_nado_target_continuation)
    assert_not_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(continuation_dir) if continuation_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness ignores stale Nado continuation when route is ready and readback is safe" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    proof_dir = Rails.root.join("tmp/test-ready-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("extended")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "extended", timestamp: 10.minutes.ago))
    write_event(proof_dir, live_canary_event(position: position, from: "extended", to: "nado", timestamp: 5.minutes.ago, production_venue: "nado"))
    position.position_dashboard_snapshot.update!(
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: "1.18",
      nado_short_eth: "0",
      combined_short_eth: "1.18",
      drift_eth: "0",
      inside_tolerance: true,
      open_orders_count_extended: 0
    )
    registry = MigrationRouteProofRegistry.new(canary_dir: proof_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report

    assert_equal "READY_FOR_RANDOM", report.fetch(:route_proof_statuses).find { |route| route[:route] == "extended->nado" }.fetch(:status)
    assert_nil report.fetch(:pending_nado_target_continuation)
    assert_equal true, report.fetch(:stale_pending_continuation_ignored)
    assert_not_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(proof_dir) if proof_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness still blocks when matching Nado continuation failed" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    continuation_dir = Rails.root.join("tmp/test-continuation-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "extended"))
    write_event(continuation_dir, continuation_event(position: position, from: "extended", final_status: "CONTINUATION_BLOCKED", target_confirmed: false))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, continuation_dir: continuation_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report

    assert_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
    assert_equal "extended->nado", report.fetch(:pending_nado_target_continuation).fetch(:route)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(continuation_dir) if continuation_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness resolves Nado continuation by pending migration id" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    continuation_dir = Rails.root.join("tmp/test-continuation-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    pending = partial_nado_target_canary_event(position: position, from: "extended").merge(pending_migration_id: "pending-123", nado_target_digest: "0xold")
    write_event(canary_dir, pending)
    write_event(continuation_dir, continuation_event(position: position, from: "extended", pending_migration_id: "pending-123", digest: "0xdifferent"))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, continuation_dir: continuation_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report

    assert_nil report.fetch(:pending_nado_target_continuation)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(continuation_dir) if continuation_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness resolves Nado continuation by target digest" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    continuation_dir = Rails.root.join("tmp/test-continuation-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "ethereal").merge(pending_migration_id: "pending-123"))
    write_event(continuation_dir, continuation_event(position: position, from: "ethereal", pending_migration_id: nil, digest: "0xnado-target"))
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, continuation_dir: continuation_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: recovery_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report

    assert_nil report.fetch(:pending_nado_target_continuation)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(continuation_dir) if continuation_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
  end

  test "random readiness is actionable and blocks live while proofs are missing" do
    report = MigrationRandomReadiness.new(position: migration_position("nado"), planner: random_planner).report

    assert_equal true, report.fetch(:random_engine_implemented)
    assert_equal "nado", report.fetch(:current_production_venue)
    assert report.fetch(:next_recommended_canary)
    assert_match(/bin\/rails migration:rehearse_route/, report.fetch(:operator_commands).fetch(:next_canary_dry_run))
    assert_match(/bin\/rails migration:run_manual_live_canary/, report.fetch(:operator_commands).fetch(:next_canary_live))
    assert_equal false, report.fetch(:current_safe_to_live_if_operator_gates_open)
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end

  test "historical pre-fix Nado confirmation failures do not block readiness when current state is otherwise rehearsable" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "1.1",
      new_short_size: "1.1",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_FAILED,
      message: "submitted confirmation must equal I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_ORDERS",
      rebalanced_at: 1.day.ago
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_equal 1, report.dig(:nado_auto_summary, :historical_prefix_confirmation_failed_count)
    assert_equal true, report.fetch(:current_safe_to_rehearse)
    assert_not_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
  end

  test "pending Nado rebalance blocks random readiness" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "1.1",
      new_short_size: "1.1",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_PENDING,
      message: "pending digest",
      rebalanced_at: Time.current
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
  end

  test "stale acknowledged Nado pending does not block random readiness" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "0.483",
      new_short_size: "0.483",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_STALE_SUPERSEDED,
      message: "Nado stale pending acknowledged",
      rebalanced_at: 8.days.ago
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_not_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
    assert_nil report.dig(:nado_auto_summary, :latest_nado_pending)
    assert_equal 1, report.dig(:nado_auto_summary, :stale_acknowledged_nado_pending_count)
  end

  test "confirmed later Nado pending row no longer appears as latest pending" do
    position = migration_position("nado")
    position.hedge.short_rebalances.create!(
      asset: "WETH",
      venue: "nado",
      old_short_size: "1.0",
      new_short_size: "1.1",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      message: "Confirmed by later Nado readback",
      rebalanced_at: Time.current
    )

    report = MigrationRandomReadiness.new(position: position, planner: random_planner).report

    assert_nil report.dig(:nado_auto_summary, :latest_nado_pending)
    assert_not_includes report.fetch(:blockers), "pending ShortRebalance must be resolved before random migration"
  end

  test "current recovery-finalized Ethereal to Nado route leaves Nado to Ethereal as next canary" do
    canary_dir = Rails.root.join("tmp/test-canary-proofs-#{SecureRandom.hex(4)}")
    recovery_dir = Rails.root.join("tmp/test-recovery-proofs-#{SecureRandom.hex(4)}")
    random_dir = Rails.root.join("tmp/test-random-proofs-#{SecureRandom.hex(4)}")
    position = migration_position("nado")
    write_event(canary_dir, live_canary_event(position: position, from: "extended", to: "ethereal", production_venue: "ethereal"))
    write_event(canary_dir, live_canary_event(position: position, from: "ethereal", to: "extended", production_venue: "extended"))
    write_event(canary_dir, live_canary_event(position: position, from: "extended", to: "nado", production_venue: "nado"))
    write_event(canary_dir, live_canary_event(position: position, from: "nado", to: "extended", production_venue: "extended"))
    write_event(canary_dir, partial_nado_target_canary_event(position: position, from: "ethereal", timestamp: 10.minutes.ago))
    write_event(recovery_dir, recovery_event(position: position, from: "ethereal", to: "nado", timestamp: 5.minutes.ago, source_already_flat: true, orders_submitted: 0, signatures_created: 0))
    write_event(random_dir, {
      action: "random_migration_rehearsal",
      position_id: position.id,
      from_venue: "nado",
      to_venue: "ethereal",
      final_status: "dry_run",
      timestamp: Time.current.iso8601,
      orders_submitted: 0,
      signatures_created: 0
    })
    registry = MigrationRouteProofRegistry.new(canary_dir: canary_dir, recovery_dir: recovery_dir, route_proof_dir: recovery_dir, random_dir: random_dir)

    report = MigrationRandomReadiness.new(position: position, planner: random_planner, proof_registry: registry, canary_dir: canary_dir).report
    ethereal_nado = report.fetch(:route_proof_statuses).find { |entry| entry[:route] == "ethereal->nado" }

    assert_equal "READY_FOR_RANDOM", ethereal_nado.fetch(:status)
    assert_nil report.fetch(:pending_nado_target_continuation)
    assert_equal true, report.fetch(:stale_pending_continuation_ignored)
    assert_not_includes report.fetch(:blockers), "pending target=Nado migration continuation must be completed before random migration"
    assert_equal "nado->ethereal", report.fetch(:next_recommended_canary).fetch(:route)
    assert_equal "DRY_RUN_PROVEN", report.fetch(:next_recommended_canary).fetch(:status)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
    FileUtils.rm_rf(recovery_dir) if recovery_dir
    FileUtils.rm_rf(random_dir) if random_dir
  end

  test "random burn-in dry run writes JSONL and submits no orders" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = burn_in(position: position, live: false, log_dir: dir).run
    events = read_jsonl(result.receipt_path)

    assert_equal "success", result.status
    assert_equal [ "burn_in_started", "cycle", "burn_in_finished" ], events.map { |event| event.fetch("event") }
    assert_equal 0, events.last.fetch("orders_submitted")
    assert_equal 0, events.last.fetch("signatures_created")
    assert_equal "ethereal", events[1].fetch("from_venue")
    assert events[1].key?("before")
    assert events[1].key?("execution")
    assert events[1].key?("after")
    assert events[1].key?("pre_cycle_target")
    assert events[1].key?("post_cycle_target")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in refreshes LP target before every cycle and after migration" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher).run

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal %w[preflight pre_cycle post_cycle], refresher.stages
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops if LP target refresh fails before cycle" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(fail_on: "pre_cycle")

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "stopped", result.status
    assert_equal "blocked_stale_or_unavailable_lp_target", cycle.fetch("status")
    assert_equal 0, cycle.fetch("execution").fetch("orders_submitted")
    assert_equal 0, cycle.fetch("execution").fetch("signatures_created")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops when target changes more than max allowed" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(target_by_stage: { "post_cycle" => "1.40" })

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher, max_target_change_per_cycle_eth: "0.15").run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "stopped", result.status
    assert_equal "stopped_target_changed_too_much", cycle.fetch("status")
    assert_equal "0.22", cycle.fetch("post_cycle_target").fetch("target_delta_eth")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops before migration when current hedge is outside tolerance and rebalance disabled" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(target_by_stage: { "pre_cycle" => "1.30" })

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher, rebalance_before_cycle: false).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "stopped", result.status
    assert_equal "blocked_before_cycle_out_of_tolerance", cycle.fetch("status")
    assert_equal 0, cycle.fetch("execution").fetch("orders_submitted")
    assert_match "recommended_rebalance_eth", cycle.fetch("blockers").join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in does not reuse stale dashboard snapshot target" do
    position = migration_position("ethereal")
    position.position_dashboard_snapshot.update!(target_short_eth: "0.75")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(target_by_stage: { "preflight" => "1.18", "pre_cycle" => "1.19", "post_cycle" => "1.19" })

    result = burn_in(position: position, live: false, log_dir: dir, snapshot_refresher: refresher).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal "1.19", cycle.fetch("pre_cycle_target").fetch("target_short_eth")
    assert_equal "1.19", cycle.fetch("post_cycle_target").fetch("target_short_eth")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in completes multiple dry-run cycles when target changes slightly inside tolerance" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(target_sequence: [ "1.18", "1.18", "1.19", "1.19", "1.20" ])

    result = burn_in(position: position, live: false, log_dir: dir, snapshot_refresher: refresher, max_cycles: 2).run

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 2, result.summary.fetch(:cycles_succeeded)
    assert_equal "1.18", result.summary.fetch(:initial_target_short_eth)
    assert_equal BigDecimal("1.20"), BigDecimal(result.summary.fetch(:final_target_short_eth))
    assert_equal "0.01", result.summary.fetch(:max_target_delta_eth)
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops if app production venue and actual exposure disagree" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(exposure_by_stage: {
      "pre_cycle" => { "extended" => "0", "ethereal" => "0", "nado" => "1.18" }
    })

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "stopped", result.status
    assert_equal "blocked_unexpected_venue_exposure", cycle.fetch("status")
    assert_includes cycle.fetch("blockers"), "app production venue and actual venue exposure disagree"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops if more than one venue has non-zero short" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(exposure_by_stage: {
      "pre_cycle" => { "extended" => "0", "ethereal" => "1.18", "nado" => "0.10" }
    })

    result = burn_in(position: position, live: true, log_dir: dir, snapshot_refresher: refresher).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "stopped", result.status
    assert_equal "blocked_before_cycle_out_of_tolerance", cycle.fetch("status")
    assert_includes cycle.fetch("blockers"), "more than one venue has exposure"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in final summary includes target stats" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    refresher = BurnInSnapshotRefresher.new(target_by_stage: { "post_cycle" => "1.19" })

    result = burn_in(position: position, live: false, log_dir: dir, snapshot_refresher: refresher).run
    final = read_jsonl(result.receipt_path).last

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal "1.18", final.fetch("initial_target_short_eth")
    assert_equal "1.19", final.fetch("final_target_short_eth")
    assert_equal "0.01", final.fetch("max_target_delta_eth")
    assert_equal 0, final.fetch("target_refresh_failures")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in live requires exact confirmation" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = burn_in(position: position, live: true, confirmation: "wrong", log_dir: dir).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationRandomBurnInRunner::CONFIRMATION}"
    assert_equal "blocked_before_start", read_jsonl(result.receipt_path).first.fetch("status")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in refuses to start if all routes are not ready" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    registry = BurnInProofRegistry.new(missing: [ { route: "nado->ethereal", from_venue: "nado", to_venue: "ethereal", status: "DRY_RUN_PROVEN" } ])

    result = burn_in(position: position, live: false, proof_registry: registry, log_dir: dir).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "all route proofs must be READY_FOR_RANDOM"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in refuses to start when hedge is outside tolerance" do
    position = migration_position("ethereal")
    position.position_dashboard_snapshot.update!(inside_tolerance: false)
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    refresher = BurnInSnapshotRefresher.new(target_by_stage: { "preflight" => "1.30" })

    result = burn_in(position: position, live: false, log_dir: dir, snapshot_refresher: refresher).run

    assert_equal "blocked", result.status
    assert_includes result.blockers, "current hedge must be inside tolerance"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in selects only routes from current production venue" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = burn_in(position: position, live: false, selector: ->(routes) { routes.last.fetch(:route) }, log_dir: dir).run
    cycle = read_jsonl(result.receipt_path).find { |event| event["event"] == "cycle" }

    assert_equal "ethereal", cycle.fetch("from_venue")
    assert_includes %w[extended nado], cycle.fetch("to_venue")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops when after readback source is not flat" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    executor = BurnInExecutor.new(after: ->(pos, from, to) {
      update_burn_in_snapshot(pos, production_venue: to, shorts: { from => "1.18", to => "1.18" })
    })

    result = burn_in(position: position, live: true, executor: executor, log_dir: dir).run

    assert_equal "stopped", result.status, result.blockers.inspect
    assert_match "source venue ethereal is not flat", result.blockers.join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops when target is not confirmed" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    executor = BurnInExecutor.new(after: ->(pos, from, to) {
      update_burn_in_snapshot(pos, production_venue: to, shorts: { from => "0", to => "0" })
    })

    result = burn_in(position: position, live: true, executor: executor, log_dir: dir).run

    assert_equal "stopped", result.status, result.blockers.inspect
    assert_match "target venue", result.blockers.join(" ")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in stops when open orders are non-zero after migration" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")
    executor = BurnInExecutor.new(after: ->(pos, from, to) {
      update_burn_in_snapshot(pos, production_venue: to, shorts: { from => "0", to => "1.18" }, open_orders: 1)
    })

    result = burn_in(position: position, live: true, executor: executor, log_dir: dir).run

    assert_equal "stopped", result.status, result.blockers.inspect
    assert_includes result.blockers, "open orders are non-zero after migration"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in switches active venue auto to target after finalization" do
    OperationalSetting.delete_all
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = burn_in(position: position, live: true, disable_after: false, selector: ->(_) { "ethereal->nado" }, log_dir: dir).run

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in disable after disables random auto and Nado live gates" do
    OperationalSetting.delete_all
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = burn_in(position: position, live: true, disable_after: true, selector: ->(_) { "ethereal->nado" }, log_dir: dir).run

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal false, OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  test "random burn-in blocks while migration lock is active" do
    position = migration_position("ethereal")
    dir = Rails.root.join("tmp/test-burn-in-#{SecureRandom.hex(4)}")

    result = nil
    MigrationExecutionLock.with_lock(position) do
      result = burn_in(position: position, live: false, log_dir: dir).run
    end

    assert_equal "blocked", result.status
    assert_includes result.blockers, "migration lock is already active for this position"
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  private

  def random_planner(route_matrix: ready_matrix, selector: nil)
    MigrationRandomPlanner.new(
      route_matrix: route_matrix,
      proof_registry: EmptyProofRegistry.new,
      random_seed: "seed",
      selector: selector
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
      extended_status: venue == "extended" ? "active" : "flat",
      ethereal_status: venue == "ethereal" ? "active" : "flat",
      nado_status: venue == "nado" ? "active" : "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      signer_status: "ok",
      open_orders_count_extended: 0
    )
    position
  end

  def ready_matrix
    {
      routes: [
        route("nado", "ethereal"),
        route("nado", "extended"),
        route("ethereal", "nado"),
        route("extended", "nado")
      ]
    }
  end

  def route(from, to, route_status: "READY_FOR_DRY_RUN", preview_available: true)
    {
      from_venue: from,
      to_venue: to,
      route_status: route_status,
      preview_available: preview_available,
      target_open_preview_available: preview_available,
      source_close_preview_available: preview_available,
      open_orders_status: "clear",
      blockers: []
    }
  end

  def write_event(dir, event)
    FileUtils.mkdir_p(dir)
    File.open(Pathname(dir).join("20260601.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
  end

  def burn_in(position:, live:, proof_registry: BurnInProofRegistry.new, executor: BurnInExecutor.new, selector: ->(routes) { routes.first.fetch(:route) }, log_dir:, confirmation: MigrationRandomBurnInRunner::CONFIRMATION, disable_after: true, snapshot_refresher: BurnInSnapshotRefresher.new, max_cycles: 1, rebalance_before_cycle: false, max_target_change_per_cycle_eth: "0.15")
    MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: 30,
      interval_seconds: 0,
      max_cycles: max_cycles,
      live: live,
      disable_after: disable_after,
      confirmation: confirmation,
      proof_registry: proof_registry,
      executor_factory: -> { executor },
      selector: selector,
      log_dir: log_dir,
      stdout: StringIO.new,
      snapshot_refresher: snapshot_refresher,
      rebalance_before_cycle: rebalance_before_cycle,
      max_target_change_per_cycle_eth: max_target_change_per_cycle_eth,
      readiness_factory: ->(**) {
        {
          pending_nado_target_continuation: nil,
          pending_nado_target_continuation_blocking: false,
          stale_pending_continuation_ignored: false,
          blockers: []
        }
      }
    )
  end

  def read_jsonl(path)
    File.readlines(path).map { |line| JSON.parse(line) }
  end

  def update_burn_in_snapshot(position, production_venue:, shorts:, open_orders: 0, target: "1.18")
    combined = shorts.values.map { |value| BigDecimal(value.to_s) }.sum(BigDecimal("0"))
    drift = BigDecimal(target.to_s) - combined
    inside = drift.abs <= BigDecimal(target.to_s) * BigDecimal("0.03")
    attrs = {
      production_venue: production_venue,
      selected_venue: production_venue,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      target_short_eth: target,
      tolerance_abs_eth: (BigDecimal(target.to_s) * BigDecimal("0.03")).to_s("F"),
      combined_short_eth: combined.to_s("F"),
      drift_eth: drift.to_s("F"),
      inside_tolerance: inside,
      open_orders_count_extended: open_orders
    }
    shorts.each { |venue, value| attrs["#{venue}_short_eth"] = value }
    position.hedge.update!(execution_venue: production_venue)
    position.position_dashboard_snapshot.update!(attrs)
    ActiveVenueAutoPolicy.new(position: position).enable_venue!(venue: production_venue, reason: "test burn-in executor finalized")
  end

  def live_canary_event(position:, from:, to:, timestamp: Time.current, final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS, production_venue: to, orders_submitted: 0, signatures_created: 0)
    {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: production_venue,
      final_status: final_status,
      mode: "full",
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: orders_submitted,
      orders_placed: orders_submitted,
      signatures_created: signatures_created,
      timestamp: timestamp.iso8601
    }
  end

  def partial_canary_event(position:, from:, to:, timestamp: Time.current, orders_submitted: 2)
    {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      final_status: "PARTIAL_OVERHEDGE_MANUAL_ACTION_REQUIRED",
      manual_action_required: true,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: false,
      final_inside_tolerance: true,
      source_flat_after: false,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: orders_submitted,
      orders_placed: orders_submitted,
      signatures_created: orders_submitted,
      timestamp: timestamp.iso8601
    }
  end

  def recovery_event(position:, from:, to:, timestamp: Time.current, source_already_flat: true, source_close_confirmed: false, orders_submitted: 0, signatures_created: 0)
    {
      action: "recover_target_first_source_close",
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      production_venue: to,
      final_status: "MIGRATION_FINALIZED",
      lifecycle_state: "MIGRATION_FINALIZED",
      readback_confirmed: true,
      target_confirmed: true,
      source_already_flat: source_already_flat,
      source_close_confirmed: source_close_confirmed,
      other_venues_flat: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      manual_action_required: false,
      orders_submitted: orders_submitted,
      orders_placed: orders_submitted,
      signatures_created: signatures_created,
      timestamp: timestamp.iso8601
    }
  end

  def partial_nado_target_canary_event(position:, from:, timestamp: Time.current)
    {
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
    }
  end

  def continuation_event(position:, from:, timestamp: Time.current, final_status: "MIGRATION_FINALIZED", target_confirmed: true, pending_migration_id: nil, digest: "0xnado-target")
    {
      action: "continue_target_first_after_nado_confirmed",
      position_id: position.id,
      from_venue: from,
      to_venue: "nado",
      final_status: final_status,
      continuation_of_accepted_nado_target: true,
      pending_migration_id: pending_migration_id,
      nado_target_digest: digest,
      target_confirmed: target_confirmed,
      source_close_confirmed: true,
      final_inside_tolerance: true,
      production_venue_finalized: true,
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      timestamp: timestamp.iso8601
    }
  end

  class EmptyProofRegistry
    def report(position:)
      {
        routes: MigrationLiveRouteCapability::ROUTES.map do |from, to|
          { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "NOT_STARTED", blockers: [ "missing" ] }
        end,
        completed_route_proofs: [],
        missing_route_proofs: MigrationLiveRouteCapability::ROUTES.map { |from, to| { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "NOT_STARTED" } },
        stale_route_proofs: []
      }
    end
  end

  class BurnInProofRegistry
    def initialize(missing: [])
      @missing = missing
    end

    def report(position:)
      routes = MigrationLiveRouteCapability::ROUTES.map do |from, to|
        missing_route = @missing.find { |route| route[:from_venue] == from && route[:to_venue] == to }
        missing_route || { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "READY_FOR_RANDOM", blockers: [] }
      end
      {
        routes: routes,
        completed_route_proofs: routes.select { |route| route[:status] == "READY_FOR_RANDOM" },
        missing_route_proofs: @missing,
        stale_route_proofs: [],
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0
      }
    end
  end

  class BurnInSnapshotRefresher
    attr_reader :stages

    def initialize(fail_on: nil, target_by_stage: {}, target_sequence: nil, exposure_by_stage: {})
      @fail_on = fail_on
      @target_by_stage = target_by_stage
      @target_sequence = target_sequence&.dup
      @exposure_by_stage = exposure_by_stage
      @stages = []
    end

    def call(position:, stage:)
      @stages << stage
      raise "LP target unavailable" if stage == @fail_on

      target = next_target(stage, position)
      exposure = @exposure_by_stage.fetch(stage, nil)
      apply_target(position, target: target, exposure: exposure)
      position.position_dashboard_snapshot.reload
    end

    private

    def next_target(stage, position)
      return @target_by_stage.fetch(stage) if @target_by_stage.key?(stage)
      return @target_sequence.shift if @target_sequence&.any?

      position.position_dashboard_snapshot.target_short_eth.to_s("F")
    end

    def apply_target(position, target:, exposure:)
      snapshot = position.position_dashboard_snapshot
      shorts = exposure || {
        "extended" => snapshot.extended_short_eth,
        "ethereal" => snapshot.ethereal_short_eth,
        "nado" => snapshot.nado_short_eth
      }
      combined = shorts.values.map { |value| BigDecimal(value.to_s) }.sum(BigDecimal("0"))
      target_decimal = BigDecimal(target.to_s)
      tolerance = target_decimal * BigDecimal(position.hedge.tolerance.to_s)
      drift = target_decimal - combined
      position.update!(asset0_amount: target_decimal, asset1_amount: position.asset1_amount || BigDecimal("0"))
      snapshot.update!(
        refreshed_at: Time.current,
        refresh_status: "ok",
        stale: false,
        target_short_eth: target_decimal,
        tolerance_abs_eth: tolerance,
        combined_short_eth: combined,
        drift_eth: drift,
        inside_tolerance: drift.abs <= tolerance,
        extended_short_eth: shorts.fetch("extended", BigDecimal("0")),
        ethereal_short_eth: shorts.fetch("ethereal", BigDecimal("0")),
        nado_short_eth: shorts.fetch("nado", BigDecimal("0")),
        signer_status: "ok",
        open_orders_count_extended: snapshot.open_orders_count_extended || 0
      )
    end
  end

  class BurnInExecutor
    def initialize(after: nil, status: "success")
      @after = after
      @status = status
    end

    def run(position:, from_venue:, to_venue:, **)
      if @after
        @after.call(position, from_venue, to_venue)
      else
        position.position_dashboard_snapshot.update!(target_short_eth: "1.18")
        attrs = { from_venue => "0", to_venue => "1.18" }
        position.hedge.update!(execution_venue: to_venue)
        position.position_dashboard_snapshot.update!(
          production_venue: to_venue,
          selected_venue: to_venue,
          extended_short_eth: attrs.fetch("extended", "0"),
          ethereal_short_eth: attrs.fetch("ethereal", "0"),
          nado_short_eth: attrs.fetch("nado", "0"),
          combined_short_eth: "1.18",
          drift_eth: "0",
          inside_tolerance: true,
          open_orders_count_extended: 0
        )
        ActiveVenueAutoPolicy.new(position: position).enable_venue!(venue: to_venue, reason: "test burn-in executor finalized")
      end
      HedgeVenueMigrationExecutor::Result.new(
        @status,
        [],
        [],
        {
          from_venue: from_venue,
          to_venue: to_venue,
          final_status: @status,
          orders_submitted: 2,
          orders_placed: 2,
          signatures_created: 2,
          receipt_path: "tmp/test-burn-in-executor.jsonl"
        }
      )
    end
  end
end
