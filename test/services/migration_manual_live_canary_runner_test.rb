require "test_helper"

class MigrationManualLiveCanaryRunnerTest < ActiveSupport::TestCase
  test "run manual live canary blocks without env and exact phrase" do
    result = MigrationManualLiveCanaryRunner.new(receipt_dir: Rails.root.join("tmp/test-canary-runner-#{SecureRandom.hex(4)}")).run(
      position: position,
      from: "extended",
      to: "ethereal",
      confirmation: "wrong"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationManualLiveCanaryRunner::CONFIRMATION}"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  private

  def position
    @position ||= begin
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
        external_id: SecureRandom.hex(4),
        active: true
      )
      position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
      position.create_position_dashboard_snapshot!(
        refreshed_at: Time.current,
        refresh_status: "ok",
        stale: false,
        production_venue: "extended",
        target_short_eth: "1.0",
        combined_short_eth: "1.0",
        drift_eth: "0",
        inside_tolerance: true,
        extended_short_eth: "1.0",
        ethereal_short_eth: "0",
        nado_short_eth: "0"
      )
      position
    end
  end
end
