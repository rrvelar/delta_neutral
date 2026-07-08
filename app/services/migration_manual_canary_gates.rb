# Safe, auditable arming of the DB-backed OperationalSettings gates required for
# ONE supervised manual live canary, plus a fail-closed disarm.
#
# Why this exists: the migration live gates are OperationalSettings and are
# resolved DB-first (see OperationalSettings.get), so a DB row set to "false"
# authoritatively overrides any inline process ENV. Passing `env GATE=true` to a
# one-off rake command therefore has NO effect on these gates. To run a
# supervised canary you must temporarily set the DB gates, then disarm them.
#
# In addition, the canary refuses to migrate when EITHER the source or the target
# venue auto-rebalance could fire mid-migration. So arm also PAUSES both the
# source (from) and target (to) venue auto-rebalance gates that are enabled
# (recording each prior value), and disarm RESTORES every paused gate to its
# exact prior value. Prior values are persisted to a small state file so arm and
# disarm — which run as separate processes — agree on what to restore.
#
# This service NEVER runs a canary and NEVER submits orders/signatures. Callers
# (rake tasks) must arm, run exactly one canary, then always disarm — including
# after a failure — so gates are never left enabled and every paused auto gate is
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

    # Where the paused-auto records are persisted between arm and disarm.
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

  def status
    {
      route: "#{from}->#{to}",
      recommended_sequence: route_policy.route_strategy(from: from, to: to),
      db_gates: db_gate_keys.map { |key| gate_value(key) },
      env_only_gates: env_only_gate_keys.map { |key| { key: key, source: "process ENV (pass inline on the canary command)", enabled: OperationalSettings.enabled?(key, env: env) } },
      source_auto: auto_status(role: "source", venue: from),
      target_auto: auto_status(role: "target", venue: to)
    }
  end

  # Arm the DB gates for one canary and pause the source AND target venue auto
  # gates. Returns before/after snapshots. Fail-closed: requires the exact
  # confirmation phrase; sets nothing otherwise.
  def arm!(confirmation:)
    return refusal("confirmation must equal #{ARM_CONFIRMATION}") unless confirmation.to_s == ARM_CONFIRMATION

    before = ALL_DB_GATES.map { |key| gate_value(key) }
    db_gate_keys.each do |key|
      OperationalSettings.set!(key: key, enabled: true, reason: "arm one manual canary #{from}->#{to}")
    end
    paused = pause_venue_autos!
    {
      ok: true, action: "arm_manual_canary_gates", route: "#{from}->#{to}",
      armed_db_gates: db_gate_keys, env_only_gates_to_pass_inline: env_only_gate_keys,
      paused_autos: paused,
      before: before, after: ALL_DB_GATES.map { |key| gate_value(key) },
      reminder: "Run exactly one canary, then always run disarm — including after failure. Disarm restores every paused source/target auto gate."
    }
  end

  # Disarm every manual-canary DB gate back to false AND restore every paused auto
  # gate (source and target) to its exact prior value. Always safe and idempotent:
  # no confirmation needed (only disables live gates / restores autos), and an
  # absent/empty state file is a no-op.
  def self.disarm!
    before = ALL_DB_GATES.map { |key| gate_value_for(key) }
    ALL_DB_GATES.each do |key|
      OperationalSettings.set!(key: key, enabled: false, reason: "disarm manual canary gates")
    end
    restored = restore_venue_autos!
    {
      ok: true, action: "disarm_manual_canary_gates",
      disarmed_db_gates: ALL_DB_GATES, restored_autos: restored,
      before: before, after: ALL_DB_GATES.map { |key| gate_value_for(key) }
    }
  end

  # --- source/target auto pause/restore ---

  # Pause both the source and target venue auto gates that are currently enabled.
  # Only enabled gates are paused/recorded; unrelated venue autos are untouched.
  def pause_venue_autos!
    auto_targets.map { |role, venue, key| pause_auto!(role: role, venue: venue, key: key) }
  end

  def pause_auto!(role:, venue:, key:)
    return { paused: false, role: role, venue: venue, key: nil, reason: "#{venue} has no auto-rebalance gate" } unless key

    current = OperationalSettings.get(key)
    unless current.enabled == true
      # Already off (never on, or already paused by an earlier un-disarmed arm).
      # Do NOT overwrite an existing record — the original prior value must survive.
      return { paused: false, role: role, venue: venue, key: key, current_value: current.raw_value, note: "auto already disabled" }
    end

    unless self.class.paused_auto_record(key)
      self.class.upsert_paused_auto(
        key: key,
        record: { "previous_value" => current.raw_value, "venue" => venue, "role" => role, "paused_at" => Time.current.utc.iso8601 },
        route: "#{from}->#{to}"
      )
    end
    OperationalSettings.set!(key: key, enabled: false, reason: "pause #{role} auto for manual canary #{from}->#{to}")
    { paused: true, role: role, venue: venue, key: key, previous_value: current.raw_value }
  end

  def self.restore_venue_autos!
    restored = paused_autos.map do |key, record|
      OperationalSettings.set!(key: key, enabled: record["previous_value"], reason: "restore #{record['role']} auto after manual canary")
      { key: key, role: record["role"], venue: record["venue"], restored_value: record["previous_value"] }
    end
    clear_pause_record
    restored
  end

  def auto_status(role:, venue:)
    key = OperationalSettings.auto_key_for(venue)
    restore_pending = self.class.pending_restore?
    return { role: role, venue: venue, key: nil, would_pause: false, restore_pending: restore_pending } unless key

    current = OperationalSettings.get(key)
    record = self.class.paused_auto_record(key)
    {
      role: role, venue: venue, key: key,
      current_value: current.raw_value,
      currently_enabled: current.enabled,
      would_pause: current.enabled == true,
      previous_value: record && record["previous_value"],
      restore_pending: restore_pending
    }
  end

  # --- persistence of the paused-auto records ---

  def self.pause_record
    return nil unless File.exist?(state_path)

    JSON.parse(File.read(state_path))
  rescue JSON::ParserError, SystemCallError
    nil
  end

  # Map of gate key => { previous_value, venue, role, paused_at }.
  def self.paused_autos
    record = pause_record
    return {} unless record.is_a?(Hash)

    autos = record["paused_autos"]
    autos.is_a?(Hash) ? autos : {}
  end

  def self.paused_auto_record(key)
    paused_autos[key]
  end

  def self.upsert_paused_auto(key:, record:, route:)
    current = pause_record
    current = {} unless current.is_a?(Hash)
    current["route"] ||= route
    current["paused_autos"] ||= {}
    current["paused_autos"][key] = record
    write_pause_record(current)
  end

  def self.write_pause_record(hash)
    FileUtils.mkdir_p(File.dirname(state_path))
    File.write(state_path, JSON.generate(hash))
  end

  def self.clear_pause_record
    FileUtils.rm_f(state_path)
  end

  def self.pending_restore?(record = pause_record)
    return false unless record.is_a?(Hash)

    autos = record["paused_autos"]
    autos.is_a?(Hash) && autos.any?
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

  # [ [role, venue, key], ... ] for the source and target venue autos, deduped by
  # key and skipping venues without an auto gate.
  def auto_targets
    [ [ "source", from, OperationalSettings.auto_key_for(from) ],
      [ "target", to, OperationalSettings.auto_key_for(to) ] ]
      .select { |_role, _venue, key| key.present? }
      .uniq { |_role, _venue, key| key }
  end

  def gate_value(key)
    self.class.gate_value_for(key)
  end

  def refusal(message)
    { ok: false, action: "arm_manual_canary_gates", errors: [ message ] }
  end
end
