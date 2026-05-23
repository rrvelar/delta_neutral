require "test_helper"

class AerodromeAutoRebalanceStatusTest < ActiveSupport::TestCase
  test "returns inside tolerance state correctly" do
    position = create_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
      report = build_report(position, current_short: "1.22")

      assert_equal false, report.fetch(:database_write)
      assert_equal false, report.fetch(:external_api)
      assert_equal hedge, report.fetch(:hedge)
      assert_equal "1.25", report.fetch(:current_target_hedge_eth)
      assert_equal "1.22", report.fetch(:current_hyperliquid_eth_short)
      assert_equal "0.03", report.fetch(:current_drift_eth)
      assert_equal "0.0625", report.fetch(:tolerance_eth)
      assert_equal true, report.fetch(:inside_tolerance)
      assert_equal false, report.fetch(:rebalance_needed)
    end
  end

  test "returns rebalance needed when drift exceeds tolerance" do
    position = create_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    with_env(
      "AERODROME_HEDGE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_LIVE_APPROVED" => "false",
      "HYPERLIQUID_TESTNET" => "true"
    ) do
      report = build_report(position, current_short: "1.0")

      assert_equal false, report.fetch(:inside_tolerance)
      assert_equal true, report.fetch(:rebalance_needed)
      assert_includes report.fetch(:blockers), "rebalance needed but AERODROME_HEDGE_ENABLED is not true"
      assert_includes report.fetch(:blockers), "rebalance needed but AERODROME_HEDGE_PAUSED is true"
    end
  end

  test "reads recurring schedules" do
    position = create_position
    Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)

    report = build_report(position, current_short: "1.22")

    assert_equal "every minute", report.dig(:scheduler, :position_sync_schedule)
    assert_equal "every 5 minutes", report.dig(:scheduler, :hedge_sync_schedule)
  end

  test "includes last short rebalance summary" do
    position = create_position
    hedge = Hedge.create!(position: position, target: "1.0", tolerance: "0.05", active: true)
    rebalance = hedge.short_rebalances.create!(
      asset: "WETH",
      old_short_size: "0.0",
      new_short_size: "1.25",
      realized_pnl: "0",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: Time.zone.local(2026, 5, 11, 12, 0, 0)
    )

    report = build_report(position, current_short: "1.25")

    assert_equal rebalance, report.fetch(:last_short_rebalance)
    assert_equal rebalance.rebalanced_at, report.fetch(:last_rebalance_time)
    assert_equal ShortRebalance::STATUS_SUCCESS, report.fetch(:last_rebalance_status)
  end

  test "uses Nado current short and auto gate without Hyperliquid pause blockers" do
    position = create_position
    Hedge.create!(
      position: position,
      target: "1.0",
      tolerance: "0.001",
      active: true,
      execution_venue: "nado"
    )

    with_env(
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_HEDGE_PAUSED" => "true",
      "AERODROME_HEDGE_ENABLED" => "false"
    ) do
      report = AerodromeAutoRebalanceStatus.new(
        position: position,
        dashboard_status: {
          execution_venue: "nado",
          current_short_eth: "1.2495",
          drift_eth: "0.0005",
          margin_mode: "isolated",
          isolated_margin_usd: "2500"
        }
      ).report

      assert_equal "nado", report.fetch(:execution_venue)
      assert_equal "Nado", report.fetch(:execution_venue_name)
      assert_equal "1.2495", report.fetch(:current_venue_eth_short)
      assert_equal false, report.fetch(:rebalance_needed)
      assert_equal true, report.fetch(:inside_tolerance)
      assert_equal "disabled", report.fetch(:auto_rebalance_status)
      assert_equal "Manual Nado hedge is active; automatic Nado rebalance is disabled.", report.fetch(:auto_rebalance_message)
      assert_empty report.fetch(:blockers)
    end
  end

  test "blocks Nado auto rebalance only on Nado auto gate when drift exceeds tolerance" do
    position = create_position
    Hedge.create!(
      position: position,
      target: "1.0",
      tolerance: "0.001",
      active: true,
      execution_venue: "nado"
    )

    with_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false", "AERODROME_HEDGE_PAUSED" => "true") do
      report = AerodromeAutoRebalanceStatus.new(
        position: position,
        dashboard_status: {
          execution_venue: "nado",
          current_short_eth: "1.20",
          drift_eth: "0.05"
        }
      ).report

      assert_equal true, report.fetch(:rebalance_needed)
      assert_includes report.fetch(:blockers), "rebalance needed but AERODROME_NADO_AUTO_REBALANCE_ENABLED is not true"
      refute_includes report.fetch(:blockers), "rebalance needed but AERODROME_HEDGE_PAUSED is true"
    end
  end

  private

  def build_report(position, current_short:)
    target = position.asset0_amount * position.hedge.target
    AerodromeAutoRebalanceStatus.new(
      position: position,
      dashboard_status: {
        current_short_eth: current_short,
        drift_eth: (target - BigDecimal(current_short)).to_s("F")
      }
    ).report
  end

  def create_position
    dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    wallet = Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
    Position.create!(
      user: users(:one),
      dex: dex,
      wallet: wallet,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.25",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: SecureRandom.hex(4),
      pool_address: "0xpool",
      active: true
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
