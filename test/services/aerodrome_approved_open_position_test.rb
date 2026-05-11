require "test_helper"
require "tmpdir"

class AerodromeApprovedOpenPositionTest < ActiveSupport::TestCase
  setup do
    @env = {
      "AERODROME_MAX_SHORT_ETH" => "0.02",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "50",
      "AERODROME_APPROVED_OPEN_POSITION_SIZE_TOLERANCE_ETH" => "0.002"
    }
  end

  test "approved successful production live log with matching current ETH passes" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.0101" })

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.0102")).report

          assert_equal true, report.fetch(:approved)
          assert_equal "approved", report.fetch(:approval_status)
          assert_equal "PASS", report.fetch(:status)
          assert_empty report.fetch(:blockers)
        end
      end
    end
  end

  test "approved production cap tier passes within hard ceiling" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.40" }, max_eth: "0.55", max_notional: "1300")

        with_env(@env.merge("AERODROME_MAX_SHORT_ETH" => "0.55", "AERODROME_MAX_SHORT_NOTIONAL_USD" => "1300")) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.4005")).report

          assert_equal "approved", report.fetch(:approval_status)
          assert_equal "PASS", report.fetch(:status)
          assert_empty report.fetch(:blockers)
        end
      end
    end
  end

  test "blocks approved log max ETH over production hard ceiling" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.40" }, max_eth: "0.76", max_notional: "1300")

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.40")).report

          assert_equal "out_of_bounds", report.fetch(:approval_status)
          assert_includes report.fetch(:blockers), "Approved max ETH exceeds production hard ceiling"
        end
      end
    end
  end

  test "blocks approved log max notional over production hard ceiling" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.40" }, max_eth: "0.55", max_notional: "2001")

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.40")).report

          assert_equal "out_of_bounds", report.fetch(:approval_status)
          assert_includes report.fetch(:blockers), "Approved max notional exceeds production hard ceiling"
        end
      end
    end
  end

  test "current ETH nil warns when approved open hedge is no longer open" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.0101" })

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: nil).report

          assert_equal "current_nil", report.fetch(:approval_status)
          assert_equal "WARN", report.fetch(:status)
          assert_includes report.fetch(:warnings), "Approved open hedge is no longer open"
        end
      end
    end
  end

  test "blocks current ETH over max ETH" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.0101" })

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.03")).report

          assert_equal "out_of_bounds", report.fetch(:approval_status)
          assert_equal "BLOCKED", report.fetch(:status)
          assert_includes report.fetch(:blockers), "Current ETH short exceeds approved max ETH"
        end
      end
    end
  end

  test "blocks current ETH notional over max" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.0101" }, max_notional: "20")

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.011")).report

          assert_equal "out_of_bounds", report.fetch(:approval_status)
          assert_includes report.fetch(:blockers), "Current ETH notional exceeds approved max notional"
        end
      end
    end
  end

  test "blocks current ETH outside tolerance" do
    with_position do |position|
      Dir.mktmpdir do |dir|
        write_log(dir, final_position: { asset: "ETH", size: "-0.0101" })

        with_env(@env) do
          report = build_service(log_dir: dir, position: position, current_position: eth_position("-0.015")).report

          assert_equal "mismatch", report.fetch(:approval_status)
          assert_includes report.fetch(:blockers), "Current ETH short differs from approved final size beyond tolerance"
        end
      end
    end
  end

  test "manual action required is not approved" do
    Dir.mktmpdir do |dir|
      write_log(dir, manual_action_required: true)

      with_env(@env) do
        report = build_service(log_dir: dir, current_position: eth_position("-0.0101")).report

        assert_equal false, report.fetch(:approved)
        assert_equal "not_approved", report.fetch(:approval_status)
      end
    end
  end

  private

  def build_service(log_dir:, current_position:, position: nil)
    AerodromeApprovedOpenPosition.new(log_dir: log_dir, current_position: current_position, position: position)
  end

  def write_log(dir, final_position: { asset: "ETH", size: "-0.0101" }, status: "success", manual_action_required: false, confirmed: true, max_eth: "0.02", max_notional: "50")
    File.write(
      File.join(dir, "20260510120000-test.jsonl"),
      [
        { type: "start", gates: { max_short_eth: max_eth, max_short_notional_usd: max_notional } }.to_json,
        {
          type: "finish",
          status: status,
          stop_reason: "duration complete",
          position_left_open: true,
          final_position: final_position,
          final_position_confirmed: confirmed,
          manual_action_required: manual_action_required,
          errors: []
        }.to_json
      ].join("\n")
    )
  end

  def with_position
    position = create_aerodrome_position
    yield position
  ensure
    position&.destroy
  end

  def create_aerodrome_position
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
      asset0_amount: "1.1",
      asset1_amount: "500.0",
      asset0_price_usd: "2300.0",
      asset1_price_usd: "1.0",
      external_id: "315985",
      pool_address: "0xpool",
      active: true
    )
  end

  def eth_position(size)
    { asset: "ETH", size: BigDecimal(size) }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end
end
