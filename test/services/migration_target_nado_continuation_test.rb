require "test_helper"

class MigrationTargetNadoContinuationTest < ActiveSupport::TestCase
  test "extended to nado delayed target dry run is ready to close source" do
    position = migration_position("extended")
    canary_dir = write_pending_canary(position: position, from: "extended", expected: "0.9134680515417161", source_size: "0.903", digest: "0xextendednado")

    result = continuation(
      position: position,
      from: "extended",
      canary_dir: canary_dir,
      extended_short: "0.903",
      nado_short: "0.913",
      target: "0.9134680515417161"
    ).run

    assert_equal "READY_TO_CLOSE_SOURCE", result.status, result.blockers.inspect
    assert_equal true, result.receipt.fetch(:target_confirmed)
    assert_equal false, result.receipt.fetch(:source_already_flat)
    assert_equal "0xextendednado", result.receipt.fetch(:nado_target_digest)
    assert_equal "extended", result.receipt.fetch(:source_close_plan).fetch("venue")
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "extended to nado delayed target live continuation closes source and finalizes" do
    position = migration_position("extended")
    canary_dir = write_pending_canary(position: position, from: "extended", expected: "0.9134680515417161", source_size: "0.903", digest: "0xextendednado")
    calls = []
    leg_runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "extended-close",
        after_short_eth: "0",
        receipt: { exchange_order_id: "extended-close", orders_placed: 1, signatures_created: 1 }
      }
    end

    result = continuation(
      position: position,
      from: "extended",
      canary_dir: canary_dir,
      extended_short: "0.903",
      nado_short: "0.913",
      target: "0.9134680515417161",
      live: true,
      confirmation: MigrationTargetNadoContinuation::CONFIRMATION,
      leg_runner: leg_runner
    ).run

    assert_equal "MIGRATION_FINALIZED", result.status, result.blockers.inspect
    assert_equal 1, calls.size
    assert_equal "extended", calls.first.fetch(:venue)
    assert_equal "buy", calls.first.fetch(:side)
    assert_equal true, calls.first.fetch(:reduce_only)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:continuation_of_accepted_nado_target)
    assert_equal "0xextendednado", result.receipt.fetch(:nado_target_digest)
    assert_equal "extended-close", result.receipt.fetch(:source_leg_exchange_order_id)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "live continuation does not require source recovery env gate" do
    position = migration_position("extended")
    canary_dir = write_pending_canary(position: position, from: "extended", expected: "0.9134680515417161", source_size: "0.903", digest: "0xextendednado")
    calls = []
    leg_runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "extended-close",
        after_short_eth: "0",
        receipt: { exchange_order_id: "extended-close", orders_placed: 1, signatures_created: 1 }
      }
    end

    result = continuation(
      position: position,
      from: "extended",
      canary_dir: canary_dir,
      extended_short: "0.903",
      nado_short: "0.913",
      target: "0.9134680515417161",
      live: true,
      confirmation: MigrationTargetNadoContinuation::CONFIRMATION,
      env: recovery_env.merge("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "false"),
      leg_runner: leg_runner
    ).run

    assert_equal "MIGRATION_FINALIZED", result.status, result.blockers.inspect
    assert_equal 1, calls.size
    assert_not_includes result.blockers, "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true"
    assert_equal true, result.receipt.fetch(:target_confirmed)
    assert_equal "nado", position.hedge.reload.execution_venue
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "continuation never opens or closes Nado target" do
    position = migration_position("ethereal")
    canary_dir = write_pending_canary(position: position, from: "ethereal", expected: "0.9363623373136126", source_size: "0.9671", digest: "0x22f2")
    calls = []
    leg_runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "ethereal-close",
        after_short_eth: "0",
        receipt: { exchange_order_id: "ethereal-close", orders_placed: 1, signatures_created: 1 }
      }
    end

    result = continuation(
      position: position,
      from: "ethereal",
      canary_dir: canary_dir,
      ethereal_short: "0.9671",
      nado_short: "0.936",
      target: "0.9363623373136126",
      live: true,
      confirmation: MigrationTargetNadoContinuation::CONFIRMATION,
      leg_runner: leg_runner
    ).run

    assert_equal "MIGRATION_FINALIZED", result.status, result.blockers.inspect
    assert_equal [ "ethereal" ], calls.map { |leg| leg.fetch(:venue) }
    assert_equal true, calls.first.fetch(:reduce_only)
    assert_equal "buy", calls.first.fetch(:side)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "ethereal to nado delayed target live continuation closes source and finalizes" do
    position = migration_position("ethereal")
    canary_dir = write_pending_canary(position: position, from: "ethereal", expected: "0.9363623373136126", source_size: "0.9671", digest: "0x22f2aaa2a032853609a860cf8b60c593da9085547b3dab646f2774783264e6a6")
    calls = []
    leg_runner = ->(leg, context:) do
      calls << leg
      {
        status: "confirmed",
        confirmed: true,
        orders_placed: 1,
        signatures_created: 1,
        exchange_order_id: "ethereal-close",
        after_short_eth: "0",
        receipt: { exchange_order_id: "ethereal-close", orders_placed: 1, signatures_created: 1 }
      }
    end

    result = continuation(
      position: position,
      from: "ethereal",
      canary_dir: canary_dir,
      ethereal_short: "0.9671",
      nado_short: "0.936",
      target: "0.9363623373136126",
      live: true,
      confirmation: MigrationTargetNadoContinuation::CONFIRMATION,
      leg_runner: leg_runner
    ).run

    assert_equal "MIGRATION_FINALIZED", result.status, result.blockers.inspect
    assert_equal "ethereal", calls.first.fetch(:venue)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal "0x22f2aaa2a032853609a860cf8b60c593da9085547b3dab646f2774783264e6a6", result.receipt.fetch(:nado_target_digest)
    assert_equal "ethereal-close", result.receipt.fetch(:source_leg_exchange_order_id)
    assert_equal true, result.receipt.fetch(:final_inside_tolerance)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "continuation refuses to close source while Nado target is still missing" do
    position = migration_position("ethereal")
    canary_dir = write_pending_canary(position: position, from: "ethereal", expected: "0.9363623373136126", source_size: "0.9671", digest: "0xpending")

    result = continuation(
      position: position,
      from: "ethereal",
      canary_dir: canary_dir,
      ethereal_short: "0.9671",
      nado_short: "0",
      target: "0.9363623373136126"
    ).run

    assert_equal "TARGET_STILL_PENDING", result.status
    assert_equal false, result.receipt.fetch(:target_confirmed)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_includes result.blockers, "Nado target short must be present"
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  test "source already flat continuation finalizes without source close order" do
    position = migration_position("ethereal")
    canary_dir = write_pending_canary(position: position, from: "ethereal", expected: "0.9363623373136126", source_size: "0.9671", digest: "0xalreadyflat")

    result = continuation(
      position: position,
      from: "ethereal",
      canary_dir: canary_dir,
      ethereal_short: "0",
      nado_short: "0.936",
      target: "0.9363623373136126",
      live: true,
      confirmation: MigrationTargetNadoContinuation::CONFIRMATION
    ).run

    assert_equal "MIGRATION_FINALIZED", result.status, result.blockers.inspect
    assert_equal true, result.receipt.fetch(:source_already_flat)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  ensure
    FileUtils.rm_rf(canary_dir) if canary_dir
  end

  private

  def continuation(position:, from:, canary_dir:, extended_short: "0", ethereal_short: "0", nado_short:, target:, live: false, confirmation: nil, env: recovery_env, leg_runner: nil)
    MigrationTargetNadoContinuation.new(
      position: position,
      from: from,
      to: "nado",
      canary_dir: canary_dir,
      receipt_dir: Rails.root.join("tmp/test-nado-continuations-#{SecureRandom.hex(4)}"),
      live: live,
      confirmation: confirmation,
      env: env,
      recovery_factory: ->(position:, from:, to:, dry_run:, live:, confirmation:) {
        MigrationTargetFirstSourceRecovery.new(
          position: position,
          from: from,
          to: to,
          dry_run: dry_run,
          live: live,
          confirmation: confirmation,
          env: env,
          extended_venue: FakeVenue.new("extended", extended_short),
          ethereal_venue: FakeVenue.new("ethereal", ethereal_short),
          nado_venue: FakeVenue.new("nado", nado_short),
          fresh_target: FreshTarget.new(target),
          leg_runner: leg_runner,
          receipt_dir: Rails.root.join("tmp/test-migration-recoveries-#{SecureRandom.hex(4)}"),
          require_recovery_live_gate: false
        )
      }
    )
  end

  def write_pending_canary(position:, from:, expected:, source_size:, digest:)
    dir = Rails.root.join("tmp/test-canary-continuation-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(dir)
    event = {
      action: "manual_live_canary",
      position_id: position.id,
      from_venue: from,
      to_venue: "nado",
      route: "#{from}->nado",
      timestamp: Time.current.utc.iso8601,
      final_status: "TARGET_ACCEPTED_AWAITING_CONTINUATION",
      target_leg_status: "TARGET_SUBMITTED_PENDING_READBACK",
      continuation_pending: true,
      nado_target_digest: digest,
      exchange_order_ids: [ digest ],
      orders_submitted: 1,
      orders_placed: 1,
      signatures_created: 1,
      planned_target_leg: {
        venue: "nado",
        action: "open_short",
        side: "sell",
        reduce_only: false,
        size_eth: expected,
        expected_after_short_eth: expected
      },
      planned_source_leg: {
        venue: from,
        action: "close_short",
        side: "buy",
        reduce_only: true,
        size_eth: source_size,
        expected_after_short_eth: "0"
      },
      continuation_command: "bin/rails migration:continue_target_first_after_nado_confirmed position_id=#{position.id} from=#{from} to=nado dry_run=true"
    }
    File.open(Pathname(dir).join("20260602.jsonl"), "a") { |file| file.puts(JSON.generate(event)) }
    dir
  end

  def recovery_env
    {
      "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def migration_position(execution_venue)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      mellow_metadata: JSON.generate({ "hedge_ready" => true }),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: execution_venue)
    position
  end

  class FreshTarget
    def initialize(target) = @target = target
    def resolve(refresh_if_stale:)
      {
        status: "ok",
        target_short_eth: BigDecimal(@target),
        target_source: "current_share_token_resolver",
        exposure_source: "current_share_token_resolver",
        exposure_refreshed_at: Time.current.iso8601,
        blockers: []
      }
    end
  end

  class FakeVenue
    def initialize(name, short)
      @name = name
      @short = BigDecimal(short)
    end

    def read_position(symbol:)
      return nil if @short.zero?

      { venue: @name, short_size: @short, size: -@short, symbol: "ETH-PERP" }
    end

    def account_state
      { open_orders_count: 0, blockers: [], warnings: [] }
    end

    def live_enabled? = true
  end
end
