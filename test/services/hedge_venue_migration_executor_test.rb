require "test_helper"

class HedgeVenueMigrationExecutorTest < ActiveSupport::TestCase
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

    assert_equal "TARGET_SUBMITTED_BUT_NOT_CONFIRMED", result.status
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

    assert_equal "TARGET_SUBMITTED_BUT_NOT_CONFIRMED", result.status
    assert_equal 1, calls.size
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

        assert_equal "partial_migration_manual_action_required", result.status
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

      assert_equal "TARGET_SUBMITTED_BUT_NOT_CONFIRMED", result.status
      assert_equal 1, fake_service.submit_count
      assert_equal 3, fake_service.reconcile_count
      assert_equal 1, calls
      assert_equal "TARGET_SUBMITTED_PENDING_READBACK", result.receipt.fetch(:target_leg_status)
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

    assert_equal "TARGET_SUBMITTED_BUT_NOT_CONFIRMED", result.status
    assert_equal "TARGET_SUBMITTED_PENDING_READBACK", result.receipt.fetch(:lifecycle_state)
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

    assert_equal "FINAL_READBACK_RECHECK_REQUIRED", result.status
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

    assert_equal "FINAL_READBACK_RECHECK_REQUIRED", result.status
    assert_equal true, result.receipt.fetch(:manual_action_required)
    assert_equal "extended", calls.first.fetch(:venue)
    assert_equal "ethereal", calls.second.fetch(:venue)
    assert_match "migration:recover_target_first_source_close", result.receipt.fetch(:recovery_command)
  end

  test "live execution blocks when source auto is enabled" do
    position = migration_position(extended_auto_enabled: true)
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
    assert_includes result.blockers, "Extended auto must be disabled during migration."
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

    assert_equal "FINAL_READBACK_RECHECK_REQUIRED", result.status
    assert_equal "FINAL_READBACK_RECHECK_REQUIRED", result.receipt.fetch(:lifecycle_state)
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

  private

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
