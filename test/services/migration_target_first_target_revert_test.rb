require "test_helper"

# Revert recovery: close ONLY the target leg reduce-only and keep the source as
# the surviving production venue. Mirror image of the source-close recovery.
class MigrationTargetFirstTargetRevertTest < ActiveSupport::TestCase
  test "dry run builds a reduce-only target close leg and keeps the source" do
    position = migration_position(execution_venue: "nado")
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295"
    ).run

    leg = result.receipt.fetch(:planned_target_close_leg)
    assert_equal "dry_run", result.status
    assert_empty result.blockers
    assert_equal "extended", leg.fetch(:venue)
    assert_equal "close_short", leg.fetch(:action)
    assert_equal "buy", leg.fetch(:side)
    assert_equal true, leg.fetch(:reduce_only)
    assert_equal "1.295", leg.fetch(:size_eth)
    assert_equal "0", leg.fetch(:expected_after_short_eth)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live revert closes only the target and preserves the source with exactly one active venue" do
    position = migration_position(execution_venue: "nado")
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

    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      live: true,
      confirmation: MigrationTargetFirstTargetRevert::CONFIRMATION,
      env: revert_env,
      leg_runner: leg_runner
    ).run

    assert_equal "TARGET_REVERT_CONFIRMED", result.status, result.blockers.inspect
    assert_equal 1, calls.size
    assert_equal "extended", calls.first.fetch(:venue)
    assert_equal "buy", calls.first.fetch(:side)
    assert_equal true, calls.first.fetch(:reduce_only)
    assert_equal true, result.receipt.fetch(:target_flat_after)
    assert_equal true, result.receipt.fetch(:source_preserved_after)
    assert_equal true, result.receipt.fetch(:exactly_one_active_venue)
    assert_equal [ "nado" ], result.receipt.fetch(:active_short_venues_after)
    assert_equal true, result.receipt.fetch(:open_orders_clear_after)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  test "live revert re-points the production venue to the source when it was left on the target" do
    position = migration_position(execution_venue: "extended")
    leg_runner = ->(leg, context:) do
      { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "extended-close", after_short_eth: "0" }
    end

    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      live: true,
      confirmation: MigrationTargetFirstTargetRevert::CONFIRMATION,
      env: revert_env,
      leg_runner: leg_runner
    ).run

    assert_equal "TARGET_REVERT_CONFIRMED", result.status, result.blockers.inspect
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
  end

  test "revert finalization never re-enables any venue auto gate as a side effect" do
    position = migration_position(execution_venue: "extended")
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test setup")
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test setup")
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test setup")
    leg_runner = ->(leg, context:) do
      { status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1, exchange_order_id: "extended-close", after_short_eth: "0" }
    end

    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      live: true,
      confirmation: MigrationTargetFirstTargetRevert::CONFIRMATION,
      env: revert_env,
      leg_runner: leg_runner
    ).run

    assert_equal "TARGET_REVERT_CONFIRMED", result.status, result.blockers.inspect
    assert_equal "nado", position.hedge.reload.execution_venue
    # 2026-07-17 regression: finalization must not flip any auto gate back on.
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "blocks when the source is flat because a revert must keep one live source leg" do
    position = migration_position(execution_venue: "nado")
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "0",
      extended_short: "1.295"
    ).run

    assert_equal "dry_run", result.status
    assert_includes result.blockers.join(" "), "source short must be preserved"
  end

  test "blocks when the target is already flat" do
    position = migration_position(execution_venue: "nado")
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "0"
    ).run

    assert_equal "dry_run", result.status
    assert_includes result.blockers.join(" "), "target short must be present"
  end

  test "blocks when a third venue is not flat" do
    position = migration_position(execution_venue: "nado")
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      ethereal_short: "0.2"
    ).run

    assert_includes result.blockers.join(" "), "unexpected third-venue short is present during target revert"
  end

  test "live revert blocks with the wrong confirmation and does not submit" do
    position = migration_position(execution_venue: "nado")
    calls = []
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      live: true,
      confirmation: "wrong",
      env: revert_env,
      leg_runner: ->(leg, context:) { calls << leg; {} }
    ).run

    assert_equal "TARGET_REVERT_BLOCKED", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationTargetFirstTargetRevert::CONFIRMATION}"
    assert_empty calls
  end

  test "live revert blocks when the revert gate is disabled" do
    position = migration_position(execution_venue: "nado")
    result = revert(
      position: position,
      from: "nado",
      to: "extended",
      nado_short: "1.297",
      extended_short: "1.295",
      live: true,
      confirmation: MigrationTargetFirstTargetRevert::CONFIRMATION,
      env: revert_env.merge("MIGRATION_TARGET_FIRST_TARGET_REVERT_ENABLED" => "false")
    ).run

    assert_equal "TARGET_REVERT_BLOCKED", result.status
    assert_includes result.blockers, "MIGRATION_TARGET_FIRST_TARGET_REVERT_ENABLED must be true"
  end

  private

  def revert(position:, from:, to:, extended_short: "0", ethereal_short: "0", nado_short: "0", live: false, confirmation: nil, env: {}, leg_runner: nil)
    MigrationTargetFirstTargetRevert.new(
      position: position,
      from: from,
      to: to,
      live: live,
      confirmation: confirmation,
      env: env,
      extended_venue: FakeVenue.new("extended", extended_short),
      ethereal_venue: FakeVenue.new("ethereal", ethereal_short),
      nado_venue: FakeVenue.new("nado", nado_short),
      leg_runner: leg_runner,
      receipt_dir: Rails.root.join("tmp/test-migration-reverts-#{SecureRandom.hex(4)}")
    )
  end

  def revert_env
    {
      "MIGRATION_TARGET_FIRST_TARGET_REVERT_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_HEDGE_LIVE_ENABLED" => "true",
      "AERODROME_NADO_LIVE_MIGRATION_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  def migration_position(execution_venue:)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.297",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: execution_venue)
    position
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
