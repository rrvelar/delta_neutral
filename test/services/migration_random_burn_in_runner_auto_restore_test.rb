require "test_helper"

# Restoration of the active venue's auto after a defensive executor pause, once
# recovery proves the direct market safe (the 2026-07-11 auto-restore gap: the
# defensive pause disabled every venue auto, the hold rebalance was then blocked
# by the disabled auto, and the runner stopped while the position drifted).
class MigrationRandomBurnInRunnerAutoRestoreTest < ActiveSupport::TestCase
  RESTORE_REASON = "restore venue auto after defensive recovery reconciled safe".freeze

  test "safe recovery restores the active venue auto with an audited reason" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position)

    result = runner.send(:restore_active_venue_auto_after_safe_recovery!, safe_report)

    assert_equal true, result[:restored]
    assert_equal "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", result[:key]
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    audit = OperationalSettingAudit.where(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED").order(created_at: :desc).first
    assert_equal RESTORE_REASON, audit.reason
    assert_equal "true", audit.new_value
    # only the active venue's auto is enabled (finalize policy semantics)
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
    assert_equal false, OperationalSettings.enabled?("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
  end

  test "restore is a no-op when the active venue auto is already enabled" do
    position = ethereal_position
    disable_all_autos!
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test setup")
    runner = build_runner(position)

    result = runner.send(:restore_active_venue_auto_after_safe_recovery!, safe_report)

    assert_equal false, result[:restored]
    assert_equal "already_enabled", result[:reason]
  end

  test "restore is skipped when the report venue does not match the hedge execution venue" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position)

    result = runner.send(:restore_active_venue_auto_after_safe_recovery!, safe_report(production_venue: "extended"))

    assert_equal false, result[:restored]
    assert_equal "hedge_venue_mismatch", result[:reason]
    assert_equal false, OperationalSettings.enabled?("EXTENDED_AUTO_REBALANCE_ENABLED")
  end

  test "restore is skipped when the runner is not live" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position, live: false)

    result = runner.send(:restore_active_venue_auto_after_safe_recovery!, safe_report)

    assert_equal false, result[:restored]
    assert_equal "not_live", result[:reason]
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "hold rebalance recovery restores the auto only when the direct market is safe" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position, preflight: safe_report)

    recovered = runner.send(:recover_hold_rebalance_check, zero_submit_blocked_check)

    assert_equal "recovered_after_direct_market_safe_preflight", recovered[:reason]
    assert_equal true, recovered.dig(:active_venue_auto_restore, :restored)
    assert_equal true, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "hold rebalance recovery leaves the auto paused when outside tolerance" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position, preflight: unsafe_report(inside_tolerance: false))

    recovered = runner.send(:recover_hold_rebalance_check, zero_submit_blocked_check)

    refute_equal "recovered_after_direct_market_safe_preflight", recovered[:reason]
    assert_nil recovered[:active_venue_auto_restore]
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "hold rebalance recovery leaves the auto paused when open orders exist" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position, preflight: unsafe_report(open_orders: 1))

    recovered = runner.send(:recover_hold_rebalance_check, zero_submit_blocked_check)

    assert_nil recovered[:active_venue_auto_restore]
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "hold rebalance recovery leaves the auto paused when readback blockers are present" do
    position = ethereal_position
    disable_all_autos!
    runner = build_runner(position, preflight: unsafe_report(blockers: [ "unconfirmed venue readback: ethereal" ]))

    recovered = runner.send(:recover_hold_rebalance_check, zero_submit_blocked_check)

    assert_nil recovered[:active_venue_auto_restore]
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  test "hold rebalance recovery leaves the auto paused when a second venue holds a short" do
    position = ethereal_position
    disable_all_autos!
    report = safe_report
    report[:venues]["extended"] = { short_eth: "0.5", open_orders_count: 0 }
    report[:active_short_venues] = [ "ethereal", "extended" ]
    runner = build_runner(position, preflight: report)

    recovered = runner.send(:recover_hold_rebalance_check, zero_submit_blocked_check)

    assert_nil recovered[:active_venue_auto_restore]
    assert_equal false, OperationalSettings.enabled?("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  private

  def build_runner(position, live: true, preflight: nil)
    MigrationRandomBurnInRunner.new(
      position: position,
      duration_minutes: 0,
      interval_seconds: 0,
      max_cycles: 1,
      live: live,
      confirmation: live ? MigrationRandomBurnInRunner::CONFIRMATION : nil,
      log_dir: Rails.root.join("tmp/test-burn-in-auto-restore-#{SecureRandom.hex(4)}"),
      stdout: StringIO.new,
      preflight_factory: preflight ? ->(position:, stage:) { preflight } : nil
    )
  end

  def safe_report(production_venue: "ethereal")
    {
      production_venue: production_venue,
      active_short_venues: [ "ethereal" ],
      inside_tolerance: true,
      blockers: [],
      venues: {
        "ethereal" => { short_eth: "1.6", open_orders_status: "zero", open_orders_count: 0 },
        "extended" => { short_eth: "0", open_orders_status: "zero", open_orders_count: 0 },
        "nado" => { short_eth: "0", open_orders_status: "zero", open_orders_count: 0 }
      },
      target: { target_short_eth: "1.6" }
    }
  end

  def unsafe_report(inside_tolerance: true, open_orders: 0, blockers: [])
    report = safe_report
    report[:inside_tolerance] = inside_tolerance
    report[:blockers] = blockers
    if open_orders.positive?
      report[:venues]["ethereal"][:open_orders_status] = "blocked"
      report[:venues]["ethereal"][:open_orders_count] = open_orders
    end
    report
  end

  def zero_submit_blocked_check(status: "blocked_before_submit")
    {
      reason: "blocked",
      status: status,
      blockers: [ "active venue one-shot rebalance status is blocked_before_submit" ],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      rebalance: { status: status, orders_submitted: 0, orders_placed: 0, signatures_created: 0 }
    }
  end

  def disable_all_autos!
    %w[AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED EXTENDED_AUTO_REBALANCE_ENABLED AERODROME_NADO_AUTO_REBALANCE_ENABLED].each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "test setup")
    end
  end

  def ethereal_position
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
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
    position
  end
end
