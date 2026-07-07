# Safe, auditable arming of the DB-backed OperationalSettings gates required for
# ONE supervised manual live canary, plus a fail-closed disarm.
#
# Why this exists: the migration live gates are OperationalSettings and are
# resolved DB-first (see OperationalSettings.get), so a DB row set to "false"
# authoritatively overrides any inline process ENV. Passing `env GATE=true` to a
# one-off rake command therefore has NO effect on these gates. To run a
# supervised canary you must temporarily set the DB gates, then disarm them.
#
# In addition, the canary refuses to migrate out of a venue whose auto-rebalance
# could fire mid-migration. So arm also PAUSES the source venue's auto-rebalance
# gate (recording its prior value), and disarm RESTORES it exactly. The prior
# value is persisted to a small state file so arm and disarm — which run as
# separate processes — agree on what to restore.
#
# This service NEVER runs a canary and NEVER submits orders/signatures. Callers
# (rake tasks) must arm, run exactly one canary, then always disarm — including
# after a failure — so gates are never left enabled and the source auto gate is
# always restored.
class MigrationManualCanaryGates
  ARM_CONFIRMATION = "I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY".freeze

  # DB-backed gates always required for a full supervised canary.
  BASE_DB_GATES = %w[
    MIGRATION_LIVE_ENABLED
    MIGRATION_MANUAL_LIVE_CANARY_ENABLED
    MIGRATION_FULL_ALLOWED
  ].freeze

  # DB-backed gates that only apply when a nado leg is involved.
  NADO_DB_GATES = %w[
    AERODROME_NADO_HEDGE_LIVE_ENABLED
    AERODROME_NADO_LIVE_MIGRATION_ENABLED
  ].freeze

  # Every DB gate this service may ever touch — the disarm surface (fail closed).
  ALL_DB_GATES = (BASE_DB_GATES + NADO_DB_GATES).freeze

  class << self
    attr_writer :state_path

    # Where the paused-source-auto record is persisted between arm and disarm.
    def state_path
      @state_path ||= Rails.root.join("storage/manual_canary_gate_state.json")
    end
  end

  def initialize(from:, to:, env: ENV, route_policy: nil)
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @env = env
    @route_policy = route_policy || MigrationRouteOperationalPolicy.new(env: env)
  end

  # DB-backed gates that must be armed for THIS route.
  def db_gate_keys
    keys = BASE_DB_GATES.dup
    keys.concat(NADO_DB_GATES) if venues.include?("nado")
    keys.uniq
  end

  # Gates the app reads from process ENV only (not OperationalSettings). These are
  # NOT persisted; the operator passes them inline on the canary command and they
  # take effect because no DB row shadows them.
  def env_only_gate_keys
    keys = []
    keys << "EXTENDED_LIVE_ENABLED" << "EXTENDED_MAINNET_PROBE_ENABLED" if venues.include?("extended")
    keys << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" if venues.include?("ethereal")
    keys << "MIGRATION_SOURCE_FIRST_CANARY_ALLOWED" if source_first?
    keys.uniq
  end

  def source_first?
    route_policy.route_strategy(from: from, to: to).to_s == "source_first"
  end

  # The SOURCE venue's auto-rebalance OperationalSettings key (never the target's).
  def source_auto_gate_key
    OperationalSettings.auto_key_for(from)
  end

  def status
    {
      route: "#{from}->#{to}",
      recommended_sequence: route_policy.route_strategy(from: from, to: to),
      db_gates: db_gate_keys.map { |key| gate_value(key) },
      env_only_gates: env_only_gate_keys.map { |key| { key: key, source: "process ENV (pass inline on the canary command)", enabled: OperationalSettings.enabled?(key, env: env) } },
      source_auto: source_auto_status
    }
  end

  # Arm the DB gates for one canary and pause the source auto gate. Returns
  # before/after snapshots. Fail-closed: requires the exact confirmation phrase;
  # sets nothing otherwise.
  def arm!(confirmation:)
    return refusal("confirmation must equal #{ARM_CONFIRMATION}") unless confirmation.to_s == ARM_CONFIRMATION

    before = ALL_DB_GATES.map { |key| gate_value(key) }
    db_gate_keys.each do |key|
      OperationalSettings.set!(key: key, enabled: true, reason: "arm one manual canary #{from}->#{to}")
    end
    paused = pause_source_auto!
    {
      ok: true, action: "arm_manual_canary_gates", route: "#{from}->#{to}",
      armed_db_gates: db_gate_keys, env_only_gates_to_pass_inline: env_only_gate_keys,
      paused_source_auto: paused,
      before: before, after: ALL_DB_GATES.map { |key| gate_value(key) },
      reminder: "Run exactly one canary, then always run disarm — including after failure. Disarm restores the paused source auto gate."
    }
  end

  # Disarm every manual-canary DB gate back to false AND restore any paused source
  # auto gate to its exact prior value. Always safe and idempotent: no confirmation
  # needed (only disables live gates), and a missing/absent pause record is a no-op.
  def self.disarm!
    before = ALL_DB_GATES.map { |key| gate_value_for(key) }
    ALL_DB_GATES.each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "disarm manual canary gates")
    end
    restored = restore_source_auto!
    {
      ok: true, action: "disarm_manual_canary_gates",
      disarmed_db_gates: ALL_DB_GATES, restored_source_auto: restored,
      before: before, after: ALL_DB_GATES.map { |key| gate_value_for(key) }
    }
  end

  # --- source auto pause/restore ---

  def pause_source_auto!
    key = source_auto_gate_key
    return { paused: false, reason: "route source #{from} has no auto-rebalance gate" } unless key

    current = OperationalSettings.get(key)
    unless current.enabled == true
      # Already off (never on, or already paused by an earlier un-disarmed arm).
      # Do NOT overwrite an existing pause record — its prior value must survive.
      return { paused: false, key: key, current_value: current.raw_value, note: "source auto already disabled" }
    end

    self.class.write_pause_record(
      "key" => key, "previous_value" => current.raw_value,
      "route" => "#{from}->#{to}", "paused_at" => Time.current.utc.iso8601
    )
    OperationalSettings.set!(key: key, enabled: false, reason: "pause source auto for manual canary #{from}->#{to}")
    { paused: true, key: key, previous_value: current.raw_value }
  end

  def self.restore_source_auto!
    record = pause_record
    return { restored: false, reason: "no paused source auto to restore" } unless record.is_a?(Hash) && record["key"].present?

    OperationalSettings.set!(key: record["key"], enabled: record["previous_value"], reason: "restore source auto after manual canary #{record['route']}")
    clear_pause_record
    { restored: true, key: record["key"], restored_value: record["previous_value"] }
  end

  def source_auto_status
    key = source_auto_gate_key
    record = self.class.pause_record
    restore_pending = self.class.pending_restore?(record)
    return { key: nil, would_pause: false, restore_pending: restore_pending } unless key

    current = OperationalSettings.get(key)
    {
      key: key,
      current_value: current.raw_value,
      currently_enabled: current.enabled,
      would_pause: current.enabled == true,
      previous_value: (record && record["key"] == key) ? record["previous_value"] : nil,
      restore_pending: restore_pending
    }
  end

  # --- persistence of the paused-auto record ---

  def self.pause_record
    return nil unless File.exist?(state_path)

    JSON.parse(File.read(state_path))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def self.write_pause_record(hash)
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, JSON.generate(hash))
  end

  def self.clear_pause_record
    FileUtils.rm_f(state_path)
  end

  def self.pending_restore?(record = pause_record)
    record.is_a?(Hash) && record["key"].present?
  end

  def self.gate_value_for(key)
    value = OperationalSettings.get(key)
    { key: key, enabled: value.enabled, source: value.source, raw_value: value.raw_value }
  end

  private

  attr_reader :from, :to, :env, :route_policy

  def venues
    [ from, to ]
  end

  def gate_value(key)
    self.class.gate_value_for(key)
  end

  def refusal(message)
    { ok: false, action: "arm_manual_canary_gates", errors: [ message ] }
  end
end
