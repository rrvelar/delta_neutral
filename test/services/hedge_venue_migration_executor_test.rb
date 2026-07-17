require "test_helper"

class HedgeVenueMigrationExecutorTest < ActiveSupport::TestCase
  test "double exposure production-safe threshold default is unchanged at 5 seconds" do
    executor = HedgeVenueMigrationExecutor.new(env: {})

    assert_equal BigDecimal("5"), executor.send(:max_double_exposure_seconds)
  end

  test "all migration production-safe latency thresholds are unchanged" do
    executor = HedgeVenueMigrationExecutor.new(env: {})

    assert_equal BigDecimal("5"), executor.send(:max_double_exposure_seconds)
    assert_equal BigDecimal("10"), executor.send(:max_unhedged_seconds)
    assert_equal BigDecimal("15"), executor.send(:max_target_leg_latency_seconds)
    assert_equal BigDecimal("45"), executor.send(:max_total_route_latency_seconds)
  end

  test "migration route proof registry route set is unchanged" do
    assert_equal(
      [
        [ "extended", "ethereal" ], [ "ethereal", "extended" ],
        [ "extended", "nado" ], [ "nado", "extended" ],
        [ "ethereal", "nado" ], [ "nado", "ethereal" ]
      ],
      MigrationRouteProofRegistry::ROUTES
    )
  end

  test "live execution blocks without env gate" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: {}).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "MIGRATION_LIVE_ENABLED must be true"
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "source first live execution blocks without env gate and confirmation" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: {}).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: "wrong",
      full_migration_allowed: true,
      mode: "full",
      migration_sequence: "source_first"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "MIGRATION_LIVE_ENABLED must be true"
    assert_includes result.blockers, "submitted confirmation must equal #{HedgeVenueMigrationExecutor::CONFIRMATION}"
    assert_equal "source_first", result.receipt.fetch(:migration_sequence)
  end

  test "live execution blocks without confirmation" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: live_env, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: "wrong",
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{HedgeVenueMigrationExecutor::CONFIRMATION}"
  end

  test "live execution blocks with open orders" do
    position = migration_position(open_orders_count: 1)
    result = HedgeVenueMigrationExecutor.new(env: live_env, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "target/source open orders must be zero."
  end

  test "execution stops if first leg is not confirmed" do
    position = migration_position
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      assert context.fetch(:position)
      { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 1 }
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal 1, calls.size
  end

  test "target leg readback present but unconfirmed writes recovery command" do
    position = migration_position
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      assert context.fetch(:position)
      {
        status: "submitted_but_readback_pending",
        confirmed: false,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: "0.8",
        readback: { current_short_eth: "0.8", confirmed: false }
      }
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal 2, calls.size
    assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
    assert_match "from=extended to=ethereal", result.receipt.fetch(:recovery_command)
  end

  test "Nado target leg pending submit is reconciled before executor stops" do
    position = migration_position
    position.hedge.update!(execution_venue: "ethereal")
    position.position_dashboard_snapshot.update!(
      production_venue: "ethereal",
      selected_venue: "ethereal",
      extended_short_eth: "0",
      ethereal_short_eth: "0.8",
      nado_short_eth: "0"
    )
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0x3845e7",
      action_plan: { expected_after_short_eth: "0.8" },
      post_submit_readback_poll_attempts: Array.new(12) { |index| { attempt: index + 1, position_present: false, confirmed: false } }
    })
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0x3845e7",
      post_submit_readback: { short_size: BigDecimal("0.8") },
      post_submit_readback_poll_attempts: Array.new(12) { |index| { attempt: index + 1, position_present: false, confirmed: false } },
      reconciled_after_pending: true
    })
    fake_service = Class.new do
      attr_reader :reconciled, :reconcile_kwargs
      def initialize(pending, confirmed)
        @pending = pending
        @confirmed = confirmed
        @reconciled = false
      end
      def open_short(**_kwargs) = @pending
      def reconcile_pending_result(result, **kwargs)
        @reconciled = true
        @reconcile_kwargs = kwargs
        result.status == "submitted_but_readback_pending" ? @confirmed : result
      end
    end.new(pending, confirmed)
    first_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), venue_builder: fake_builder)
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      calls == 1 ? first_runner.call(leg, context: context) : { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, after_short_eth: "0", exchange_order_id: "ethereal-close" }
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }, final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado")).run(
        position: position,
        from_venue: "ethereal",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "success", result.status, result.blockers.inspect
      assert_equal true, fake_service.reconciled
      assert_equal "0.8", fake_service.reconcile_kwargs.fetch(:expected_short)
      assert_equal "0.8", fake_service.reconcile_kwargs.fetch(:target_short)
      assert_equal "0.024", fake_service.reconcile_kwargs.fetch(:tolerance_eth)
      assert_equal 2, calls
      assert_equal "nado", position.hedge.reload.execution_venue
      assert_equal "MIGRATION_FINALIZED", result.receipt.fetch(:lifecycle_state)
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal true, result.receipt.fetch(:target_late_reconciliation)
      assert_equal "SOURCE_CLOSE_CONFIRMED", result.receipt.fetch(:source_leg_status)
      assert_equal [ "0x3845e7", "ethereal-close" ], result.receipt.fetch(:exchange_order_ids)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
      assert_equal true, result.receipt.fetch(:would_execute_live)
    end
  end

  test "Extended to Nado target confirmed late continues to Extended source close" do
    position = migration_position
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-target",
      submitted_order_summary: { expected_after_short_eth: "0.8" },
      post_submit_readback_poll_attempts: [ { attempt: 1, short_size: "0", confirmed: false } ]
    })
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-target",
      post_submit_readback: { short_size: BigDecimal("0.8") },
      reconciled_after_pending: true,
      readback_confirmed: true
    })
    fake_service = Class.new do
      attr_reader :submit_count, :reconcile_count
      def initialize(pending, confirmed)
        @pending = pending
        @confirmed = confirmed
        @submit_count = 0
        @reconcile_count = 0
      end
      def open_short(**_kwargs)
        @submit_count += 1
        @pending
      end
      def reconcile_pending_result(_result, **_kwargs)
        @reconcile_count += 1
        @confirmed
      end
    end.new(pending, confirmed)
    first_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), venue_builder: fake_builder)
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      calls == 1 ? first_runner.call(leg, context: context) : { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, after_short_eth: "0", exchange_order_id: "extended-close" }
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }, final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")).run(
        position: position,
        from_venue: "extended",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "success", result.status, result.blockers.inspect
      assert_equal 1, fake_service.submit_count
      assert_equal 1, fake_service.reconcile_count
      assert_equal 2, calls
      assert_equal "nado", position.hedge.reload.execution_venue
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal "SOURCE_CLOSE_CONFIRMED", result.receipt.fetch(:source_leg_status)
      assert_equal [ "0xnado-target", "extended-close" ], result.receipt.fetch(:exchange_order_ids)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
      assert_equal 2, result.receipt.fetch(:signatures_created)
    end
  end

  test "Extended to Nado accepted digest retries target reconciliation before source close" do
    position = migration_position
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0x11c27ce8029bf779a4e2b7b916c259ef7bba06646d8e8d8a648c33b2b914f76a",
      submitted_order_summary: { expected_after_short_eth: "1.25344725365047" },
      post_submit_readback_poll_attempts: [ { attempt: 1, short_size: nil, confirmed: false } ]
    })
    still_pending = NadoHedgeExecutionService::Result.new("submitted_pending_readback", [], [], pending.receipt.merge(
      lifecycle_state: "SUBMITTED_PENDING_READBACK",
      readback_confirmed: false
    ))
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], pending.receipt.merge(
      post_submit_readback: { short_size: BigDecimal("1.253") },
      reconciled_after_pending: true,
      readback_confirmed: true
    ))
    fake_service = Class.new do
      attr_reader :reconcile_count, :submit_count
      def initialize(results)
        @results = results
        @reconcile_count = 0
        @submit_count = 0
      end
      def open_short(**_kwargs)
        @submit_count += 1
        @results.first
      end
      def reconcile_pending_result(_result, **_kwargs)
        @reconcile_count += 1
        @results.fetch(@reconcile_count, @results.last)
      end
    end.new([ pending, still_pending, confirmed ])
    first_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_NADO_TARGET_RECONCILIATION_ATTEMPTS" => "3",
        "MIGRATION_NADO_TARGET_RECONCILIATION_INTERVAL_SECONDS" => "0"
      ),
      venue_builder: fake_builder
    )
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      calls == 1 ? first_runner.call(leg, context: context) : { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, after_short_eth: "0", exchange_order_id: "extended-close" }
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
      ).run(
        position: position,
        from_venue: "extended",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "success", result.status, result.blockers.inspect
      assert_equal 1, fake_service.submit_count
      assert_equal 2, fake_service.reconcile_count
      assert_equal 2, calls
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal true, result.receipt.fetch(:target_late_reconciliation)
      assert_equal true, result.receipt.dig(:to_leg_execution, :confirmed)
      assert_equal 2, result.receipt.dig(:to_leg_execution, :receipt, :migration_target_reconciliation_attempts).size
      assert_equal [ "0x11c27ce8029bf779a4e2b7b916c259ef7bba06646d8e8d8a648c33b2b914f76a", "extended-close" ], result.receipt.fetch(:exchange_order_ids)
    end
  end

  test "Extended to Nado uses close-only Extended source close path after Nado target confirms late" do
    position = migration_position
    venues = FakeVenueBuilder.new(
      "nado" => FakeVenue.new(nil),
      "extended" => FakeVenue.new({ short_size: BigDecimal("0.8") })
    )
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-target",
      submitted_order_summary: { expected_after_short_eth: "0.8" }
    })
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], pending.receipt.merge(
      post_submit_readback: { short_size: BigDecimal("0.8") },
      reconciled_after_pending: true,
      readback_confirmed: true
    ))
    nado_service = FakeNadoMigrationService.new(pending: pending, confirmed: confirmed)
    extended_service = FakeExtendedMigrationService.new(
      ExtendedHedgeExecutionService::Result.new("success", [], [], {
        mode: "close_only",
        submitted: true,
        orders_placed: 1,
        orders_submitted: 1,
        signatures_created: 1,
        exchange_order_id: "extended-close",
        readback_attempts: [ { short_size: "0", confirmed: true } ],
        final_status: "success"
      })
    )
    runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      venue_builder: venues
    )

    NadoHedgeExecutionService.stub(:new, nado_service) do
      ExtendedHedgeExecutionService.stub(:new, extended_service) do
        result = HedgeVenueMigrationExecutor.new(
          env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
          leg_runner: runner,
          snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
          final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
        ).run(
          position: position,
          from_venue: "extended",
          to_venue: "nado",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          mode: "full"
        )

        assert_equal "success", result.status, result.blockers.inspect
        assert_equal 1, nado_service.open_calls
        assert_equal 1, nado_service.reconcile_calls
        assert_equal 1, extended_service.close_calls.size
        assert_equal 0, extended_service.rebalance_calls.size
        assert_equal "0.8", extended_service.close_calls.first.fetch(:size_eth).to_s("F")
        assert_equal "close_only", result.receipt.dig(:from_leg_execution, :receipt, :mode)
        assert_equal "SOURCE_CLOSE_CONFIRMED", result.receipt.fetch(:source_leg_status)
        assert_equal true, result.receipt.fetch(:source_leg_submitted)
        assert_equal "extended-close", result.receipt.fetch(:source_leg_exchange_order_id)
        assert_equal [ "0xnado-target", "extended-close" ], result.receipt.fetch(:exchange_order_ids)
        assert_equal 2, result.receipt.fetch(:orders_submitted)
        assert_equal 2, result.receipt.fetch(:signatures_created)
        assert_equal "nado", position.hedge.reload.execution_venue
      end
    end
  end

  test "Extended to Nado confirms rounded Nado target readback before source close" do
    position = migration_position
    position.position_dashboard_snapshot.update!(
      target_short_eth: "0.9134680515417161",
      tolerance_abs_eth: "0.027404041546251483",
      combined_short_eth: "0.903",
      extended_short_eth: "0.903",
      nado_short_eth: "0"
    )
    venues = FakeVenueBuilder.new(
      "nado" => FakeVenue.new(nil),
      "extended" => FakeVenue.new({ short_size: BigDecimal("0.903"), size: BigDecimal("-0.903"), margin_mode: "cross" })
    )
    nado_service = ReconcilingNadoMigrationService.new(
      expected_short: "0.9134680515417161",
      late_position: { size: BigDecimal("-0.913"), short_size: BigDecimal("0.913"), margin_mode: "isolated" }
    )
    extended_service = FakeExtendedMigrationService.new(
      ExtendedHedgeExecutionService::Result.new("success", [], [], {
        mode: "close_only",
        submitted: true,
        orders_placed: 1,
        orders_submitted: 1,
        signatures_created: 1,
        exchange_order_id: "extended-close-0.903",
        readback_attempts: [ { short_size: "0", confirmed: true } ],
        final_status: "success"
      })
    )
    runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_NADO_TARGET_RECONCILIATION_ATTEMPTS" => "3",
        "MIGRATION_NADO_TARGET_RECONCILIATION_INTERVAL_SECONDS" => "0"
      ),
      venue_builder: venues
    )

    NadoHedgeExecutionService.stub(:new, nado_service) do
      ExtendedHedgeExecutionService.stub(:new, extended_service) do
        result = HedgeVenueMigrationExecutor.new(
          env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
          leg_runner: runner,
          snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
          final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
        ).run(
          position: position,
          from_venue: "extended",
          to_venue: "nado",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          step_size_eth: "0.9134680515417161",
          mode: "full"
        )

        assert_equal "success", result.status, result.blockers.inspect
        assert_equal 1, nado_service.open_calls
        assert_equal 1, nado_service.reconcile_calls
        assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
        attempts = result.receipt.dig(:to_leg_execution, :receipt, :migration_target_reconciliation_attempts)
        assert_equal 1, attempts.size
        assert_equal "0.913", attempts.first.fetch(:actual_nado_short_eth)
        assert_equal "0.9134680515417161", attempts.first.fetch(:expected_nado_short_eth)
        assert_equal "0.0004680515417161", attempts.first.fetch(:difference_eth)
        assert_equal true, attempts.first.fetch(:confirmed_by_size_increment)
        assert_equal true, attempts.first.fetch(:confirmed)
        assert_equal 1, extended_service.close_calls.size
        assert_equal true, result.receipt.fetch(:source_leg_submitted)
        assert_equal "SOURCE_CLOSE_CONFIRMED", result.receipt.fetch(:source_leg_status)
        assert_equal [ "0xnado-target", "extended-close-0.903" ], result.receipt.fetch(:exchange_order_ids)
        assert_equal 2, result.receipt.fetch(:orders_submitted)
        assert_equal 2, result.receipt.fetch(:signatures_created)
        assert_equal "nado", position.hedge.reload.execution_venue
      end
    end
  end

  test "Extended to Nado reports explicit source close blocker when Extended close is blocked before submit" do
    position = migration_position
    venues = FakeVenueBuilder.new(
      "nado" => FakeVenue.new(nil),
      "extended" => FakeVenue.new({ short_size: BigDecimal("0.8") })
    )
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-target",
      post_submit_readback: { short_size: BigDecimal("0.8") },
      reconciled_after_pending: true,
      readback_confirmed: true
    })
    nado_service = FakeNadoMigrationService.new(pending: confirmed, confirmed: confirmed)
    extended_service = FakeExtendedMigrationService.new(
      ExtendedHedgeExecutionService::Result.new("blocked_before_submit", [ "Extended source close blocked before submit" ], [], {
        mode: "close_only",
        submitted: false,
        orders_placed: 0,
        orders_submitted: 0,
        signatures_created: 0,
        exchange_order_id: nil,
        final_status: "blocked_before_submit",
        blockers: [ "Extended source close blocked before submit" ]
      })
    )
    runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      venue_builder: venues
    )

    NadoHedgeExecutionService.stub(:new, nado_service) do
      ExtendedHedgeExecutionService.stub(:new, extended_service) do
        result = HedgeVenueMigrationExecutor.new(
          env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
          leg_runner: runner,
          snapshot_refresher: ->(item) { item.position_dashboard_snapshot }
        ).run(
          position: position,
          from_venue: "extended",
          to_venue: "nado",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          mode: "full"
        )

        assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
        assert_equal 1, extended_service.close_calls.size
        assert_equal false, result.receipt.fetch(:source_leg_submitted)
        assert_nil result.receipt.fetch(:source_leg_exchange_order_id)
        assert_equal "RECOVERY_REQUIRED", result.receipt.fetch(:source_leg_status)
        assert_includes result.blockers, "Extended source close blocked before submit"
        assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
        assert_equal [ "0xnado-target" ], result.receipt.fetch(:exchange_order_ids)
        assert_equal 1, result.receipt.fetch(:orders_submitted)
        assert_equal 1, result.receipt.fetch(:signatures_created)
        assert_equal "extended", position.hedge.reload.execution_venue
      end
    end
  end

  test "Ethereal to Nado accepted digest retries target reconciliation before source close" do
    position = migration_position_for("ethereal")
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-ethereal",
      submitted_order_summary: { expected_after_short_eth: "0.8" }
    })
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], pending.receipt.merge(
      post_submit_readback: { short_size: BigDecimal("0.8") },
      reconciled_after_pending: true,
      readback_confirmed: true
    ))
    fake_service = Class.new do
      attr_reader :reconcile_count
      def initialize(pending, confirmed)
        @pending = pending
        @confirmed = confirmed
        @reconcile_count = 0
      end
      def open_short(**_kwargs) = @pending
      def reconcile_pending_result(_result, **_kwargs)
        @reconcile_count += 1
        @confirmed
      end
    end.new(pending, confirmed)
    first_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), venue_builder: fake_builder)
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      calls == 1 ? first_runner.call(leg, context: context) : { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, after_short_eth: "0", exchange_order_id: "ethereal-close" }
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado")
      ).run(
        position: position,
        from_venue: "ethereal",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "success", result.status, result.blockers.inspect
      assert_equal 1, fake_service.reconcile_count
      assert_equal 2, calls
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal [ "0xnado-ethereal", "ethereal-close" ], result.receipt.fetch(:exchange_order_ids)
    end
  end

  test "target first Nado accepted and confirmed by readback immediately continues to source close" do
    position = migration_position
    calls = []
    snapshot_refreshes = 0
    runner = ->(leg, context:) do
      calls << leg
      if calls.size == 1
        {
          status: "submitted_pending_readback",
          confirmed: false,
          orders_placed: 1,
          signatures_created: 1,
          after_short_eth: "0.8",
          exchange_order_id: "0xnado-target",
          readback: { short_size: "0.8" }
        }
      else
        {
          status: "confirmed",
          confirmed: true,
          orders_placed: 1,
          signatures_created: 1,
          after_short_eth: "0",
          exchange_order_id: "extended-close",
          readback: { short_size: "0" }
        }
      end
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      leg_runner: runner,
      snapshot_refresher: ->(item) {
        snapshot_refreshes += 1
        item.position_dashboard_snapshot
      },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 1, snapshot_refreshes
    assert_equal 2, calls.size
    assert_equal "TARGET_CONFIRMED_BY_CONTINUATION_READBACK", result.receipt.fetch(:target_leg_status)
    assert_equal "extended", calls.second.fetch(:venue)
    assert_equal "buy", calls.second.fetch(:side)
    assert_equal true, calls.second.fetch(:reduce_only)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal [ "0xnado-target", "extended-close" ], result.receipt.fetch(:exchange_order_ids)
    assert result.receipt.fetch(:target_leg_submit_started_at)
    assert result.receipt.fetch(:target_leg_submit_finished_at)
    assert result.receipt.fetch(:target_leg_accepted_at)
    assert_equal "0xnado-target", result.receipt.fetch(:target_leg_digest_or_order_id)
    assert result.receipt.fetch(:target_readback_confirmed_at)
    assert result.receipt.fetch(:source_close_submit_started_at)
    assert result.receipt.fetch(:source_close_submit_finished_at)
    assert_equal "extended-close", result.receipt.fetch(:source_close_order_id)
    assert_operator BigDecimal(result.receipt.fetch(:target_accept_to_source_close_submit_latency_seconds).to_s), :<=, BigDecimal("10")
    assert_operator BigDecimal(result.receipt.fetch(:target_confirm_to_source_close_submit_latency_seconds).to_s), :<=, BigDecimal("10")
  end

  test "migration receipt promotes venue action timing and latency threshold warnings" do
    position = migration_position
    calls = []
    target_timing = {
      build_started_at: "2026-06-06T12:00:00.000000Z",
      build_finished_at: "2026-06-06T12:00:00.200000Z",
      sign_started_at: "2026-06-06T12:00:00.200000Z",
      sign_finished_at: "2026-06-06T12:00:00.400000Z",
      submit_started_at: "2026-06-06T12:00:00.400000Z",
      submit_finished_at: "2026-06-06T12:00:01.400000Z",
      submit_latency_seconds: 1.0,
      exchange_accept_at: "2026-06-06T12:00:01.400000Z",
      readback_started_at: "2026-06-06T12:00:01.400000Z",
      readback_confirmed_at: "2026-06-06T12:01:01.700000Z",
      readback_latency_seconds: 60.3,
      total_action_latency_seconds: 61.7,
      poll_attempts: 6,
      poll_interval_seconds: "0.5",
      slow_step: "readback"
    }
    source_timing = {
      submit_latency_seconds: 0.3,
      readback_latency_seconds: 0.4,
      total_action_latency_seconds: 0.9,
      slow_step: "readback"
    }
    runner = ->(leg, context:) do
      calls << leg
      if calls.size == 1
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "0xnado-target", readback: { short_size: "0.8" }, timing: target_timing }
      else
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "extended-close", readback: { short_size: "0" }, timing: source_timing }
      end
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_MAX_TARGET_LEG_LATENCY_SECONDS" => "15"
      ),
      leg_runner: runner,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 2, calls.size
    assert_equal 61.7, result.receipt.fetch(:target_total_latency_seconds)
    assert_equal 1.0, result.receipt.fetch(:target_submit_latency_seconds)
    assert_equal 60.3, result.receipt.fetch(:target_readback_latency_seconds)
    assert_equal "readback", result.receipt.fetch(:target_slow_step)
    assert_equal 0.9, result.receipt.fetch(:source_close_total_latency_seconds)
    assert_equal true, result.receipt.fetch(:latency_threshold_exceeded)
    assert_includes result.receipt.fetch(:warnings).join(" "), "LATENCY_THRESHOLD_EXCEEDED"
    assert_includes result.receipt.fetch(:latency_thresholds_exceeded).map { |entry| entry[:field] }, :target_total_latency_seconds
  end

  test "target first route records double exposure and marks late source flat as not production safe" do
    position = migration_position
    calls = []
    current_time = Time.zone.local(2026, 6, 6, 12, 0, 0)
    now = -> {
      value = current_time
      current_time += 3.seconds
      value
    }
    runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: calls.size == 1 ? "0xnado-target" : "extended-close",
        readback: { short_size: calls.size == 1 ? "0.8" : "0" }
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS" => "1",
        "MIGRATION_TARGET_TO_SOURCE_CLOSE_MAX_LATENCY_SECONDS" => "60"
      ),
      leg_runner: runner,
      now: now,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status
    assert_equal "nado", position.hedge.reload.execution_venue
    assert result.receipt.fetch(:double_exposure_started_at)
    assert result.receipt.fetch(:double_exposure_ended_at)
    assert_operator BigDecimal(result.receipt.fetch(:double_exposure_seconds).to_s), :>, BigDecimal("1")
    assert_equal false, result.receipt.fetch(:route_production_safe)
    assert_equal "failed_latency_threshold", result.receipt.fetch(:latency_proof_status)
    assert_equal false, result.receipt.fetch(:manual_action_required)
    assert_equal true, result.receipt.fetch(:latency_incident)
    assert_equal false, OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
  end

  test "defensive pause records previously enabled venue autos in the receipt" do
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test setup")
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test setup")
    executor = HedgeVenueMigrationExecutor.new(env: {})
    receipt = {}

    executor.send(:pause_autonomous_migration!, migration_position, receipt)

    assert_includes receipt[:defensively_paused_venue_autos], "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"
    refute_includes receipt[:defensively_paused_venue_autos], "EXTENDED_AUTO_REBALANCE_ENABLED"
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "double exposure ends at the close leg's own readback timestamp when present" do
    position = migration_position
    calls = []
    current_time = Time.zone.local(2026, 6, 6, 12, 0, 0)
    now = -> {
      value = current_time
      current_time += 3.seconds
      value
    }
    leg_flat_confirmed_at = "2026-06-06T12:00:20.500000Z"
    runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: calls.size == 1 ? "0xnado-target" : "extended-close",
        readback: { short_size: calls.size == 1 ? "0.8" : "0" },
        timing: calls.size == 2 ? { readback_confirmed_at: leg_flat_confirmed_at } : {}
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      leg_runner: runner,
      now: now,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    # Final verification still ran and gated success.
    assert_equal "success", result.status, result.blockers.inspect
    assert_equal true, result.receipt.fetch(:source_flat_confirmed)
    # Window end re-anchored to the leg-internal flat readback, not a later stamp.
    assert_equal leg_flat_confirmed_at, result.receipt.fetch(:source_close_position_readback_confirmed_at)
    assert_equal leg_flat_confirmed_at, result.receipt.fetch(:source_close_flat_confirmed_at)
    assert_equal leg_flat_confirmed_at, result.receipt.fetch(:double_exposure_ended_at)
    assert_equal "position_readback", result.receipt.fetch(:double_exposure_end_source)
  end

  test "double exposure end falls back to a stamped time when the close leg has no readback timestamp" do
    position = migration_position
    calls = []
    current_time = Time.zone.local(2026, 6, 6, 12, 0, 0)
    now = -> {
      value = current_time
      current_time += 3.seconds
      value
    }
    runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: calls.size == 1 ? "0xnado-target" : "extended-close",
        readback: { short_size: calls.size == 1 ? "0.8" : "0" }
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
      leg_runner: runner,
      now: now,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert result.receipt.fetch(:source_close_position_readback_confirmed_at)
    assert_equal result.receipt.fetch(:source_close_position_readback_confirmed_at), result.receipt.fetch(:double_exposure_ended_at)
  end

  test "target confirmation to source close latency beyond threshold returns manual action before source submit" do
    position = migration_position
    calls = []
    current_time = Time.zone.local(2026, 6, 6, 12, 0, 0)
    now = -> {
      value = current_time
      current_time += 2.seconds
      value
    }
    runner = ->(leg, context:) do
      calls << leg
      {
        status: "submitted_pending_readback",
        confirmed: false,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: "0.8",
        exchange_order_id: "0xnado-target",
        readback: { short_size: "0.8" }
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_TARGET_TO_SOURCE_CLOSE_MAX_LATENCY_SECONDS" => "1"
      ),
      leg_runner: runner,
      now: now,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot }
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "nado",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal 1, calls.size
    assert_nil result.receipt[:source_close_submit_started_at]
    assert_includes result.blockers.join(" "), "target confirmation to source close submit latency exceeded"
    assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
  end

  test "accepted Nado target remains pending without duplicate submit when reconciliation never confirms" do
    position = migration_position
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0xpendingnado",
      submitted_order_summary: { expected_after_short_eth: "0.8" }
    })
    still_pending = NadoHedgeExecutionService::Result.new("submitted_pending_readback", [], [], pending.receipt.merge(
      lifecycle_state: "SUBMITTED_PENDING_READBACK",
      readback_confirmed: false
    ))
    fake_service = Class.new do
      attr_reader :submit_count, :reconcile_count
      def initialize(pending, still_pending)
        @pending = pending
        @still_pending = still_pending
        @submit_count = 0
        @reconcile_count = 0
      end
      def open_short(**_kwargs)
        @submit_count += 1
        @pending
      end
      def reconcile_pending_result(_result, **_kwargs)
        @reconcile_count += 1
        @still_pending
      end
    end.new(pending, still_pending)
    first_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
        "MIGRATION_NADO_TARGET_RECONCILIATION_ATTEMPTS" => "3",
        "MIGRATION_NADO_TARGET_RECONCILIATION_INTERVAL_SECONDS" => "0"
      ),
      venue_builder: fake_builder
    )
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      first_runner.call(leg, context: context)
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot }
      ).run(
        position: position,
        from_venue: "extended",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
      assert_equal 1, fake_service.submit_count
      assert_equal 3, fake_service.reconcile_count
      assert_equal 1, calls
      assert_equal "TARGET_SUBMITTED_PENDING_READBACK", result.receipt.fetch(:target_leg_status)
      assert_equal true, result.receipt.fetch(:manual_action_required)
      assert_equal false, result.receipt.fetch(:source_leg_submitted, false)
      assert_equal "0xpendingnado", result.receipt.fetch(:nado_target_digest)
      assert_equal "close source venue reduce-only", result.receipt.fetch(:recommended_action)
      assert_equal 1, result.receipt.fetch(:orders_submitted)
      assert_equal 1, result.receipt.fetch(:signatures_created)
      assert_equal [ "0xpendingnado" ], result.receipt.fetch(:exchange_order_ids)
      assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
    end
  end

  test "unconfirmed accepted target submit records pending state counts and generic recovery command" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: ->(leg, context:) {
      {
        status: "submitted_but_readback_pending",
        confirmed: false,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "0xpending",
        readback: Array.new(12) { |index| { attempt: index + 1, position_present: false, confirmed: false } }
      }
    }, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.receipt.fetch(:lifecycle_state)
    assert_equal "TARGET_SUBMITTED_PENDING_READBACK", result.receipt.fetch(:target_leg_status)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:orders_placed)
    assert_equal true, result.receipt.fetch(:would_execute_live)
    assert_equal [ "0xpending" ], result.receipt.fetch(:exchange_order_ids)
    assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
    assert_match "from=extended to=ethereal", result.receipt.fetch(:recovery_command)
  end

  test "second leg failure produces partial migration status" do
    position = migration_position
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      assert context.fetch(:position)
      if calls.size == 1
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1 }
      else
        { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 0 }
      end
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal 2, calls.size
    assert_equal 2, result.receipt.fetch(:orders_placed)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  test "source first target leg failure after source close requires manual action" do
    position = migration_position
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      assert context.fetch(:position)
      if calls.size == 1
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, after_short_eth: leg.fetch(:expected_after_short_eth) }
      else
        { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 1, blockers: [ "target open not confirmed" ] }
      end
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full",
      migration_sequence: "source_first"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_SOURCE_FLAT_TARGET_NOT_OPEN", result.status
    assert_equal true, result.receipt.fetch(:manual_action_required)
    assert_equal "extended", calls.first.fetch(:venue)
    assert_equal "ethereal", calls.second.fetch(:venue)
    assert_match "sequence=source_first", result.receipt.fetch(:recovery_command)
  end

  test "source first Nado accepted digest finalizes after late Nado readback" do
    position = migration_position_for("ethereal")
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-source-first",
      action_plan: { expected_after_short_eth: "0.8" },
      post_submit_readback_poll_attempts: Array.new(12) { |index| { attempt: index + 1, position_present: false, confirmed: false } },
      final_status: "submitted_but_readback_pending"
    })
    confirmed = NadoHedgeExecutionService::Result.new("rebalance_confirmed_late", [], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-source-first",
      post_submit_readback: { short_size: BigDecimal("0.8") },
      pending_reconciliation_readback: { short_size: BigDecimal("0.8") },
      pending_reconciliation_confirmation: { confirmed: true, actual_short_eth: "0.8", expected_short_eth: "0.8" },
      reconciled_after_pending: true,
      readback_confirmed: true
    })
    fake_service = Class.new do
      attr_reader :open_calls, :reconcile_calls

      def initialize(pending, confirmed)
        @pending = pending
        @confirmed = confirmed
        @open_calls = 0
        @reconcile_calls = 0
      end

      def open_short(**_kwargs)
        @open_calls += 1
        @pending
      end

      def reconcile_pending_result(result, **_kwargs)
        @reconcile_calls += 1
        @confirmed
      end
    end.new(pending, confirmed)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      if calls.size == 1
        { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0", readback: { short_size: "0" } }
      else
        nado_runner.call(leg, context: context)
      end
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge(
          "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
          "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
          "NADO_SOURCE_FIRST_RECONCILIATION_ATTEMPTS" => "13",
          "NADO_SOURCE_FIRST_RECONCILIATION_INTERVAL_SECONDS" => "0"
        ),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado"),
        sleeper: ->(_seconds) { }
      ).run(
        position: position,
        from_venue: "ethereal",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full",
        migration_sequence: "source_first"
      )

      assert_equal "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK", result.status, result.blockers.inspect
      assert_equal 1, fake_service.open_calls
      assert_equal 1, fake_service.reconcile_calls
      assert_equal "nado", position.hedge.reload.execution_venue
      assert_equal false, result.receipt.fetch(:manual_action_required)
      assert_equal true, result.receipt.fetch(:submitted)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
      assert_equal 2, result.receipt.fetch(:orders_placed)
      assert_equal 2, result.receipt.fetch(:signatures_created)
      assert_equal [ "ethereal-close", "0xnado-source-first" ], result.receipt.fetch(:exchange_order_ids)
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal 1, result.receipt.fetch(:nado_source_first_reconciliation_attempts).size
      assert_equal "0xnado-source-first", result.receipt.fetch(:nado_source_first_reconciliation_attempts).last.fetch(:digest)
      assert result.receipt.key?(:source_flat_to_nado_submit_started_seconds)
      assert result.receipt.key?(:nado_accept_to_confirmed_seconds)
      assert result.receipt.key?(:source_flat_to_finalized_seconds)
      assert_equal 1, result.receipt.fetch(:service_readback_attempts)
      assert_equal 0, result.receipt.fetch(:canonical_readback_attempts)
    end
  end

  test "source first Nado accepted digest uses canonical recovery readback when service reconciliation misses target" do
    position = migration_position_for("ethereal")
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [ "target still not visible through Nado service poll" ], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-canonical",
      action_plan: { expected_after_short_eth: "0.8" },
      final_status: "submitted_but_readback_pending"
    })
    fake_service = FakeNadoMigrationService.new(pending: pending, confirmed: pending)
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      calls.size == 1 ? { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0" } : nado_runner.call(leg, context: context)
    end

    canonical_readback = {
      status: "confirmed",
      confirmed: true,
      target_confirmed: true,
      source_flat: true,
      third_venue_flat: true,
      combined_inside_tolerance: true,
      open_orders_clear: true,
      target_short_eth: "0.8",
      source_short_eth: "0",
      combined_short_eth: "0.8",
      expected_target_short_eth: "0.8",
      tolerance_eth: "0.024",
      latest_attempt: {
        timestamp: Time.current.utc.iso8601,
        source_short_eth: "0",
        target_venue_short_eth: "0.8",
        combined_short_eth: "0.8",
        expected_target_short_eth: "0.8",
        tolerance_eth: "0.024",
        source_flat: true,
        target_confirmed: true,
        third_venue_flat: true,
        combined_inside_tolerance: true,
        open_orders_clear: true,
        blockers: []
      },
      verification: { confirmed: true, attempts: [ { attempt: 1 } ], latest_attempt: {}, blockers: [] },
      blockers: [],
      readback_source: "canonical_nado_migration_readback"
    }
    canonical_calls = []
    NadoHedgeExecutionService.stub(:new, fake_service) do
      NadoMigrationReadback.stub(:confirm_target_short, ->(**kwargs) { canonical_calls << kwargs; canonical_readback }) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge(
          "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
          "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
          "NADO_SOURCE_FIRST_RECONCILIATION_ATTEMPTS" => "2",
          "NADO_SOURCE_FIRST_RECONCILIATION_INTERVAL_SECONDS" => "0"
        ),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado"),
        sleeper: ->(_seconds) { }
      ).run(
        position: position,
        from_venue: "ethereal",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full",
        migration_sequence: "source_first"
      )

      assert_equal "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK", result.status, result.blockers.inspect
      assert_equal 1, canonical_calls.size
      assert_equal "ethereal", canonical_calls.first.fetch(:from)
      assert_equal "nado", canonical_calls.first.fetch(:to)
      assert_equal 1, fake_service.open_calls
      assert_equal 1, fake_service.reconcile_calls
      assert_equal "nado", position.hedge.reload.execution_venue
      assert_equal true, result.receipt.fetch(:nado_source_first_canonical_readback).fetch(:confirmed)
      assert_operator BigDecimal(result.receipt.fetch(:nado_accept_to_first_canonical_readback_seconds).to_s), :<=, BigDecimal("2")
      assert_equal 1, result.receipt.fetch(:canonical_readback_attempts)
      assert_equal 1, result.receipt.fetch(:service_readback_attempts)
      assert_equal "canonical_nado_migration_readback", result.receipt.fetch(:first_confirming_readback_source)
      assert_equal "TARGET_CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:target_leg_status)
      assert_equal [ "ethereal-close", "0xnado-canonical" ], result.receipt.fetch(:exchange_order_ids)
      assert_equal true, result.receipt.fetch(:submitted)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
    end
    end
  end

  test "source first Nado safe finalization with slow latency fails route proof only" do
    position = migration_position_for("ethereal")
    current_time = Time.zone.local(2026, 6, 6, 12, 0, 0)
    now = -> {
      value = current_time
      current_time += 2.seconds
      value
    }
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [ "target still not visible through Nado service poll" ], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-slow",
      action_plan: { expected_after_short_eth: "0.8" },
      final_status: "submitted_but_readback_pending"
    })
    fake_service = FakeNadoMigrationService.new(pending: pending, confirmed: pending)
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      calls.size == 1 ? { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0" } : nado_runner.call(leg, context: context)
    end
    canonical_readback = {
      status: "confirmed",
      confirmed: true,
      target_confirmed: true,
      source_flat: true,
      third_venue_flat: true,
      combined_inside_tolerance: true,
      open_orders_clear: true,
      target_short_eth: "0.8",
      source_short_eth: "0",
      combined_short_eth: "0.8",
      expected_target_short_eth: "0.8",
      tolerance_eth: "0.024",
      latest_attempt: {
        timestamp: "2026-06-06T16:00:30.000000Z",
        source_short_eth: "0",
        target_venue_short_eth: "0.8",
        combined_short_eth: "0.8",
        expected_target_short_eth: "0.8",
        tolerance_eth: "0.024",
        source_flat: true,
        target_confirmed: true,
        third_venue_flat: true,
        combined_inside_tolerance: true,
        open_orders_clear: true,
        blockers: []
      },
      verification: { confirmed: true, latest_attempt: {}, blockers: [] },
      blockers: [],
      readback_source: "canonical_nado_migration_readback"
    }

    NadoHedgeExecutionService.stub(:new, fake_service) do
      NadoMigrationReadback.stub(:confirm_target_short, ->(**_kwargs) { canonical_readback }) do
        result = HedgeVenueMigrationExecutor.new(
          env: live_env.merge(
            "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
            "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
            "NADO_SOURCE_FIRST_RECONCILIATION_ATTEMPTS" => "2",
            "NADO_SOURCE_FIRST_RECONCILIATION_INTERVAL_SECONDS" => "0",
            "MIGRATION_MAX_TOTAL_ROUTE_SECONDS" => "5",
            "MIGRATION_MAX_UNHEDGED_SECONDS" => "5",
            "MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS" => "5"
          ),
          leg_runner: runner,
          now: now,
          snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
          final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado"),
          sleeper: ->(_seconds) { }
        ).run(
          position: position,
          from_venue: "ethereal",
          to_venue: "nado",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          mode: "full",
          migration_sequence: "source_first"
        )

        assert_equal "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK", result.status, result.blockers.inspect
        assert_equal "nado", position.hedge.reload.execution_venue
        assert_equal false, result.receipt.fetch(:manual_action_required)
        assert_equal true, result.receipt.fetch(:production_venue_finalized)
        assert_equal true, result.receipt.fetch(:route_complete_by_readback)
        assert_equal false, result.receipt.fetch(:route_production_safe)
        assert_equal "failed_latency_threshold", result.receipt.fetch(:latency_proof_status)
        assert_equal "0", result.receipt.fetch(:double_exposure_seconds)
        assert_equal true, result.receipt.fetch(:double_exposure_threshold_passed)
        assert_no_match(/double exposure lasted 0.*exceeding/, result.receipt.fetch(:latency_threshold_blockers).join(" "))
        assert_match(/source-flat-to-target-confirmed latency/, result.receipt.fetch(:latency_threshold_blockers).join(" "))
      end
    end
  end

  test "source first pre source close latency is reported separately and does not fail route safety" do
    position = migration_position_for("ethereal")
    base = Time.zone.parse("2026-06-06T12:00:00Z")
    times = [
      base,
      base + 50.seconds,
      base + 50.seconds,
      base + 50.1.seconds,
      base + 50.2.seconds,
      base + 50.21.seconds,
      base + 50.22.seconds,
      base + 50.23.seconds
    ]
    now = -> { times.shift || base + 50.24.seconds }
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [ "target still not visible through Nado service poll" ], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-fast-risk",
      action_plan: { expected_after_short_eth: "0.8" },
      final_status: "submitted_but_readback_pending"
    })
    fake_service = FakeNadoMigrationService.new(pending: pending, confirmed: pending)
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      calls.size == 1 ? { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0" } : nado_runner.call(leg, context: context)
    end
    canonical_readback = {
      status: "confirmed",
      confirmed: true,
      target_confirmed: true,
      source_flat: true,
      third_venue_flat: true,
      combined_inside_tolerance: true,
      open_orders_clear: true,
      target_short_eth: "0.8",
      source_short_eth: "0",
      combined_short_eth: "0.8",
      expected_target_short_eth: "0.8",
      tolerance_eth: "0.024",
      latest_attempt: {
        timestamp: "2026-06-06T12:00:50.220000Z",
        source_short_eth: "0",
        target_venue_short_eth: "0.8",
        combined_short_eth: "0.8",
        expected_target_short_eth: "0.8",
        tolerance_eth: "0.024",
        source_flat: true,
        target_confirmed: true,
        third_venue_flat: true,
        combined_inside_tolerance: true,
        open_orders_clear: true,
        blockers: []
      },
      verification: { confirmed: true, attempts: [ { attempt: 1 } ], latest_attempt: {}, blockers: [] },
      blockers: [],
      readback_source: "canonical_nado_migration_readback"
    }

    NadoHedgeExecutionService.stub(:new, fake_service) do
      NadoMigrationReadback.stub(:confirm_target_short, ->(**_kwargs) { canonical_readback }) do
        result = HedgeVenueMigrationExecutor.new(
          env: live_env.merge(
            "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
            "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
            "MIGRATION_MAX_TOTAL_ROUTE_SECONDS" => "45",
            "MIGRATION_MAX_UNHEDGED_SECONDS" => "5",
            "MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS" => "5"
          ),
          leg_runner: runner,
          now: now,
          snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
          final_verifier_factory: final_verifier_factory(from: "ethereal", to: "nado"),
          sleeper: ->(_seconds) { }
        ).run(
          position: position,
          from_venue: "ethereal",
          to_venue: "nado",
          dry_run: false,
          confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
          full_migration_allowed: true,
          mode: "full",
          migration_sequence: "source_first"
        )

        assert_equal "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK", result.status, result.blockers.inspect
        assert_equal true, result.receipt.fetch(:route_production_safe)
        assert_equal "passed", result.receipt.fetch(:latency_proof_status)
        assert_operator BigDecimal(result.receipt.fetch(:total_migration_latency_seconds).to_s), :>, BigDecimal("45")
        assert_operator BigDecimal(result.receipt.fetch(:source_flat_to_target_confirmed_seconds).to_s), :<, BigDecimal("1")
        assert_empty Array(result.receipt[:latency_threshold_blockers])
      end
    end
  end

  test "source first Nado execution confirmation ends risk window before delayed position readback" do
    position = migration_position_for("ethereal")
    base = Time.zone.parse("2026-06-06T16:00:00Z")
    times = [
      base,
      base + 1.second,
      base + 2.seconds,
      base + 3.seconds,
      base + 4.seconds,
      base + 5.seconds,
      base + 6.seconds,
      base + 7.seconds,
      base + 8.seconds
    ]
    now = -> { times.shift || base + 9.seconds }
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [ "target still not visible through Nado service poll" ], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-exec-fast",
      action_plan: { expected_after_short_eth: "0.8" },
      final_status: "submitted_but_readback_pending"
    })
    fake_service = FakeNadoMigrationService.new(pending: pending, confirmed: pending)
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      calls.size == 1 ? { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0" } : nado_runner.call(leg, context: context)
    end
    canonical_readback = {
      status: "confirmed",
      confirmed: true,
      target_confirmed: true,
      source_flat: true,
      third_venue_flat: true,
      combined_inside_tolerance: true,
      open_orders_clear: true,
      target_short_eth: "0.8",
      source_short_eth: "0",
      combined_short_eth: "0.8",
      expected_target_short_eth: "0.8",
      tolerance_eth: "0.024",
      latest_attempt: {
        timestamp: "2026-06-06T16:00:25.000000Z",
        source_short_eth: "0",
        target_venue_short_eth: "0.8",
        combined_short_eth: "0.8",
        expected_target_short_eth: "0.8",
        tolerance_eth: "0.024",
        source_flat: true,
        target_confirmed: true,
        third_venue_flat: true,
        combined_inside_tolerance: true,
        open_orders_clear: true,
        open_orders_count: 0,
        blockers: []
      },
      verification: {
        confirmed: true,
        attempts: [ { attempt: 1 } ],
        latest_attempt: {
          source_short_eth: "0",
          target_venue_short_eth: "0.8",
          combined_short_eth: "0.8",
          expected_target_short_eth: "0.8",
          tolerance_eth: "0.024",
          open_orders_count: 0
        },
        source_flat: true,
        target_confirmed: true,
        third_venue_flat: true,
        combined_inside_tolerance: true,
        open_orders_clear: true,
        blockers: []
      },
      blockers: [],
      readback_source: "canonical_nado_migration_readback"
    }
    execution_confirmation = {
      status: "confirmed",
      confirmed: true,
      confirmed_at: "2026-06-06T16:00:04.500000Z",
      source: "archive_order",
      digest: "0xnado-exec-fast",
      attempts: []
    }

    NadoHedgeExecutionService.stub(:new, fake_service) do
      NadoExecutionConfirmation.stub(:confirm_digest, ->(**_kwargs) { execution_confirmation }) do
        NadoMigrationReadback.stub(:confirm_target_short, ->(**_kwargs) { canonical_readback }) do
          result = HedgeVenueMigrationExecutor.new(
            env: live_env.merge(
              "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
              "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
              "MIGRATION_MAX_UNHEDGED_SECONDS" => "10",
              "MIGRATION_MAX_TOTAL_ROUTE_SECONDS" => "10"
            ),
            leg_runner: runner,
            now: now,
            snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
            final_verifier_factory: ->(**) { raise "canonical final state should avoid redundant final verifier" },
            sleeper: ->(_seconds) { }
          ).run(
            position: position,
            from_venue: "ethereal",
            to_venue: "nado",
            dry_run: false,
            confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
            full_migration_allowed: true,
            mode: "full",
            migration_sequence: "source_first"
          )

          assert_equal "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK", result.status, result.blockers.inspect
          assert_equal true, result.receipt.fetch(:route_production_safe)
          assert_equal "passed", result.receipt.fetch(:latency_proof_status)
          assert_equal "archive_order", result.receipt.fetch(:target_confirmation_source)
          assert_operator BigDecimal(result.receipt.fetch(:source_flat_to_execution_confirmed_seconds).to_s), :<, BigDecimal("10")
          assert_operator BigDecimal(result.receipt.fetch(:source_flat_to_position_confirmed_seconds).to_s), :>, BigDecimal("10")
          assert_operator BigDecimal(result.receipt.fetch(:source_flat_to_finalized_seconds).to_s), :<, BigDecimal("10")
        end
      end
    end
  end

  test "source first Nado accepted digest becomes bounded ambiguous state without duplicate submit" do
    position = migration_position_for("ethereal")
    fake_venue = Class.new do
      def read_position(symbol:) = nil
    end.new
    fake_builder = Class.new do
      def initialize(venue) = @venue = venue
      def build(_name, **_kwargs) = @venue
    end.new(fake_venue)
    pending = NadoHedgeExecutionService::Result.new("submitted_but_readback_pending", [ "target still not visible" ], [], {
      submitted: true,
      orders_placed: 1,
      orders_submitted: 1,
      signatures_created: 1,
      exchange_order_id: "0xnado-ambiguous",
      action_plan: { expected_after_short_eth: "0.8" },
      final_status: "submitted_but_readback_pending"
    })
    fake_service = FakeNadoMigrationService.new(pending: pending, confirmed: pending)
    nado_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(
      env: live_env.merge(
        "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
        "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"
      ),
      venue_builder: fake_builder,
      sleeper: ->(_seconds) { }
    )
    calls = []
    runner = ->(leg, context:) do
      calls << leg
      calls.size == 1 ? { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "ethereal-close", after_short_eth: "0" } : nado_runner.call(leg, context: context)
    end

    NadoHedgeExecutionService.stub(:new, fake_service) do
      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge(
          "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
          "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
          "NADO_SOURCE_FIRST_RECONCILIATION_ATTEMPTS" => "3",
          "NADO_SOURCE_FIRST_RECONCILIATION_INTERVAL_SECONDS" => "0"
        ),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        sleeper: ->(_seconds) { }
      ).run(
        position: position,
        from_venue: "ethereal",
        to_venue: "nado",
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full",
        migration_sequence: "source_first"
      )

      assert_equal "SOURCE_FIRST_TARGET_AMBIGUOUS_AFTER_TIMEOUT", result.status
      assert_equal true, result.receipt.fetch(:manual_action_required)
      assert_equal true, result.receipt.fetch(:pending_nado_source_first_digest_unresolved)
      assert_equal 1, fake_service.open_calls
      assert_equal 1, fake_service.reconcile_calls
      assert_equal true, result.receipt.fetch(:submitted)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
      assert_equal "0xnado-ambiguous", result.receipt.fetch(:nado_target_digest)
      assert_match "migration:reconcile_nado_source_first", result.receipt.fetch(:recovery_command)
    end
  end

  test "live execution pauses source auto instead of blocking migration" do
    position = migration_position(extended_auto_enabled: true)
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: true)
    calls = []
    runner = ->(leg, context:) do
      calls << [ leg, context ]
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: leg.fetch(:expected_after_short_eth),
        exchange_order_id: "order-#{calls.size}",
        readback: { short_size: leg.fetch(:expected_after_short_eth) }
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env,
      leg_runner: runner,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "successful full migration finalizes only after target holds hedge and source is flat" do
    position = migration_position
    calls = []
    runner = ->(leg, context:) do
      calls << [ leg, context ]
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: leg.fetch(:expected_after_short_eth),
        exchange_order_id: "order-#{calls.size}",
        readback: { short_size: leg.fetch(:expected_after_short_eth) }
      }
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }, final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal")).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal "ethereal", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
    assert_equal [ "order-1", "order-2" ], result.receipt.fetch(:exchange_order_ids)
  end

  test "shared final reconciliation finalizes all six target first routes after stale first final readback" do
    routes = [
      [ "extended", "ethereal" ],
      [ "ethereal", "extended" ],
      [ "extended", "nado" ],
      [ "nado", "extended" ],
      [ "ethereal", "nado" ],
      [ "nado", "ethereal" ]
    ]

    routes.each do |from, to|
      position = migration_position_for(from)
      calls = []
      runner = ->(leg, context:) do
        calls << [ leg, context ]
        {
          status: "confirmed",
          confirmed: true,
          orders_placed: 1,
          signatures_created: 1,
          after_short_eth: leg.fetch(:expected_after_short_eth),
          exchange_order_id: "order-#{from}-#{to}-#{calls.size}"
        }
      end

      result = HedgeVenueMigrationExecutor.new(
        env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"),
        leg_runner: runner,
        snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
        final_verifier_factory: final_verifier_factory(from: from, to: to, safe_on_attempt: 2)
      ).run(
        position: position,
        from_venue: from,
        to_venue: to,
        dry_run: false,
        confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
        full_migration_allowed: true,
        mode: "full"
      )

      assert_equal "success", result.status, "#{from}->#{to}: #{result.blockers.inspect}"
      assert_equal to, position.hedge.reload.execution_venue
      assert_equal "MIGRATION_FINALIZED", result.receipt.fetch(:lifecycle_state)
      assert_equal "MIGRATION_CONFIRMED_LATE", result.receipt.fetch(:final_reconciliation_status)
      assert_equal 2, result.receipt.dig(:final_reconciliation, :attempts).size
      assert_equal true, result.receipt.fetch(:source_flat_after)
      assert_equal true, result.receipt.fetch(:target_holds_expected_short)
      assert_equal true, result.receipt.fetch(:third_venue_flat)
      assert_equal true, result.receipt.fetch(:final_inside_tolerance)
      assert_equal 0, result.receipt.fetch(:open_orders_after)
      assert_equal 2, result.receipt.fetch(:orders_submitted)
      assert_equal 2, result.receipt.fetch(:signatures_created)
    end
  end

  test "final reconciliation failure preserves submit counts and recovery command" do
    position = migration_position
    runner = ->(leg, context:) do
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: leg.fetch(:expected_after_short_eth),
        exchange_order_id: "order-#{leg.fetch(:venue)}"
      }
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }, final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal", safe: false)).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.receipt.fetch(:lifecycle_state)
    assert_equal 2, result.receipt.fetch(:orders_submitted)
    assert_equal 2, result.receipt.fetch(:signatures_created)
    assert_equal [ "order-ethereal", "order-extended" ], result.receipt.fetch(:exchange_order_ids)
    assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  test "receipt redacts sensitive fields" do
    position = migration_position
    runner = ->(_leg, context:) do
      assert_equal HedgeVenueMigrationExecutor::CONFIRMATION, context.fetch(:confirmation)
      {
        status: "blocked",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 0,
        blockers: [ "blocked" ],
        private_key: "secret",
        signature: "secret-signature"
      }
    end

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "TARGET_REJECTED_OR_NOT_CONFIRMED", result.status
    assert_equal "dashboard_migration_confirmation", result.receipt.fetch(:confirmation_type)
    assert_no_match HedgeVenueMigrationExecutor::CONFIRMATION, result.receipt.to_json
    assert_equal "<redacted>", result.receipt.dig(:to_leg_execution, :private_key)
    assert_equal "<redacted>", result.receipt.dig(:to_leg_execution, :signature)
  end

  # --- authoritative source-close fill ends the double-exposure window ---

  test "target_first ends double-exposure at the authoritative source-close fill when final readback agrees" do
    confirmed_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 12.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: { confirmed: true, reduce_only: true, source: "ethereal_order_list_fill", confirmed_at: confirmed_at, filled_eth: "0.8", remaining_eth: "0" },
      verifier_safe: true
    )
    r = result.receipt

    assert_equal "success", result.status
    assert_equal "authoritative_fill", r.fetch(:double_exposure_end_source)
    assert_equal confirmed_at, r.fetch(:double_exposure_ended_at)
    assert_equal confirmed_at, r.fetch(:source_close_flat_confirmed_at)
    assert_equal true, r.fetch(:source_close_fill_readback_agreement)
    # Overhedge window is the ~2s to the fill, well under the 5s budget: no incident,
    # so the route certifies (vs the ~40s slow-position-readback path).
    assert_operator BigDecimal(r.fetch(:double_exposure_seconds).to_s), :<, BigDecimal("5")
    assert_equal false, r.fetch(:latency_incident, false)
    # The slow position readback still ran and is later than the fill confirmation.
    assert_operator r.fetch(:source_close_position_readback_confirmed_at), :>, confirmed_at
  end

  test "target_first fails closed when the source-close fill disagrees with the final readback" do
    confirmed_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 12.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: { confirmed: true, reduce_only: true, source: "ethereal_order_list_fill", confirmed_at: confirmed_at, filled_eth: "0.8", remaining_eth: "0" },
      verifier_safe: false
    )
    r = result.receipt

    refute_equal "success", result.status
    assert_equal false, r.fetch(:source_close_fill_readback_agreement)
    assert_equal "position_readback", r.fetch(:double_exposure_end_source)
    refute_equal true, r.fetch(:route_production_safe, nil)
  end

  test "target_first partial (non-confirmed) fill falls back to position readback and stays unsafe" do
    result = run_ethereal_to_extended(
      # A non-authoritative confirmation (confirmed:false) must be ignored.
      source_close_confirmation: { confirmed: false, reduce_only: true, source: "ethereal_order_list_fill", confirmed_at: (Time.zone.local(2026, 7, 8, 12, 0, 0) + 12.seconds).utc.iso8601(6) },
      verifier_safe: true, max_double_exposure: "5"
    )
    r = result.receipt

    assert_equal "success", result.status
    assert_equal "position_readback", r.fetch(:double_exposure_end_source)
    assert_operator BigDecimal(r.fetch(:double_exposure_seconds).to_s), :>, BigDecimal("5")
    assert_equal false, r.fetch(:route_production_safe)
    assert_equal true, r.fetch(:latency_incident)
  end

  test "target_first with no authoritative fill uses the slow position readback (existing behavior)" do
    result = run_ethereal_to_extended(source_close_confirmation: nil, verifier_safe: true, max_double_exposure: "5")
    r = result.receipt

    assert_equal "success", result.status
    assert_equal "position_readback", r.fetch(:double_exposure_end_source)
    assert_operator BigDecimal(r.fetch(:double_exposure_seconds).to_s), :>, BigDecimal("5")
    assert_equal false, r.fetch(:route_production_safe)
    assert_equal true, r.fetch(:latency_incident)
  end

  # --- authoritative target-open fill starts the double-exposure window ---

  test "target_first starts the double-exposure window at the authoritative target-open fill" do
    fill_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 5.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: nil, verifier_safe: true, max_double_exposure: "5",
      target_open_confirmation: {
        confirmed: true, reduce_only: false, source: "ethereal_order_list_open_fill",
        confirmed_at: fill_at, open_size_eth: "0.8", filled_eth: "0.8", remaining_eth: "0", order_status: "FILLED"
      }
    )
    r = result.receipt

    assert_equal "success", result.status
    assert_equal "authoritative_fill", r.fetch(:double_exposure_start_source)
    assert_equal "ethereal_order_list_open_fill", r.fetch(:target_open_confirmation_source)
    assert_equal fill_at, r.fetch(:target_open_fill_confirmed_at)
    assert_equal fill_at, r.fetch(:target_leg_accepted_at)
    assert_equal fill_at, r.fetch(:double_exposure_started_at)
    # Window start moved EARLIER than the leg-return timestamp -> never masks exposure.
    assert_operator r.fetch(:double_exposure_started_at), :<, r.fetch(:target_leg_submit_finished_at)
    assert_equal true, r.fetch(:target_open_fill_readback_agreement)
    assert r.fetch(:open_fill_confirmation).present?
  end

  test "target_first without an authoritative target-open fill keeps the submit-finished window start" do
    result = run_ethereal_to_extended(source_close_confirmation: nil, verifier_safe: true, max_double_exposure: "5")
    r = result.receipt

    assert_equal "position_readback", r.fetch(:double_exposure_start_source)
    assert_equal r.fetch(:target_leg_submit_finished_at), r.fetch(:double_exposure_started_at)
    assert_nil r[:target_open_fill_confirmed_at]
    assert_nil r[:target_open_fill_readback_agreement]
  end

  test "target_first flags disagreement when the final readback does not confirm the target open" do
    fill_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 5.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: nil, verifier_safe: false,
      target_open_confirmation: {
        confirmed: true, reduce_only: false, source: "ethereal_order_list_open_fill",
        confirmed_at: fill_at, open_size_eth: "0.8", filled_eth: "0.8", remaining_eth: "0", order_status: "FILLED"
      }
    )
    r = result.receipt

    refute_equal "success", result.status
    assert_equal false, r.fetch(:target_open_fill_readback_agreement)
  end

  test "target_first does not submit the source close when the target open is not authoritatively confirmed" do
    result = run_ethereal_to_extended(
      source_close_confirmation: nil, verifier_safe: false, target_leg_confirmed: false,
      # A non-authoritative open fill (confirmed:false) must never release the source close.
      target_open_confirmation: { confirmed: false, reduce_only: false, source: "ethereal_order_list_open_fill", confirmed_at: (Time.zone.local(2026, 7, 8, 12, 0, 0) + 5.seconds).utc.iso8601(6) }
    )
    r = result.receipt

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_nil r[:source_close_submit_started_at]
    refute_equal "authoritative_fill", r[:double_exposure_start_source]
  end

  # --- executor consumes Extended-shaped fill confirmations (venue-agnostic) ---

  test "target_first consumes an Extended authoritative target-open fill for the window start" do
    fill_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 5.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: nil, verifier_safe: true, max_double_exposure: "5",
      target_open_confirmation: {
        confirmed: true, reduce_only: false, source: "extended_order_by_id_fill",
        confirmed_at: fill_at, open_size_eth: "0.8", filled_eth: "0.8", remaining_eth: "0", order_status: "FILLED"
      }
    )
    r = result.receipt

    assert_equal "authoritative_fill", r.fetch(:double_exposure_start_source)
    assert_equal "extended_order_by_id_fill", r.fetch(:target_open_confirmation_source)
    assert_equal fill_at, r.fetch(:double_exposure_started_at)
  end

  test "target_first ends double-exposure at an Extended authoritative source-close fill" do
    confirmed_at = (Time.zone.local(2026, 7, 8, 12, 0, 0) + 12.seconds).utc.iso8601(6)
    result = run_ethereal_to_extended(
      source_close_confirmation: { confirmed: true, reduce_only: true, source: "extended_order_by_id_fill", confirmed_at: confirmed_at, filled_eth: "0.8", remaining_eth: "0" },
      verifier_safe: true, max_double_exposure: "5"
    )
    r = result.receipt

    assert_equal "success", result.status
    assert_equal "authoritative_fill", r.fetch(:double_exposure_end_source)
    assert_equal confirmed_at, r.fetch(:double_exposure_ended_at)
    assert_equal true, r.fetch(:source_close_fill_readback_agreement)
  end

  # --- Part A: frozen Ethereal source position (guarded) ---

  def frozen_leg_runner
    HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: {})
  end

  def frozen_close_leg(size: "1.8703")
    { venue: "ethereal", side: "buy", size_eth: size, expected_after_short_eth: "0" }
  end

  def frozen_context(proof:, sequence: "target_first")
    { receipt: { migration_sequence: sequence, frozen_source_position: proof } }
  end

  def valid_proof(size: "1.8703")
    { source_venue: "ethereal", short_size: size, invariants_proven: true }
  end

  test "frozen source position is used when all invariants hold and size matches" do
    pos = frozen_leg_runner.send(:frozen_ethereal_source_position, frozen_close_leg, frozen_context(proof: valid_proof))
    assert pos, "expected a frozen synthesized position"
    assert_equal "short", pos[:side]
    assert_equal "1.8703", pos[:short_size]
    assert_equal true, pos[:frozen_source_position]
  end

  test "no frozen source position when the proof is absent (fresh read)" do
    assert_nil frozen_leg_runner.send(:frozen_ethereal_source_position, frozen_close_leg, frozen_context(proof: nil))
  end

  test "no frozen source position when invariants are not proven" do
    proof = valid_proof.merge(invariants_proven: false)
    assert_nil frozen_leg_runner.send(:frozen_ethereal_source_position, frozen_close_leg, frozen_context(proof: proof))
  end

  test "no frozen source position when the planned size mismatches the frozen size" do
    assert_nil frozen_leg_runner.send(:frozen_ethereal_source_position, frozen_close_leg(size: "1.5"), frozen_context(proof: valid_proof(size: "1.8703")))
  end

  test "no frozen source position when the leg is not a close-to-flat" do
    open_leg = { venue: "ethereal", side: "sell", size_eth: "1.8703", expected_after_short_eth: "1.8703" }
    assert_nil frozen_leg_runner.send(:frozen_ethereal_source_position, open_leg, frozen_context(proof: valid_proof))
  end

  test "no frozen source position when the sequence is not target_first" do
    assert_nil frozen_leg_runner.send(:frozen_ethereal_source_position, frozen_close_leg, frozen_context(proof: valid_proof, sequence: "source_first"))
  end

  # --- Indeterminate target-leg timeout classification (2026-07-16 incident) ---
  # A Net::ReadTimeout during the target submit surfaces as a "failed_before_submit"
  # leg with orders_placed 0. The order may still have reached the venue and
  # filled, so the executor must NOT clean-abort as TARGET_REJECTED; it must do an
  # authoritative target readback and fail closed.

  def timeout_target_leg
    ->(_leg, context:) do
      assert context.fetch(:position)
      {
        status: "failed_before_submit",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 0,
        blockers: [ "Net::ReadTimeout: Net::ReadTimeout with #<TCPSocket:(closed)>" ]
      }
    end
  end

  test "target submit timeout with target live is classified TARGET_FILLED_CONFIRMATION_UNKNOWN and requires recovery" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(
      env: live_env,
      leg_runner: timeout_target_leg,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal", safe: true)
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal "TARGET_FILLED_CONFIRMATION_UNKNOWN", result.receipt.fetch(:target_leg_status)
    assert_equal true, result.receipt.fetch(:target_confirmation_timed_out)
    assert_equal true, result.receipt.fetch(:target_possibly_live)
    assert_equal "0.8", result.receipt.fetch(:target_authoritative_readback_short_eth)
    assert_equal true, result.receipt.fetch(:random_and_auto_paused)
    # The source close must NEVER be submitted when the target is possibly live.
    assert_nil result.receipt[:source_close_submit_started_at]
    options = result.receipt.fetch(:recovery_options)
    assert_equal %w[A B C], options.map { |o| o[:option] }
    revert = options.find { |o| o[:action] == "revert_migration" }
    assert_match "migration:revert_target_first_target_close", revert.fetch(:command)
    assert_includes result.blockers.join(" "), "the target filled"
  end

  test "target submit timeout with target confirmed flat is a clean reject that preserves the source" do
    position = migration_position
    result = HedgeVenueMigrationExecutor.new(
      env: live_env,
      leg_runner: timeout_target_leg,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal", safe: false)
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "TARGET_REJECTED_OR_NOT_CONFIRMED", result.status
    assert_equal "TARGET_REJECTED_OR_NOT_CONFIRMED", result.receipt.fetch(:target_leg_status)
    assert_equal "0.0", result.receipt.fetch(:target_authoritative_readback_short_eth)
    assert_nil result.receipt[:target_possibly_live]
    assert_includes result.blockers.join(" "), "is flat"
  end

  test "target leg submit_failed (HTTP 503) is classified via authoritative readback, not clean-rejected" do
    position = migration_position
    runner = ->(_leg, context:) do
      assert context.fetch(:position)
      {
        status: "submit_failed",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 1,
        exchange_order_id: nil,
        blockers: [ "Extended submit failed: HTTP 503 (JSON::ParserError: unexpected character)" ]
      }
    end

    result = HedgeVenueMigrationExecutor.new(
      env: live_env,
      leg_runner: runner,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal", safe: true)
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal "TARGET_FILLED_CONFIRMATION_UNKNOWN", result.receipt.fetch(:target_leg_status)
    assert_equal true, result.receipt.fetch(:target_confirmation_timed_out)
    assert_nil result.receipt[:source_close_submit_started_at]
  end

  test "target submit timeout with unavailable readback fails closed to TARGET_CONFIRMATION_TIMEOUT" do
    position = migration_position
    unavailable_verifier = Class.new do
      def verify
        {
          status: "recheck_required",
          confirmed: false,
          attempts: [],
          latest_attempt: {
            attempt: 1,
            status: "recheck",
            readback_source: "venue_readback_error",
            blockers: [ "final readback unavailable: Net::ReadTimeout: execution expired" ]
          },
          blockers: [ "final readback unavailable" ]
        }
      end
    end.new

    result = HedgeVenueMigrationExecutor.new(
      env: live_env,
      leg_runner: timeout_target_leg,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: ->(position:, receipt:) { unavailable_verifier }
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )

    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", result.status
    assert_equal "TARGET_CONFIRMATION_TIMEOUT", result.receipt.fetch(:target_leg_status)
    assert_equal true, result.receipt.fetch(:target_possibly_live)
    assert_nil result.receipt.fetch(:target_authoritative_readback_short_eth)
    assert_equal true, result.receipt.fetch(:random_and_auto_paused)
    assert_includes result.blockers.join(" "), "readback is unavailable"
  end

  private

  # Runs a target_first migration (extended->nado, the proven executor test setup)
  # with a stubbed leg runner whose source-close (2nd) leg optionally carries an
  # authoritative close-fill confirmation. The executor's authoritative-fill logic
  # is venue-agnostic; Ethereal-specific production is covered in the service test.
  # `now` advances 10s per mark so the slow position-readback path measures ~40s.
  def run_ethereal_to_extended(source_close_confirmation:, verifier_safe: true, max_double_exposure: nil, target_open_confirmation: nil, target_leg_confirmed: true)
    position = migration_position
    clock = Time.zone.local(2026, 7, 8, 12, 0, 0)
    now = -> { value = clock; clock += 10.seconds; value }
    calls = 0
    runner = ->(leg, context:) do
      calls += 1
      if calls == 1
        leg_result = {
          status: target_leg_confirmed ? "confirmed" : "submitted_pending_readback",
          confirmed: target_leg_confirmed, orders_placed: 1, signatures_created: 1,
          exchange_order_id: "nado-target",
          readback: { short_size: target_leg_confirmed ? "0.8" : "0" }
        }
        leg_result[:open_fill_confirmation] = target_open_confirmation if target_open_confirmation
        leg_result
      else
        leg_result = {
          status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1,
          exchange_order_id: "extended-close",
          readback: { short_size: "0" }
        }
        leg_result[:close_fill_confirmation] = source_close_confirmation if source_close_confirmation
        leg_result
      end
    end
    env = live_env.merge(
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
      "MIGRATION_TARGET_TO_SOURCE_CLOSE_MAX_LATENCY_SECONDS" => "600"
    )
    env["MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS"] = max_double_exposure if max_double_exposure
    HedgeVenueMigrationExecutor.new(
      env: env, leg_runner: runner, now: now,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "nado", safe: verifier_safe)
    ).run(
      position: position, from_venue: "extended", to_venue: "nado",
      dry_run: false, confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true, mode: "full"
    )
  end

  FakeVenue = Struct.new(:position) do
    def read_position(symbol:) = position
  end

  class FakeVenueBuilder
    def initialize(venues)
      @venues = venues
    end

    def build(name, **_kwargs)
      @venues.fetch(name)
    end
  end

  class FakeNadoMigrationService
    attr_reader :open_calls, :reconcile_calls

    def initialize(pending:, confirmed:)
      @pending = pending
      @confirmed = confirmed
      @open_calls = 0
      @reconcile_calls = 0
    end

    def open_short(**_kwargs)
      @open_calls += 1
      @pending
    end

    def reconcile_pending_result(result, **_kwargs)
      @reconcile_calls += 1
      result.status == "submitted_but_readback_pending" ? @confirmed : result
    end
  end

  class ReconcilingNadoMigrationService < NadoHedgeExecutionService
    attr_reader :open_calls, :reconcile_calls

    def initialize(expected_short:, late_position:)
      @expected_short = expected_short
      @late_position = late_position
      @open_calls = 0
      @reconcile_calls = 0
    end

    def open_short(**_kwargs)
      @open_calls += 1
      Result.new("submitted_but_readback_pending", [], [], {
        submitted: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "0xnado-target",
        action_plan: {
          expected_after_short_eth: @expected_short,
          delta_eth: @expected_short
        },
        post_submit_readback_poll_attempts: [ { attempt: 1, short_size: "0", confirmed: false } ],
        final_status: "submitted_but_readback_pending"
      })
    end

    def reconcile_pending_result(result, **kwargs)
      @reconcile_calls += 1
      super
    end

    def read_position
      @late_position
    end

    def product_size_increment
      BigDecimal("0.001")
    end
  end

  class FakeExtendedMigrationService
    attr_reader :close_calls, :rebalance_calls

    def initialize(close_result)
      @close_result = close_result
      @close_calls = []
      @rebalance_calls = []
    end

    def close_short(**kwargs)
      @close_calls << kwargs
      @close_result
    end

    def rebalance_short(**kwargs)
      @rebalance_calls << kwargs
      ExtendedHedgeExecutionService::Result.new("blocked_before_submit", [ "rebalance should not be used for close-to-flat source leg" ], [], {})
    end
  end

  FakeFinalVerifier = Struct.new(:from, :to, :safe, :safe_on_attempt, keyword_init: true) do
    def verify
      attempts = []
      (1..safe_on_attempt).each do |attempt|
        confirmed = safe && attempt >= safe_on_attempt
        attempts << attempt_payload(attempt: attempt, confirmed: confirmed)
      end
      latest = attempts.last
      {
        status: latest[:status] == "confirmed" ? "confirmed" : "recheck_required",
        confirmed: latest[:status] == "confirmed",
        attempts_configured: safe_on_attempt,
        interval_seconds: "0",
        attempts: attempts,
        latest_attempt: latest,
        source_flat: latest[:source_flat],
        target_confirmed: latest[:target_confirmed],
        third_venue_flat: latest[:third_venue_flat],
        combined_inside_tolerance: latest[:combined_inside_tolerance],
        open_orders_clear: latest[:open_orders_clear],
        blockers: latest[:blockers],
        warnings: []
      }
    end

    def attempt_payload(attempt:, confirmed:)
      {
        attempt: attempt,
        status: confirmed ? "confirmed" : "recheck",
        readback_source: "test",
        source_venue: from,
        target_venue: to,
        source_short_eth: confirmed ? "0" : "0.8",
        target_venue_short_eth: confirmed ? "0.8" : "0",
        third_venue_shorts: { (%w[extended ethereal nado] - [ from, to ]).first => "0" },
        combined_short_eth: confirmed ? "0.8" : "0.8",
        expected_target_short_eth: "0.8",
        tolerance_eth: "0.024",
        source_flat: confirmed,
        target_confirmed: confirmed,
        third_venue_flat: true,
        combined_inside_tolerance: confirmed,
        open_order_counts: { from => 0, to => 0 },
        open_orders_count: 0,
        open_orders_clear: true,
        blockers: confirmed ? [] : [ "final readback stale" ]
      }
    end
  end

  def final_verifier_factory(from:, to:, safe: true, safe_on_attempt: 1)
    verifier = FakeFinalVerifier.new(from: from, to: to, safe: safe, safe_on_attempt: safe_on_attempt)
    ->(position:, receipt:) { verifier }
  end

  def live_env
    {
      "MIGRATION_LIVE_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
    }
  end

  def migration_position(open_orders_count: 0, extended_auto_enabled: false, ethereal_auto_enabled: false)
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
      nado_source_status: "ok",
      open_orders_count_extended: open_orders_count,
      leverage_margin_gate_status: "pass",
      extended_auto_enabled: extended_auto_enabled,
      ethereal_auto_enabled: ethereal_auto_enabled
    )
    position
  end

  def migration_position_for(source)
    position = migration_position
    position.hedge.update!(execution_venue: source)
    position.position_dashboard_snapshot.update!(
      production_venue: source,
      selected_venue: source,
      extended_short_eth: source == "extended" ? "0.8" : "0",
      ethereal_short_eth: source == "ethereal" ? "0.8" : "0",
      nado_short_eth: source == "nado" ? "0.8" : "0",
      extended_status: source == "extended" ? "active" : "flat",
      ethereal_status: source == "ethereal" ? "active" : "flat",
      nado_status: source == "nado" ? "active" : "flat",
      extended_auto_enabled: false,
      ethereal_auto_enabled: false
    )
    position
  end
end
