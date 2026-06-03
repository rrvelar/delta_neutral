require "test_helper"
require "setup_defaults"

class SetupDefaultsTest < ActiveSupport::TestCase
  test "installer defaults to supported hedge venue and active first import behavior" do
    report = SetupDefaults.new(env: { "DEFAULT_HEDGE_EXECUTION_VENUE" => "hyperliquid" }).report

    assert_equal %w[nado ethereal extended], report.fetch(:supported_hedge_venues)
    assert_equal "nado", report.fetch(:default_hedge_execution_venue)
    assert report.fetch(:risk_cap_settings).any? { |row| row.fetch(:key) == "ETHEREAL_MAX_SHORT_ETH" }
    assert_equal false, report.fetch(:restart_required_for_ui_risk_changes)
    assert_equal true, report.fetch(:first_import_active_by_default)
    assert_match "updates the existing position", report.fetch(:duplicate_import_behavior)
    assert_includes report.fetch(:operator_notes), "Dashboard shows active positions only."
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end
end
