require "test_helper"

class MigrationLiveCanaryCheckerTest < ActiveSupport::TestCase
  test "valid confirmed canary receipt is recognized" do
    dir = Rails.root.join("tmp/test-live-canaries-#{SecureRandom.hex(4)}")
    writer = HedgeVenueMigrationReceiptWriter.new(receipt_dir: dir)
    writer.write(valid_canary_receipt)

    checker = MigrationLiveCanaryChecker.new(receipt_dir: dir)

    assert_equal true, checker.confirmed?(from: "extended", to: "ethereal")
    assert_equal true, checker.status_for(from: "extended", to: "ethereal").fetch(:live_canary_confirmed)
  end

  test "missing canary receipt is not confirmed" do
    checker = MigrationLiveCanaryChecker.new(receipt_dir: Rails.root.join("tmp/test-live-canaries-#{SecureRandom.hex(4)}"))
    status = checker.status_for(from: "extended", to: "ethereal")

    assert_equal false, status.fetch(:live_canary_confirmed)
    assert_includes status.fetch(:blockers), "LIVE_CANARY_CONFIRMED receipt is required for extended->ethereal."
    assert_equal 0, status.fetch(:orders_submitted)
    assert_equal 0, status.fetch(:signatures_created)
  end

  private

  def valid_canary_receipt
    {
      action: "manual_live_canary",
      timestamp: Time.current.utc.iso8601,
      from_venue: "extended",
      to_venue: "ethereal",
      mode: "full",
      final_status: MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      target_leg_readback_confirmed: true,
      source_leg_readback_confirmed: true,
      final_inside_tolerance: true,
      source_flat_after: true,
      target_holds_expected_short: true,
      open_orders_after: 0,
      orders_submitted: 2,
      signatures_created: 2
    }
  end
end
