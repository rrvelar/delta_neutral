require "test_helper"

class MigrationTargetFirstSourceRecoveryTest < ActiveSupport::TestCase
  test "ethereal to nado dry run recognizes source already manually closed and recommends finalization" do
    position = migration_position(execution_venue: "ethereal")
    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11"
    ).run

    assert_equal "SOURCE_ALREADY_FLAT_READY_TO_FINALIZE", result.status
    assert_equal true, result.receipt.fetch(:source_already_flat)
    assert_equal true, result.receipt.fetch(:finalization_recommended)
    assert_match "from=ethereal to=nado", result.receipt.fetch(:finalization_command)
    assert_equal "ethereal", position.hedge.reload.execution_venue
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "ethereal to nado recovery closes only Ethereal source and finalizes after safe readback" do
    position = migration_position(execution_venue: "ethereal")
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

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "1.11",
      nado_short: "1.11",
      target: "1.11",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env,
      leg_runner: leg_runner
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_CONFIRMED", result.status, result.blockers.inspect
    assert_equal 1, calls.size
    assert_equal "ethereal", calls.first.fetch(:venue)
    assert_equal "buy", calls.first.fetch(:side)
    assert_equal true, calls.first.fetch(:reduce_only)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
  end

  test "nado to ethereal recovery builds Nado reduce only source close" do
    position = migration_position(execution_venue: "nado")
    result = recovery(
      position: position,
      from: "nado",
      to: "ethereal",
      nado_short: "0.8",
      ethereal_short: "0.8",
      target: "0.8"
    ).run

    leg = result.receipt.fetch(:planned_source_close_leg)
    assert_equal "dry_run", result.status
    assert_equal "nado", leg.fetch(:venue)
    assert_equal "buy", leg.fetch(:side)
    assert_equal true, leg.fetch(:reduce_only)
    assert_equal "0.8", leg.fetch(:size_eth)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  private

  def recovery(position:, from:, to:, extended_short: "0", ethereal_short: "0", nado_short: "0", target:, live: false, confirmation: nil, env: {}, leg_runner: nil)
    MigrationTargetFirstSourceRecovery.new(
      position: position,
      from: from,
      to: to,
      live: live,
      confirmation: confirmation,
      env: env,
      extended_venue: FakeVenue.new("extended", extended_short),
      ethereal_venue: FakeVenue.new("ethereal", ethereal_short),
      nado_venue: FakeVenue.new("nado", nado_short),
      fresh_target: FreshTarget.new(target),
      leg_runner: leg_runner,
      receipt_dir: Rails.root.join("tmp/test-migration-recoveries-#{SecureRandom.hex(4)}")
    )
  end

  def recovery_env
    {
      "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "true",
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
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      mellow_metadata: JSON.generate({ "hedge_ready" => true }),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.11",
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
        blockers: [],
        orders_submitted: 0,
        signatures_created: 0
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
