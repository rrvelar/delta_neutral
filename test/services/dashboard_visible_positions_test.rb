require "test_helper"

class DashboardVisiblePositionsTest < ActiveSupport::TestCase
  test "includes active position owned through current user's wallet even if direct user differs" do
    position = create_wallet_owned_position(user: users(:two), wallet_user: users(:one))

    visible_ids = DashboardVisiblePositions.new(user: users(:one)).call.pluck(:id)

    assert_includes visible_ids, position.id
  end

  test "does not include inactive wallet-owned positions" do
    position = create_wallet_owned_position(user: users(:two), wallet_user: users(:one), active: false)

    visible_ids = DashboardVisiblePositions.new(user: users(:one)).call.pluck(:id)

    assert_not_includes visible_ids, position.id
  end

  test "does not include another user's position when neither direct user nor wallet match" do
    position = create_wallet_owned_position(user: users(:two), wallet_user: users(:two))

    visible_ids = DashboardVisiblePositions.new(user: users(:one)).call.pluck(:id)

    assert_not_includes visible_ids, position.id
  end

  test "class convenience call includes wallet-owned Mellow position" do
    position = create_wallet_owned_position(user: users(:two), wallet_user: users(:one))

    visible_ids = DashboardVisiblePositions.call(user: users(:one)).pluck(:id)

    assert_includes visible_ids, position.id
  end

  test "positional initializer remains compatible with console checks" do
    position = create_wallet_owned_position(user: users(:two), wallet_user: users(:one))

    visible_ids = DashboardVisiblePositions.new(users(:one)).call.pluck(:id)

    assert_includes visible_ids, position.id
  end

  private

  def create_wallet_owned_position(user:, wallet_user:, active: true)
    wallet = Wallet.create!(
      user: wallet_user,
      network: networks(:base),
      address: "0x#{SecureRandom.hex(20)}"
    )
    position = Position.create!(
      user: user,
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("0.5"),
      asset1_amount: BigDecimal("1000"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: "mellow:71261528",
      pool_address: "0xpool",
      active: active
    )
    position.create_hedge!(target: BigDecimal("1.0"), tolerance: BigDecimal("0.03"), active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      extended_short_eth: BigDecimal("0.5"),
      extended_status: "active",
      ethereal_short_eth: BigDecimal("0"),
      ethereal_status: "flat",
      nado_short_eth: BigDecimal("0"),
      nado_status: "flat",
      combined_short_eth: BigDecimal("0.5"),
      target_short_eth: BigDecimal("0.5"),
      tolerance_abs_eth: BigDecimal("0.015"),
      drift_eth: BigDecimal("0"),
      inside_tolerance: true,
      signer_status: "ok"
    )
    position
  end
end
