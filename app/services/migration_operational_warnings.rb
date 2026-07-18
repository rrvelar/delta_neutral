# Operational anomaly warnings surfaced in the production runner status file and
# the Production Control Center (2026-07-17 incident follow-ups). Read-only:
# computed from the hedge record, operational settings, the Extended submit
# health file and the latest source-close recovery receipt.
class MigrationOperationalWarnings
  def self.for(position:, env: ENV, recovery_receipt_dir: MigrationTargetFirstSourceRecovery::RECEIPT_DIR)
    new(position: position, env: env, recovery_receipt_dir: recovery_receipt_dir).warnings
  end

  def initialize(position:, env: ENV, recovery_receipt_dir: MigrationTargetFirstSourceRecovery::RECEIPT_DIR)
    @position = position
    @env = env
    @recovery_receipt_dir = Pathname(recovery_receipt_dir)
  end

  def warnings
    warnings = []
    warnings.concat(extended_survivor_warnings)
    warnings.concat(extended_probation_warnings)
    warnings.concat(route_subset_warnings)
    warnings.concat(extended_auto_override_warnings)
    warnings.concat(recovery_mismatch_warnings)
    warnings
  rescue StandardError => e
    [ "operational warnings unavailable: #{e.class}: #{e.message}" ]
  end

  private

  attr_reader :position, :env, :recovery_receipt_dir

  def production_venue
    HedgeVenues.normalize(position.hedge&.execution_venue)
  end

  def extended_survivor_warnings
    return [] unless production_venue == "extended"

    warnings = []
    if ExtendedSubmitHealth.recently_failed?
      state = ExtendedSubmitHealth.snapshot
      warnings << "Extended is the surviving production venue while Extended submit health recently failed (last failure #{state['last_failure_at']}: #{state['last_error']}); reads may work while submits do not — migrate off Extended once submit health recovers."
    end
    if HedgeVenueQuarantine.quarantined?("extended", env: env)
      warnings << "Extended is the surviving production venue while Extended is quarantined; autonomous production cannot open new Extended exposure and the runner will not start until the position migrates off Extended."
    end
    warnings
  end

  def extended_probation_warnings
    warnings = []
    if HedgeVenueQuarantine.state("extended", env: env) == "probation"
      warnings << "Extended is in PROBATION — autonomous production remains blocked; supervised canaries targeting Extended require the explicit per-run gate EXTENDED_PROBATION_CANARY_ALLOWED=true passed inline."
    end
    if HedgeVenueQuarantine.probation_canary_allowed?("extended", env: env)
      warnings << "EXTENDED_PROBATION_CANARY_ALLOWED is set in this process environment — the probation canary gate must only ever be passed inline per-run, never persisted."
    end
    warnings
  end

  def route_subset_warnings
    subset = MigrationApprovedRouteSubset.new(env: env)
    return [] unless subset.active?

    allowed = subset.allowed_routes
    excluded = subset.excluded_routes
    [ "ROUTE SUBSET MODE active: autonomous selection restricted to #{allowed.presence&.join(', ') || '(no valid routes — fail closed)'}; excluded: #{excluded.join(', ')}." ]
  end

  def extended_auto_override_warnings
    value = OperationalSettings.get("EXTENDED_AUTO_REBALANCE_ENABLED", env: env)
    return [] unless value.enabled && value.source == "DB setting"

    [ "EXTENDED_AUTO_REBALANCE_ENABLED is enabled by a DB override (raw #{value.raw_value.inspect}); a dormant auto gate on Extended is a latent double-exposure risk — set it false unless an Extended auto is deliberately active." ]
  end

  def recovery_mismatch_warnings
    receipt = latest_recovery_receipt
    return [] unless receipt
    return [] unless receipt["readback_mismatch"] == true

    [ "Latest source-close recovery receipt (#{receipt['timestamp']}, #{receipt['route']}) reports an inner/outer readback mismatch: the leg claimed the source closed while its readback showed it still live. Trust only fresh authoritative position reads until a clean recovery receipt supersedes it." ]
  end

  def latest_recovery_receipt
    newest = Dir.glob(recovery_receipt_dir.join("*.jsonl")).max
    return nil unless newest

    latest = nil
    File.foreach(newest) do |line|
      entry = JSON.parse(line) rescue next
      latest = entry if entry["position_id"] == position.id
    end
    latest
  end
end
