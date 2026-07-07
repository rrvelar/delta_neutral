require "test_helper"

class MigrationManualCanaryGatesTest < ActiveSupport::TestCase
  setup do
    @state_path = Rails.root.join("tmp/manual-canary-gate-state-#{SecureRandom.hex(4)}.json")
    MigrationManualCanaryGates.state_path = @state_path
  end

  teardown do
    FileUtils.rm_f(@state_path)
    MigrationManualCanaryGates.state_path = nil
  end

  test "extended->nado arms base gates plus nado gates and lists source_first env gate" do
    gates = MigrationManualCanaryGates.new(from: "extended", to: "nado")

    assert_equal %w[MIGRATION_LIVE_ENABLED MIGRATION_MANUAL_LIVE_CANARY_ENABLED MIGRATION_FULL_ALLOWED AERODROME_NADO_HEDGE_LIVE_ENABLED AERODROME_NADO_LIVE_MIGRATION_ENABLED], gates.db_gate_keys
    assert gates.source_first?
    assert_includes gates.env_only_gate_keys, "MIGRATION_SOURCE_FIRST_CANARY_ALLOWED"
    assert_includes gates.env_only_gate_keys, "EXTENDED_LIVE_ENABLED"
  end

  test "extended->ethereal arms only base gates and has no nado or source_first gate" do
    gates = MigrationManualCanaryGates.new(from: "extended", to: "ethereal")

    assert_equal %w[MIGRATION_LIVE_ENABLED MIGRATION_MANUAL_LIVE_CANARY_ENABLED MIGRATION_FULL_ALLOWED], gates.db_gate_keys
    refute gates.source_first?
    refute_includes gates.env_only_gate_keys, "MIGRATION_SOURCE_FIRST_CANARY_ALLOWED"
    assert_includes gates.env_only_gate_keys, "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED"
  end

  test "arm! refuses without the exact confirmation and changes nothing" do
    result = MigrationManualCanaryGates.new(from: "extended", to: "nado").arm!(confirmation: "nope")

    assert_equal false, result[:ok]
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, OperationalSettings.get(key).enabled, key }
    refute MigrationManualCanaryGates.pending_restore?
  end

  test "arm! enables the route DB gates and disarm! returns every gate to false" do
    gates = MigrationManualCanaryGates.new(from: "extended", to: "nado")

    armed = gates.arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)
    assert armed[:ok]
    gates.db_gate_keys.each { |key| assert_equal true, OperationalSettings.get(key).enabled, "#{key} should be armed" }

    disarmed = MigrationManualCanaryGates.disarm!
    assert disarmed[:ok]
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, OperationalSettings.get(key).enabled, "#{key} should be disarmed" }
  end

  test "nado source auto enabled is paused on arm and restored on disarm" do
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test precondition")
    gates = MigrationManualCanaryGates.new(from: "nado", to: "ethereal")

    armed = gates.arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)

    assert_equal true, armed.dig(:paused_source_auto, :paused)
    assert_equal "AERODROME_NADO_AUTO_REBALANCE_ENABLED", armed.dig(:paused_source_auto, :key)
    assert_equal false, OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED").enabled, "source auto should be paused"
    assert MigrationManualCanaryGates.pending_restore?

    disarmed = MigrationManualCanaryGates.disarm!

    assert_equal true, disarmed.dig(:restored_source_auto, :restored)
    assert_equal true, OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED").enabled, "source auto should be restored to its prior value"
    refute MigrationManualCanaryGates.pending_restore?
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, OperationalSettings.get(key).enabled, key }
  end

  test "source auto already disabled is not paused and stays disabled after disarm" do
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: false, reason: "test precondition")
    gates = MigrationManualCanaryGates.new(from: "nado", to: "ethereal")

    armed = gates.arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)
    assert_equal false, armed.dig(:paused_source_auto, :paused)
    refute MigrationManualCanaryGates.pending_restore?

    MigrationManualCanaryGates.disarm!
    assert_equal false, OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED").enabled
  end

  test "disarm! is idempotent and safe with no armed canary" do
    first = MigrationManualCanaryGates.disarm!
    second = MigrationManualCanaryGates.disarm!

    assert first[:ok]
    assert second[:ok]
    assert_equal false, second.dig(:restored_source_auto, :restored)
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, OperationalSettings.get(key).enabled, key }
  end

  test "arm does not modify the target venue auto gate" do
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: true, reason: "source precondition")
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true, reason: "target precondition")

    MigrationManualCanaryGates.new(from: "nado", to: "ethereal").arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)

    assert_equal false, OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED").enabled, "source auto paused"
    assert_equal true, OperationalSettings.get("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED").enabled, "target auto must be untouched"
  end

  test "failure path: disarm still disables gates and restores source auto after a canary that never ran" do
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test precondition")
    MigrationManualCanaryGates.new(from: "nado", to: "ethereal").arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)

    # Simulate the canary failing / never submitting — operator runs disarm anyway.
    MigrationManualCanaryGates.disarm!

    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, OperationalSettings.get(key).enabled, key }
    assert_equal true, OperationalSettings.get("AERODROME_NADO_AUTO_REBALANCE_ENABLED").enabled, "source auto restored even when the canary did not run"
  end

  test "status reports the route policy sequence, per-gate source, and source auto pause state" do
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: true, reason: "test precondition")
    status = MigrationManualCanaryGates.new(from: "nado", to: "ethereal").status

    assert_equal "nado->ethereal", status[:route]
    assert_equal "target_first", status[:recommended_sequence]
    assert(status[:db_gates].all? { |g| g.key?(:enabled) && g.key?(:source) })
    assert_equal "AERODROME_NADO_AUTO_REBALANCE_ENABLED", status.dig(:source_auto, :key)
    assert_equal true, status.dig(:source_auto, :would_pause)
    assert_equal false, status.dig(:source_auto, :restore_pending)
  end
end
