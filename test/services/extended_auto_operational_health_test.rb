require "test_helper"

class ExtendedAutoOperationalHealthTest < ActiveSupport::TestCase
  test "health is healthy for fresh Extended production snapshot in tolerance" do
    position = health_position
    create_dashboard_snapshot(position)
    create_supporting_snapshots(position)
    create_rebalance(position, status: ShortRebalance::STATUS_SUCCESS, old_short: "0.79", new_short: "0.8", at: 1.minute.ago)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal ExtendedAutoOperationalHealth::STATUS_HEALTHY, report.fetch(:status)
    assert_empty report.fetch(:action_required)
    assert_equal "0.8", report.dig(:exposure, :extended_short_eth)
  end

  test "health is watch when snapshot is stale" do
    position = health_position
    create_dashboard_snapshot(position, refreshed_at: 3.minutes.ago)
    create_supporting_snapshots(position)
    create_rebalance(position, status: ShortRebalance::STATUS_SUCCESS, old_short: "0.79", new_short: "0.8", at: 1.minute.ago)

    with_env("POSITION_DASHBOARD_SNAPSHOT_STALE_AFTER_SECONDS" => "120", "POSITION_DASHBOARD_SNAPSHOT_CRITICAL_STALE_AFTER_SECONDS" => "600") do
      report = ExtendedAutoOperationalHealth.new(position: position).report

      assert_equal ExtendedAutoOperationalHealth::STATUS_WATCH, report.fetch(:status)
      assert_includes report.fetch(:warnings), "Position dashboard snapshot is stale."
    end
  end

  test "health is action required when Ethereal exposure exists" do
    position = health_position
    create_dashboard_snapshot(position, ethereal_short: "0.01")
    create_supporting_snapshots(position)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal ExtendedAutoOperationalHealth::STATUS_ACTION_REQUIRED, report.fetch(:status)
    assert_includes report.fetch(:action_required), "Ethereal is not flat while production venue is Extended."
  end

  test "health is action required when Nado exposure exists" do
    position = health_position
    create_dashboard_snapshot(position, nado_short: "0.01")
    create_supporting_snapshots(position)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal ExtendedAutoOperationalHealth::STATUS_ACTION_REQUIRED, report.fetch(:status)
    assert_includes report.fetch(:action_required), "Nado is not flat while production venue is Extended."
  end

  test "health is action required when signer down and auto enabled" do
    position = health_position
    create_dashboard_snapshot(position, signer_status: "down")
    create_supporting_snapshots(position)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal ExtendedAutoOperationalHealth::STATUS_ACTION_REQUIRED, report.fetch(:status)
    assert_includes report.fetch(:action_required), "Extended signer is down while auto is enabled."
  end

  test "health warns when latest rebalance failed" do
    position = health_position
    create_dashboard_snapshot(position)
    create_supporting_snapshots(position)
    create_rebalance(position, status: ShortRebalance::STATUS_SUCCESS, old_short: "0.78", new_short: "0.79", at: 2.minutes.ago)
    create_rebalance(position, status: ShortRebalance::STATUS_FAILED, old_short: "0.79", new_short: "0.8", at: 1.minute.ago)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_includes report.fetch(:warnings), "Latest Extended rebalance failed."
  end

  test "health requires action when pending rebalance is too old" do
    position = health_position
    create_dashboard_snapshot(position)
    create_supporting_snapshots(position)
    create_rebalance(position, status: ShortRebalance::STATUS_PENDING, old_short: "0.79", new_short: "0.8", at: 20.minutes.ago)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal ExtendedAutoOperationalHealth::STATUS_ACTION_REQUIRED, report.fetch(:status)
    assert_includes report.fetch(:action_required), "Pending Extended rebalance is older than 600s."
  end

  test "duplicate recent success rows are detected as duplicate risk" do
    position = health_position
    create_dashboard_snapshot(position)
    create_supporting_snapshots(position)
    create_rebalance(position, status: ShortRebalance::STATUS_SUCCESS, old_short: "0.79", new_short: "0.8", at: 30.seconds.ago)
    create_rebalance(position, status: ShortRebalance::STATUS_SUCCESS, old_short: "0.79", new_short: "0.81", at: 20.seconds.ago)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal true, report.fetch(:duplicate_risk_detected)
    assert_includes report.fetch(:action_required), "Duplicate-risk Extended rebalance pattern detected."
  end

  test "short rebalance history is not used as current exposure" do
    position = health_position
    create_dashboard_snapshot(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0")
    create_supporting_snapshots(position)
    create_rebalance(position, venue: "ethereal", status: ShortRebalance::STATUS_SUCCESS, old_short: "9", new_short: "9", at: 1.minute.ago)

    report = ExtendedAutoOperationalHealth.new(position: position).report

    assert_equal "0.8", report.dig(:exposure, :extended_short_eth)
    assert_equal "0.0", report.dig(:exposure, :ethereal_short_eth)
  end

  private

  def health_position
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.hex(6),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      active: true
    )
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    position
  end

  def create_dashboard_snapshot(position, extended_short: "0.8", ethereal_short: "0", nado_short: "0", refreshed_at: Time.current, signer_status: "ok")
    combined = BigDecimal(extended_short) + BigDecimal(ethereal_short) + BigDecimal(nado_short)
    target = BigDecimal("0.8")
    tolerance = BigDecimal("0.024")
    position.create_position_dashboard_snapshot!(
      refreshed_at: refreshed_at,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: target,
      tolerance_ratio: "0.03",
      tolerance_abs_eth: tolerance,
      combined_short_eth: combined,
      drift_eth: target - combined,
      inside_tolerance: (target - combined).abs <= tolerance,
      extended_short_eth: extended_short,
      ethereal_short_eth: ethereal_short,
      nado_short_eth: nado_short,
      extended_status: BigDecimal(extended_short).positive? ? "active" : "flat",
      ethereal_status: BigDecimal(ethereal_short).positive? ? "active" : "flat",
      nado_status: BigDecimal(nado_short).positive? ? "active" : "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      extended_auto_enabled: true,
      extended_live_enabled: true,
      signer_status: signer_status,
      signer_checked_at: refreshed_at,
      open_orders_count_extended: 0
    )
  end

  def create_supporting_snapshots(position)
    position.create_position_rewards_fees_snapshot!(refreshed_at: Time.current, refresh_status: "ok", rewards_value_state: "estimated", fee_value_state: "verified_zero")
    position.create_position_hedge_accounting_snapshot!(refreshed_at: Time.current, refresh_status: "ok", venue: "extended", current_short_eth: "0.8")
  end

  def create_rebalance(position, status:, old_short:, new_short:, at:, venue: "extended")
    position.hedge.short_rebalances.create!(
      venue: venue,
      asset: "WETH",
      old_short_size: old_short,
      new_short_size: new_short,
      status: status,
      rebalanced_at: at,
      message: status
    )
  end

  def with_env(values)
    old = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    old.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
