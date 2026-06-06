require "test_helper"

class NadoMigrationReadbackTest < ActiveSupport::TestCase
  test "canonical readback confirms rounded Nado target inside route tolerance" do
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(6),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "ethereal")
    venues = {
      "extended" => ReadbackVenue.new("0"),
      "ethereal" => ReadbackVenue.new("0"),
      "nado" => ReadbackVenue.new("2.461")
    }

    report = NadoMigrationReadback.confirm_target_short(
      position: position,
      from: "ethereal",
      to: "nado",
      expected_target_short: "2.461333",
      tolerance_eth: "0.073",
      venues: venues,
      attempts: 1,
      interval_seconds: 0
    )

    assert_equal true, report.fetch(:confirmed)
    assert_equal true, report.fetch(:target_confirmed)
    assert_equal true, report.fetch(:source_flat)
    assert_equal true, report.fetch(:third_venue_flat)
    assert_equal true, report.fetch(:combined_inside_tolerance)
    assert_equal "2.461", report.fetch(:target_short_eth)
  end

  ReadbackVenue = Struct.new(:short_eth) do
    def read_position(symbol:)
      { short_size: BigDecimal(short_eth.to_s), symbol: symbol }
    end

    def account_state
      { open_orders_count: 0 }
    end
  end
end
