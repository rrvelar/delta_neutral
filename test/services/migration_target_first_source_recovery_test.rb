require "test_helper"

class MigrationTargetFirstSourceRecoveryTest < ActiveSupport::TestCase
  test "ethereal to nado dry run recognizes already finalized production no op" do
    position = migration_position(execution_venue: "nado")
    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11"
    ).run

    assert_equal "ALREADY_FINALIZED", result.status
    assert_equal "MIGRATION_FINALIZED", result.receipt.fetch(:lifecycle_state)
    assert_empty result.blockers
    assert_equal "nado", result.receipt.fetch(:production_venue)
    assert_equal true, result.receipt.fetch(:source_already_flat)
    assert_equal true, result.receipt.fetch(:target_confirmed)
    assert_equal true, result.receipt.fetch(:other_venues_flat)
    assert_equal true, result.receipt.fetch(:final_inside_tolerance)
    assert_equal true, result.receipt.fetch(:already_finalized)
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
    assert_equal false, result.receipt.fetch(:finalization_recommended)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_includes result.warnings, "Migration already finalized; no recovery action required."
  end

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

  # 2026-07-17 incident regression: the Extended close 503'd at submit, the leg
  # still carried after_short_eth "0.0" (expected value) while its own readback
  # showed the source at 1.61 on every poll — the outer verification trusted the
  # claim and falsely reported source flat + finalized the production venue.
  test "unconfirmed source close cannot report source flat or finalize" do
    position = migration_position(execution_venue: "extended")
    leg_runner = ->(leg, context:) do
      {
        status: "submitted_but_readback_pending",
        confirmed: false,
        orders_placed: 1,
        signatures_created: 1,
        after_short_eth: "0.0",
        readback: [ { short_size: "1.61", confirmed: false } ],
        blockers: []
      }
    end

    result = recovery(
      position: position,
      from: "extended",
      to: "ethereal",
      extended_short: "1.61",
      ethereal_short: "1.6131",
      target: "1.6131",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env.merge("EXTENDED_LIVE_ENABLED" => "true", "EXTENDED_MAINNET_PROBE_ENABLED" => "true"),
      leg_runner: leg_runner
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_equal "extended", position.hedge.reload.execution_venue, "must NOT finalize to the target on an unconfirmed close"
    assert_equal false, result.receipt.fetch(:production_venue_finalized)
    assert_equal "1.61", result.receipt.fetch(:final_source_short_eth), "final source short must come from the readback, not the claimed after_short_eth"
    assert_equal true, result.receipt.fetch(:readback_mismatch)
    assert_equal false, result.receipt.fetch(:readback_confirmed)
    assert_includes result.blockers.join(" "), "not confirmed"
    assert_includes result.receipt.fetch(:warnings).join(" "), "readback is authoritative"
  end

  test "submit_failed source close never reports source flat or finalizes" do
    position = migration_position(execution_venue: "extended")
    leg_runner = ->(leg, context:) do
      {
        status: "submit_failed",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 1,
        after_short_eth: "0.0",
        blockers: [ "Extended submit failed: HTTP 503" ]
      }
    end

    result = recovery(
      position: position,
      from: "extended",
      to: "ethereal",
      extended_short: "1.61",
      ethereal_short: "1.6131",
      target: "1.6131",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env.merge("EXTENDED_LIVE_ENABLED" => "true", "EXTENDED_MAINNET_PROBE_ENABLED" => "true"),
      leg_runner: leg_runner
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_includes result.blockers.join(" "), "HTTP 503"
    assert_equal "extended", position.hedge.reload.execution_venue
    assert_equal false, result.receipt.fetch(:production_venue_finalized)
    assert_equal "1.61", result.receipt.fetch(:final_source_short_eth)
    assert_equal false, result.receipt.fetch(:readback_confirmed)
  end

  test "unconfirmed source close without a readback falls back to a fresh venue read" do
    position = migration_position(execution_venue: "extended")
    leg_runner = ->(leg, context:) do
      { status: "submitted_but_readback_pending", confirmed: false, orders_placed: 1, signatures_created: 1, after_short_eth: "0.0", blockers: [] }
    end

    result = recovery(
      position: position,
      from: "extended",
      to: "ethereal",
      extended_short: "1.61",
      ethereal_short: "1.6131",
      target: "1.6131",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env.merge("EXTENDED_LIVE_ENABLED" => "true", "EXTENDED_MAINNET_PROBE_ENABLED" => "true"),
      leg_runner: leg_runner
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_equal "1.61", result.receipt.fetch(:final_source_short_eth), "fresh venue read is the fallback evidence"
    assert_equal "extended", position.hedge.reload.execution_venue
    assert_equal false, result.receipt.fetch(:production_venue_finalized)
  end

  test "source already flat live finalization updates execution venue without orders" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env
    ).run

    assert_equal "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK", result.status, result.blockers.inspect
    assert_equal "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK", result.receipt.fetch(:lifecycle_state)
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:would_execute_live)
  end

  test "live finalization blocks with wrong confirmation" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11",
      live: true,
      confirmation: "wrong",
      env: recovery_env
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationTargetFirstSourceRecovery::CONFIRMATION}"
    assert_equal "ethereal", position.hedge.reload.execution_venue
  end

  test "source already flat live finalization does not require recovery gate" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env.merge("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "false")
    ).run

    assert_equal "SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK", result.status, result.blockers.inspect
    assert_not_includes result.blockers, "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true"
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, result.receipt.fetch(:production_venue_finalized)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:orders_placed)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal false, result.receipt.fetch(:would_execute_live)
  end

  test "source still open live recovery still requires recovery gate" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "1.11",
      nado_short: "1.11",
      target: "1.11",
      live: true,
      confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION,
      env: recovery_env.merge("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "false")
    ).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_includes result.blockers, "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true"
    assert_equal "ethereal", position.hedge.reload.execution_venue
  end

  test "recovery blocks when target is missing" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "1.11",
      nado_short: "0",
      target: "1.11"
    ).run

    assert_equal "dry_run", result.status
    assert_includes result.blockers, "Nado target short must be present"
  end

  test "source still open and target confirmed builds only source close leg" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "1.11",
      nado_short: "1.11",
      target: "1.11"
    ).run

    leg = result.receipt.fetch(:planned_source_close_leg)
    assert_equal "dry_run", result.status
    assert_empty result.blockers
    assert_equal "ethereal", leg.fetch(:venue)
    assert_equal "close_short", leg.fetch(:action)
    assert_equal "buy", leg.fetch(:side)
    assert_equal true, leg.fetch(:reduce_only)
    assert_equal "1.11", leg.fetch(:size_eth)
    assert_equal "0", leg.fetch(:expected_after_short_eth)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "recovery blocks when third venue is not flat" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      extended_short: "0.2",
      ethereal_short: "1.11",
      nado_short: "1.11",
      target: "1.11"
    ).run

    assert_includes result.blockers, "unexpected third-venue short is present during source-close recovery"
  end

  test "source already flat does not finalize when combined is outside tolerance" do
    position = migration_position(execution_venue: "ethereal")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "0.9",
      target: "1.11"
    ).run

    assert_equal "dry_run", result.status
    assert_equal false, result.receipt.fetch(:finalization_recommended)
    assert_includes result.blockers, "Nado short must be within tolerance of fresh target"
  end

  test "already finalized no op blocks when target is outside tolerance" do
    position = migration_position(execution_venue: "nado")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      ethereal_short: "0",
      nado_short: "0.9",
      target: "1.11"
    ).run

    assert_equal "dry_run", result.status
    assert_equal "RECOVERY_BLOCKED", result.receipt.fetch(:lifecycle_state)
    assert_equal false, result.receipt.fetch(:already_finalized)
    assert_equal false, result.receipt.fetch(:production_venue_finalized)
    assert_equal false, result.receipt.fetch(:final_inside_tolerance)
    assert_includes result.blockers, "Nado short must be within tolerance of fresh target"
  end

  test "already finalized no op blocks when third venue is not flat" do
    position = migration_position(execution_venue: "nado")

    result = recovery(
      position: position,
      from: "ethereal",
      to: "nado",
      extended_short: "0.2",
      ethereal_short: "0",
      nado_short: "1.11",
      target: "1.11"
    ).run

    assert_equal "dry_run", result.status
    assert_equal false, result.receipt.fetch(:already_finalized)
    assert_equal false, result.receipt.fetch(:production_venue_finalized)
    assert_includes result.blockers, "unexpected third-venue short is present during source-close recovery"
  end

  test "extended to ethereal legacy recovery route still builds source close" do
    position = migration_position(execution_venue: "extended")

    result = recovery(
      position: position,
      from: "extended",
      to: "ethereal",
      extended_short: "0.8",
      ethereal_short: "0.8",
      target: "0.8"
    ).run

    leg = result.receipt.fetch(:planned_source_close_leg)
    assert_equal "extended", leg.fetch(:venue)
    assert_equal "buy", leg.fetch(:side)
    assert_equal true, leg.fetch(:reduce_only)
    assert_equal "0.8", leg.fetch(:size_eth)
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

  test "generic recovery builds source close for all target first route pairs" do
    pairs = [
      [ "extended", "ethereal" ],
      [ "ethereal", "extended" ],
      [ "extended", "nado" ],
      [ "nado", "extended" ],
      [ "ethereal", "nado" ],
      [ "nado", "ethereal" ]
    ]

    pairs.each do |from, to|
      position = migration_position(execution_venue: from)
      shorts = { "extended" => "0", "ethereal" => "0", "nado" => "0" }
      shorts[from] = "0.8"
      shorts[to] = "0.8"
      result = recovery(
        position: position,
        from: from,
        to: to,
        extended_short: shorts.fetch("extended"),
        ethereal_short: shorts.fetch("ethereal"),
        nado_short: shorts.fetch("nado"),
        target: "0.8"
      ).run

      leg = result.receipt.fetch(:planned_source_close_leg)
      assert_equal from, leg.fetch(:venue), "#{from}->#{to}"
      assert_equal "buy", leg.fetch(:side), "#{from}->#{to}"
      assert_equal true, leg.fetch(:reduce_only), "#{from}->#{to}"
      assert_no_match(/from must be extended|to must be ethereal/, result.receipt.to_json)
    end
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
