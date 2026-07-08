require "test_helper"

class MigrationManualCanaryGatesTest < ActiveSupport::TestCase
  EXT_AUTO = "EXTENDED_AUTO_REBALANCE_ENABLED".freeze
  ETH_AUTO = "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED".freeze
  NADO_AUTO = "AERODROME_NADO_AUTO_REBALANCE_ENABLED".freeze

  setup do
    @state_path = Rails.root.join("tmp/manual-canary-gate-state-#{SecureRandom.hex(4)}.json")
    MigrationManualCanaryGates.state_path = @state_path
  end

  teardown do
    FileUtils.rm_f(@state_path)
    MigrationManualCanaryGates.state_path = nil
  end

  def enable(key)
    OperationalSettings.set!(key: key, enabled: true, reason: "test precondition")
  end

  def disable(key)
    OperationalSettings.set!(key: key, enabled: false, reason: "test precondition")
  end

  def gate_enabled?(key)
    OperationalSettings.get(key).enabled
  end

  def arm(from, to)
    MigrationManualCanaryGates.new(from: from, to: to).arm!(confirmation: MigrationManualCanaryGates::ARM_CONFIRMATION)
  end

  def paused_keys(armed)
    armed[:paused_autos].select { |p| p[:paused] }.map { |p| p[:key] }
  end

  # --- DB gate selection ---

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
    assert_includes gates.env_only_gate_keys, "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED"
  end

  test "arm! refuses without the exact confirmation and changes nothing" do
    result = MigrationManualCanaryGates.new(from: "extended", to: "nado").arm!(confirmation: "nope")

    assert_equal false, result[:ok]
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, gate_enabled?(key), key }
    refute MigrationManualCanaryGates.pending_restore?
  end

  test "arm! enables the route DB gates and disarm! returns every gate to false" do
    armed = arm("extended", "nado")
    assert armed[:ok]
    %w[MIGRATION_LIVE_ENABLED MIGRATION_MANUAL_LIVE_CANARY_ENABLED MIGRATION_FULL_ALLOWED AERODROME_NADO_HEDGE_LIVE_ENABLED AERODROME_NADO_LIVE_MIGRATION_ENABLED].each { |key| assert_equal true, gate_enabled?(key), "#{key} should be armed" }

    disarmed = MigrationManualCanaryGates.disarm!
    assert disarmed[:ok]
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, gate_enabled?(key), "#{key} should be disarmed" }
  end

  # --- source/target auto pause & restore ---

  test "target venue auto enabled is paused on arm and restored on disarm" do
    disable(EXT_AUTO)
    enable(ETH_AUTO)

    armed = arm("extended", "ethereal")

    assert_equal [ ETH_AUTO ], paused_keys(armed)
    assert_equal false, gate_enabled?(ETH_AUTO), "target auto should be paused"
    assert MigrationManualCanaryGates.pending_restore?

    MigrationManualCanaryGates.disarm!

    assert_equal true, gate_enabled?(ETH_AUTO), "target auto should be restored"
    refute MigrationManualCanaryGates.pending_restore?
  end

  test "source and target autos both enabled are both paused and both restored" do
    enable(EXT_AUTO)
    enable(ETH_AUTO)

    armed = arm("extended", "ethereal")

    assert_equal [ EXT_AUTO, ETH_AUTO ].sort, paused_keys(armed).sort
    assert_equal false, gate_enabled?(EXT_AUTO)
    assert_equal false, gate_enabled?(ETH_AUTO)

    MigrationManualCanaryGates.disarm!

    assert_equal true, gate_enabled?(EXT_AUTO)
    assert_equal true, gate_enabled?(ETH_AUTO)
  end

  test "source false, target true pauses and restores only the target auto" do
    disable(EXT_AUTO)
    enable(ETH_AUTO)

    armed = arm("extended", "ethereal")

    assert_equal [ ETH_AUTO ], paused_keys(armed)
    MigrationManualCanaryGates.disarm!
    assert_equal false, gate_enabled?(EXT_AUTO), "source auto was already off and must stay off"
    assert_equal true, gate_enabled?(ETH_AUTO), "target auto restored"
  end

  test "target false, source true pauses and restores only the source auto" do
    enable(EXT_AUTO)
    disable(ETH_AUTO)

    armed = arm("extended", "ethereal")

    assert_equal [ EXT_AUTO ], paused_keys(armed)
    MigrationManualCanaryGates.disarm!
    assert_equal true, gate_enabled?(EXT_AUTO), "source auto restored"
    assert_equal false, gate_enabled?(ETH_AUTO), "target auto was already off and must stay off"
  end

  test "arm never modifies an unrelated venue auto" do
    enable(EXT_AUTO)
    enable(ETH_AUTO)
    enable(NADO_AUTO) # nado is not part of extended->ethereal

    arm("extended", "ethereal")
    assert_equal true, gate_enabled?(NADO_AUTO), "unrelated nado auto must be untouched by arm"

    MigrationManualCanaryGates.disarm!
    assert_equal true, gate_enabled?(NADO_AUTO), "unrelated nado auto must be untouched by disarm"
  end

  test "disarm! is idempotent" do
    enable(ETH_AUTO)
    arm("extended", "ethereal")

    first = MigrationManualCanaryGates.disarm!
    second = MigrationManualCanaryGates.disarm!

    assert first[:ok]
    assert second[:ok]
    assert_empty second[:restored_autos]
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, gate_enabled?(key), key }
    assert_equal true, gate_enabled?(ETH_AUTO)
  end

  test "failure path: disarm disables gates AND restores both autos after a canary that never ran" do
    enable(EXT_AUTO)
    enable(ETH_AUTO)
    arm("extended", "ethereal")

    # Simulate the canary failing / never submitting — operator disarms anyway.
    MigrationManualCanaryGates.disarm!

    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, gate_enabled?(key), key }
    assert_equal true, gate_enabled?(EXT_AUTO), "source auto restored after failure"
    assert_equal true, gate_enabled?(ETH_AUTO), "target auto restored after failure"
  end

  test "status reports both source_auto and target_auto sections" do
    enable(ETH_AUTO)
    status = MigrationManualCanaryGates.new(from: "extended", to: "ethereal").status

    assert_equal "extended", status.dig(:source_auto, :venue)
    assert_equal EXT_AUTO, status.dig(:source_auto, :key)
    assert_equal false, status.dig(:source_auto, :would_pause)

    assert_equal "ethereal", status.dig(:target_auto, :venue)
    assert_equal ETH_AUTO, status.dig(:target_auto, :key)
    assert_equal true, status.dig(:target_auto, :currently_enabled)
    assert_equal true, status.dig(:target_auto, :would_pause)
  end

  test "disarm tolerates a stale/corrupt state file as a fail-closed no-op" do
    enable(ETH_AUTO)
    File.write(@state_path, "{ not valid json")

    refute MigrationManualCanaryGates.pending_restore?
    result = MigrationManualCanaryGates.disarm!

    assert result[:ok]
    assert_empty result[:restored_autos]
    assert_equal true, gate_enabled?(ETH_AUTO), "a corrupt record must never mutate a venue auto"
    MigrationManualCanaryGates::ALL_DB_GATES.each { |key| assert_equal false, gate_enabled?(key), key }
  end

  test "disarm ignores an unrecognized (legacy-shaped) state record without touching autos" do
    enable(ETH_AUTO)
    # Legacy flat record shape (no "paused_autos" map) must be a no-op, not a crash.
    File.write(@state_path, JSON.generate("key" => ETH_AUTO, "previous_value" => "true"))

    refute MigrationManualCanaryGates.pending_restore?
    result = MigrationManualCanaryGates.disarm!

    assert result[:ok]
    assert_empty result[:restored_autos]
    assert_equal true, gate_enabled?(ETH_AUTO)
  end
end
