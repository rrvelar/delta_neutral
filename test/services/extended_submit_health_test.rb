require "test_helper"

class ExtendedSubmitHealthTest < ActiveSupport::TestCase
  setup do
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-submit-health-unit-#{SecureRandom.hex(4)}.json")
  end

  teardown do
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-extended-submit-health-default.json")
  end

  test "no file means not recently failed" do
    assert_equal false, ExtendedSubmitHealth.recently_failed?
    assert_equal({}, ExtendedSubmitHealth.snapshot)
  end

  test "failure is recent inside the window and counts consecutively" do
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503", http_status: 503)
    ExtendedSubmitHealth.record_failure!(error: "Net::ReadTimeout")

    assert_equal true, ExtendedSubmitHealth.recently_failed?
    assert_equal 2, ExtendedSubmitHealth.snapshot["consecutive_failures"]
    assert_equal "Net::ReadTimeout", ExtendedSubmitHealth.snapshot["last_error"]
  end

  test "failure outside the window is not recent" do
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503", http_status: 503, now: 25.hours.ago)

    assert_equal false, ExtendedSubmitHealth.recently_failed?
    assert_equal true, ExtendedSubmitHealth.recently_failed?(window_seconds: 48 * 3600)
  end

  test "a success after the failure clears recency, a success before it does not" do
    ExtendedSubmitHealth.record_success!(now: 2.hours.ago)
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503", http_status: 503, now: 1.hour.ago)
    assert_equal true, ExtendedSubmitHealth.recently_failed?

    ExtendedSubmitHealth.record_success!
    assert_equal false, ExtendedSubmitHealth.recently_failed?
  end

  test "a corrupt health file fails closed to not-recently-failed and never raises" do
    FileUtils.mkdir_p(File.dirname(ExtendedSubmitHealth.path))
    File.write(ExtendedSubmitHealth.path, "not json {")

    assert_equal false, ExtendedSubmitHealth.recently_failed?
    assert_equal({}, ExtendedSubmitHealth.snapshot)
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503")
    assert_equal true, ExtendedSubmitHealth.recently_failed?
  end
end
