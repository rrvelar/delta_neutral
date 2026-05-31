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

    assert_equal "first_leg_not_confirmed", result.status
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

    assert_equal "TARGET_LEG_READBACK_PRESENT_NOT_CONFIRMED", result.status
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
      action_plan: { expected_after_short_eth: "0.8" }
    })
    confirmed = NadoHedgeExecutionService::Result.new("submitted_and_confirmed", [], [], {
      submitted: true,
      orders_placed: 1,
      signatures_created: 1,
      exchange_order_id: "0x3845e7",
      post_submit_readback: { short_size: BigDecimal("0.8") },
      reconciled_after_pending: true
    })
    fake_service = Class.new do
      attr_reader :reconciled
      def initialize(pending, confirmed)
        @pending = pending
        @confirmed = confirmed
        @reconciled = false
      end
      def open_short(**_kwargs) = @pending
      def reconcile_pending_result(result)
        @reconciled = true
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
      result = HedgeVenueMigrationExecutor.new(env: live_env.merge("AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true", "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true"), leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
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
      assert_equal 2, calls
      assert_equal "nado", position.hedge.reload.execution_venue
    end
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

    assert_equal "partial_migration_manual_action_required", result.status
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

    assert_equal "partial_migration_manual_action_required", result.status
    assert_equal true, result.receipt.fetch(:manual_action_required)
    assert_equal "extended", calls.first.fetch(:venue)
    assert_equal "ethereal", calls.second.fetch(:venue)
    assert result.receipt.fetch(:warnings).any? { |warning| warning.include?("temporarily unhedged") }
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

    result = HedgeVenueMigrationExecutor.new(env: live_env, leg_runner: runner, snapshot_refresher: ->(item) { item.position_dashboard_snapshot }).run(
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

    assert_equal "first_leg_not_confirmed", result.status
    assert_equal "dashboard_migration_confirmation", result.receipt.fetch(:confirmation_type)
    assert_no_match HedgeVenueMigrationExecutor::CONFIRMATION, result.receipt.to_json
    assert_equal "<redacted>", result.receipt.dig(:to_leg_execution, :private_key)
    assert_equal "<redacted>", result.receipt.dig(:to_leg_execution, :signature)
  end

  private

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
end
