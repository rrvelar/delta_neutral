require "test_helper"
require "rake"

class PositionsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("positions:list")
    %w[positions:list positions:activate positions:archive positions:dedupe].each { |task| Rake::Task[task].reenable }
  end

  test "positions list prints position and hedge state without live counters" do
    position = aerodrome_position(external_id: "71674988", active: true)
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")

    out, = capture_io { Rake::Task["positions:list"].invoke }
    payload = JSON.parse(out)

    assert_equal "positions_list", payload.fetch("action")
    row = payload.fetch("positions").find { |entry| entry.fetch("id") == position.id }
    assert_equal true, row.fetch("active")
    assert_equal "71674988", row.fetch("external_id")
    assert_equal "nado", row.fetch("hedge_venue")
    assert_equal true, row.fetch("hedge_active")
    assert row.fetch("updated_at").present?
    assert_equal "active production selection", row.fetch("active_state_reason")
    assert_equal 0, payload.fetch("orders_submitted")
    assert_equal 0, payload.fetch("signatures_created")
  end

  test "positions activate deactivates siblings and creates no orders or signatures" do
    active = aerodrome_position(external_id: "old", active: true)
    inactive = aerodrome_position(external_id: "new", active: false)
    inactive.create_hedge!(target: "1.0", tolerance: "0.03", active: false, execution_venue: "hyperliquid")

    with_position_id(inactive.id) do
      out, = capture_io { Rake::Task["positions:activate"].invoke }
      payload = JSON.parse(out)

      assert_equal inactive.id, payload.fetch("position_id")
      assert_equal true, payload.fetch("active")
      assert_equal true, payload.fetch("hedge_active")
      assert_not_equal "hyperliquid", payload.fetch("hedge_venue")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end

    assert_not active.reload.active?
    assert_predicate inactive.reload, :active?
    assert_predicate inactive.hedge.reload, :active?
  end

  test "positions archive deactivates safe flat position" do
    position = aerodrome_position(external_id: "archive", active: true)
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")

    with_position_id(position.id) do
      out, = capture_io { Rake::Task["positions:archive"].invoke }
      payload = JSON.parse(out)

      assert_equal "archived", payload.fetch("status")
      assert_equal false, payload.fetch("active")
      assert_equal false, payload.fetch("hedge_active")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "positions dedupe dry run identifies duplicate shape" do
    older = aerodrome_position(external_id: "71674988", active: false)
    newer = aerodrome_position(external_id: "71674988", active: true)
    newer.update!(pool_address: older.pool_address, wallet: older.wallet)

    with_env("dry_run" => "true") do
      out, = capture_io { Rake::Task["positions:dedupe"].invoke }
      payload = JSON.parse(out)
      group = payload.fetch("duplicate_groups").find { |entry| entry.fetch("canonical_position_id") == newer.id }

      assert group
      assert_includes group.fetch("duplicate_position_ids"), older.id
      assert_equal [], payload.fetch("applied")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  end

  test "positions dedupe archives inactive duplicates only with confirmation" do
    older = aerodrome_position(external_id: "71674988", active: false)
    newer = aerodrome_position(external_id: "71674988", active: true)
    newer.update!(pool_address: older.pool_address, wallet: older.wallet)

    with_env(
      "dry_run" => "false",
      "confirmation" => PositionProductionState::ARCHIVE_CONFIRMATION
    ) do
      out, = capture_io { Rake::Task["positions:dedupe"].invoke }
      payload = JSON.parse(out)

      assert_equal [], payload.fetch("blockers")
      assert payload.fetch("applied").any? { |entry| entry.fetch("id") == older.id && entry.fetch("archived") == true }
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end

    assert_not older.reload.active?
    assert_predicate newer.reload, :active?
  end

  private

  def aerodrome_position(external_id:, active:)
    Position.create!(
      user: users(:one),
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.752880354",
      asset1_amount: "959.310952",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: external_id,
      pool_address: "0xpool71674988",
      active: active
    )
  end

  def wallet
    @wallet ||= Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x#{SecureRandom.hex(20)}"
    )
  end

  def with_position_id(id)
    original = ENV["position_id"]
    ENV["position_id"] = id.to_s
    yield
  ensure
    original.nil? ? ENV.delete("position_id") : ENV["position_id"] = original
  end

  def with_env(values)
    originals = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    originals.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
