require "test_helper"

class MigrationOperationalWarningsTest < ActiveSupport::TestCase
  setup do
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-submit-health-#{SecureRandom.hex(4)}.json")
    @receipt_dir = Rails.root.join("tmp/test-warning-recoveries-#{SecureRandom.hex(4)}")
  end

  teardown do
    ExtendedSubmitHealth.path = Rails.root.join("tmp/test-extended-submit-health-default.json")
  end

  test "clean state produces no warnings" do
    position = warnings_position(execution_venue: "nado")

    assert_empty warnings_for(position)
  end

  test "warns when extended is the survivor and extended submit health recently failed" do
    position = warnings_position(execution_venue: "extended")
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503", http_status: 503)

    warnings = warnings_for(position)

    assert warnings.any? { |w| w.include?("submit health recently failed") && w.include?("HTTP 503") }, warnings.inspect
  end

  test "does not warn about submit health when a later submit succeeded" do
    position = warnings_position(execution_venue: "extended")
    ExtendedSubmitHealth.record_failure!(error: "HTTP 503", http_status: 503, now: 2.hours.ago)
    ExtendedSubmitHealth.record_success!(now: 1.hour.ago)

    warnings = warnings_for(position)

    assert warnings.none? { |w| w.include?("submit health recently failed") }, warnings.inspect
  end

  test "warns when extended is the survivor while quarantined" do
    position = warnings_position(execution_venue: "extended")
    OperationalSettings.set!(key: "EXTENDED_VENUE_QUARANTINED", enabled: true, reason: "test")

    warnings = warnings_for(position)

    assert warnings.any? { |w| w.include?("quarantined") }, warnings.inspect
  end

  test "warns when EXTENDED_AUTO_REBALANCE_ENABLED is enabled by a DB override regardless of venue" do
    position = warnings_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test")

    warnings = warnings_for(position)

    assert warnings.any? { |w| w.include?("EXTENDED_AUTO_REBALANCE_ENABLED") && w.include?("DB override") }, warnings.inspect
  end

  test "does not warn when EXTENDED_AUTO_REBALANCE_ENABLED DB row is false" do
    position = warnings_position(execution_venue: "nado")
    OperationalSettings.set!(key: "EXTENDED_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test")

    assert_empty warnings_for(position)
  end

  test "warns when the latest recovery receipt for the position reports a readback mismatch" do
    position = warnings_position(execution_venue: "nado")
    write_recovery_receipt(position_id: position.id, readback_mismatch: true)

    warnings = warnings_for(position)

    assert warnings.any? { |w| w.include?("readback mismatch") }, warnings.inspect
  end

  test "a newer clean recovery receipt supersedes an older mismatch" do
    position = warnings_position(execution_venue: "nado")
    write_recovery_receipt(position_id: position.id, readback_mismatch: true)
    write_recovery_receipt(position_id: position.id, readback_mismatch: false)

    assert_empty warnings_for(position)
  end

  test "another position's mismatch receipt does not warn" do
    position = warnings_position(execution_venue: "nado")
    write_recovery_receipt(position_id: position.id + 999, readback_mismatch: true)

    assert_empty warnings_for(position)
  end

  private

  def warnings_for(position)
    MigrationOperationalWarnings.for(position: position, env: {}, recovery_receipt_dir: @receipt_dir)
  end

  def write_recovery_receipt(position_id:, readback_mismatch:)
    FileUtils.mkdir_p(@receipt_dir)
    File.open(@receipt_dir.join("20260717.jsonl"), "a") do |file|
      file.puts(JSON.generate(
        action: "recover_target_first_source_close",
        route: "extended->ethereal",
        timestamp: Time.current.utc.iso8601,
        position_id: position_id,
        readback_mismatch: readback_mismatch
      ))
    end
  end

  def warnings_position(execution_venue:)
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.61",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: execution_venue)
    position
  end
end
