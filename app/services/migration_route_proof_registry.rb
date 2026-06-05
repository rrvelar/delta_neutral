class MigrationRouteProofRegistry
  ROUTES = MigrationLiveRouteCapability::ROUTES
  STATUSES = {
    not_started: "NOT_STARTED",
    dry_run: "DRY_RUN_PROVEN",
    live: "LIVE_CANARY_PROVEN",
    recovery: "RECOVERY_PROVEN",
    ready: "READY_FOR_RANDOM",
    stale: "STALE",
    failed: "FAILED_NEEDS_REPAIR"
  }.freeze

  def initialize(route_proof_dir: HedgeVenueMigrationRouteMatrix::PROOF_RECEIPT_DIR, canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR, recovery_dir: MigrationTargetFirstSourceRecovery::RECEIPT_DIR, continuation_dir: MigrationTargetNadoContinuation::RECEIPT_DIR, random_dir: Rails.root.join("storage/hedge_migration_random_rehearsals"), now: -> { Time.current }, source_commit: nil, stale_after: 30.days)
    @route_proof_dir = Pathname(route_proof_dir)
    @canary_dir = Pathname(canary_dir)
    @recovery_dirs = Array(recovery_dir).map { |dir| Pathname(dir) }
    @continuation_dir = Pathname(continuation_dir)
    @random_dir = Pathname(random_dir)
    @now = now
    @source_commit = source_commit || current_commit
    @stale_after = stale_after
  end

  def report(position:)
    routes = ROUTES.map { |from, to| route_status(position: position, from: from, to: to) }
    {
      action: "migration_route_proofs",
      position_id: position.id,
      source_commit: source_commit,
      routes: routes,
      completed_route_proofs: routes.select { |route| route[:status] == STATUSES[:ready] },
      missing_route_proofs: routes.reject { |route| route[:status] == STATUSES[:ready] },
      stale_route_proofs: routes.select { |route| route[:status] == STATUSES[:stale] },
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def route_status(position:, from:, to:)
    route = "#{from}->#{to}"
    dry = latest_event(position: position, from: from, to: to, dirs: [ route_proof_dir, random_dir ]) do |event|
      dry_run_proof?(event)
    end
    live = latest_event(position: position, from: from, to: to, dirs: [ canary_dir ]) do |event|
      live_canary_proof?(event)
    end
    continuation = latest_event(position: position, from: from, to: to, dirs: [ continuation_dir ]) do |event|
      continuation_proof?(event)
    end
    recovery = latest_event(position: position, from: from, to: to, dirs: recovery_dirs) do |event|
      recovery_proof?(event)
    end
    failed = latest_event(position: position, from: from, to: to, dirs: [ route_proof_dir, canary_dir, continuation_dir, *recovery_dirs, random_dir ]) do |event|
      failed_proof?(event)
    end
    latest = [ dry, live, continuation, recovery, failed ].compact.max_by { |event| event_time(event) || Time.zone.at(0) }
    status = status_for(dry: dry, live: live, continuation: continuation, recovery: recovery, failed: failed, latest: latest)
    proof_event = proof_event_for(status: status, dry: dry, live: live, continuation: continuation, recovery: recovery, failed: failed, latest: latest)

    {
      route: route,
      from_venue: from,
      to_venue: to,
      status: status,
      dry_run_receipt: receipt_ref(dry),
      live_canary_receipt: receipt_ref(live),
      continuation_receipt: receipt_ref(continuation),
      recovery_receipt: receipt_ref(recovery),
      finalization_receipt: receipt_ref(proof_event),
      proof_timestamp: proof_event&.fetch("timestamp", nil),
      source_commit: proof_event&.fetch("source_commit", nil) || proof_event&.fetch("commit_sha", nil),
      final_venue: final_venue_for(event: proof_event, status: status, to: to),
      final_readback_summary: final_readback_summary(proof_event),
      orders_submitted: proof_event&.fetch("orders_submitted", 0).to_i,
      orders_placed: proof_event&.fetch("orders_placed", 0).to_i,
      signatures_created: proof_event&.fetch("signatures_created", 0).to_i,
      manual_intervention: manual_intervention?(proof_event),
      blockers: blockers_for(status, route)
    }
  end

  def resolved_nado_target_continuation?(position:, pending_event:)
    return false unless pending_event["to_venue"] == "nado"

    from = pending_event["from_venue"]
    to = pending_event["to_venue"]
    route = route_status(position: position, from: from, to: to)
    return false unless route[:status] == STATUSES[:ready] && route[:continuation_receipt].present?

    continuation_events(position: position, from: from, to: to).any? do |event|
      continuation_proof?(event) && continuation_matches_pending?(continuation: event, pending: pending_event)
    end
  end

  def canary_receipt_dir
    canary_dir
  end

  private

  attr_reader :route_proof_dir, :canary_dir, :recovery_dirs, :continuation_dir, :random_dir, :now, :source_commit, :stale_after

  def status_for(dry:, live:, continuation:, recovery:, failed:, latest:)
    return STATUSES[:not_started] unless latest

    if continuation && !manual_intervention?(continuation) && later_than?(continuation, recovery) && later_than?(continuation, live)
      return stale?(continuation) ? STATUSES[:stale] : STATUSES[:ready]
    end

    if live && !manual_intervention?(live) && later_than?(live, recovery)
      return stale?(live) ? STATUSES[:stale] : STATUSES[:ready]
    end

    return stale?(recovery) ? STATUSES[:stale] : STATUSES[:recovery] if recovery

    if failed && event_time(failed) == event_time(latest)
      return stale?(failed) ? STATUSES[:stale] : STATUSES[:failed]
    end

    return stale?(live) ? STATUSES[:stale] : STATUSES[:ready] if live && !manual_intervention?(live)
    return STATUSES[:live] if live
    return stale?(dry) ? STATUSES[:stale] : STATUSES[:dry_run] if dry

    STATUSES[:not_started]
  end

  def proof_event_for(status:, dry:, live:, continuation:, recovery:, failed:, latest:)
    case status
    when STATUSES[:ready], STATUSES[:live]
      [ continuation, live ].compact.max_by { |event| event_time(event) || Time.zone.at(0) }
    when STATUSES[:recovery]
      recovery
    when STATUSES[:dry_run]
      dry
    when STATUSES[:failed]
      failed
    else
      latest
    end
  end

  def latest_event(position:, from:, to:, dirs:, &block)
    events(dirs)
      .select { |event| event["position_id"].to_s == position.id.to_s && event["from_venue"] == from && event["to_venue"] == to }
      .select(&block)
      .max_by { |event| event_time(event) || Time.zone.at(0) }
  end

  def events(dirs)
    dirs.flat_map do |dir|
      Dir.glob(Pathname(dir).join("*.jsonl")).flat_map do |path|
        File.readlines(path).filter_map do |line|
          JSON.parse(line).merge("receipt_path" => path)
        rescue JSON::ParserError
          nil
        end
      end
    rescue SystemCallError
      []
    end
  end

  def continuation_events(position:, from:, to:)
    events([ continuation_dir ])
      .select { |event| event["position_id"].to_s == position.id.to_s && event["from_venue"] == from && event["to_venue"] == to }
  end

  def continuation_matches_pending?(continuation:, pending:)
    continuation_id = continuation["pending_migration_id"].presence
    pending_id = pending["pending_migration_id"].presence
    return true if continuation_id && pending_id && continuation_id == pending_id

    continuation_digest = continuation["nado_target_digest"].presence || continuation["nado_target_exchange_order_id"].presence
    pending_digest = pending["nado_target_digest"].presence || Array(pending["exchange_order_ids"]).first.presence
    return true if continuation_digest && pending_digest && continuation_digest == pending_digest

    continuation["from_venue"] == pending["from_venue"] &&
      continuation["to_venue"] == pending["to_venue"] &&
      continuation_digest.present? &&
      Array(pending["exchange_order_ids"]).map(&:to_s).include?(continuation_digest.to_s)
  end

  def dry_run_proof?(event)
    event["action"].to_s.in?(%w[migration_route_proof random_migration_rehearsal]) &&
      (event["route_status"] == "READY_FOR_DRY_RUN" || event["final_status"].to_s.in?(%w[dry_run READY_FOR_TARGET_FIRST]))
  end

  def live_canary_proof?(event)
    clean_live_final_status?(event["final_status"]) &&
      event["target_leg_readback_confirmed"] == true &&
      event["source_leg_readback_confirmed"] == true &&
      event["final_inside_tolerance"] == true &&
      event["source_flat_after"] == true &&
      event["target_holds_expected_short"] == true &&
      event["open_orders_after"].to_i.zero?
  end

  def clean_live_final_status?(status)
    status.to_s.in?([
      MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      "MIGRATION_FINALIZED",
      "MIGRATION_CONFIRMED_LATE",
      "ALREADY_MIGRATED_CONFIRMED_BY_READBACK",
      "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      MigrationRouteCompletionReconciler::FINALIZED_STATUS
    ])
  end

  def recovery_proof?(event)
    event["action"] == "recover_target_first_source_close" &&
      event["final_status"].to_s.in?(%w[MIGRATION_FINALIZED ALREADY_FINALIZED SOURCE_ALREADY_FLAT_READY_TO_FINALIZE SOURCE_CLOSE_RECOVERY_CONFIRMED]) &&
      event["target_confirmed"] == true &&
      (event["source_already_flat"] == true || event["source_close_confirmed"] == true || event["readback_confirmed"] == true) &&
      event["other_venues_flat"] == true &&
      event["final_inside_tolerance"] == true &&
      event["production_venue_finalized"] == true &&
      !manual_exchange_intervention?(event)
  end

  def continuation_proof?(event)
    event["action"] == "continue_target_first_after_nado_confirmed" &&
      event["final_status"].to_s.in?(%w[MIGRATION_FINALIZED SOURCE_CLOSE_RECOVERY_CONFIRMED]) &&
      event["continuation_of_accepted_nado_target"] == true &&
      event["nado_target_digest"].present? &&
      event["target_confirmed"] == true &&
      (event["source_close_confirmed"] == true || event["source_already_flat"] == true) &&
      event["final_inside_tolerance"] == true &&
      event["production_venue_finalized"] == true &&
      !manual_exchange_intervention?(event)
  end

  def failed_proof?(event)
    return false if recovery_proof?(event)
    return false if continuation_proof?(event)

    event["final_status"].to_s.match?(/FAILED|BLOCKED|MANUAL_ACTION/i) ||
      event["manual_action_required"] == true
  end

  def later_than?(event, other)
    return true unless other

    event_time_value = event_time(event)
    other_time_value = event_time(other)
    return true unless event_time_value && other_time_value

    event_time_value >= other_time_value
  end

  def stale?(event)
    time = event_time(event)
    return true if time && time < now.call - stale_after

    event_commit = event["source_commit"] || event["commit_sha"]
    event_commit.present? && source_commit.present? && !source_commit.start_with?(event_commit.to_s) && !event_commit.to_s.start_with?(source_commit)
  end

  def manual_intervention?(event)
    return false unless event
    return false if recovery_proof?(event)

    event["manual_action_required"] == true ||
      event["final_status"].to_s.match?(/MANUAL_ACTION|PARTIAL/i) ||
      event["message"].to_s.match?(/manual close|manual action/i)
  end

  def manual_exchange_intervention?(event)
    event["manual_exchange_intervention"] == true ||
      event["manual_trade_performed"] == true ||
      event["manual_user_exchange_intervention"] == true ||
      event["message"].to_s.match?(/manual exchange trade|manually traded/i)
  end

  def blockers_for(status, route)
    case status
    when STATUSES[:ready] then []
    when STATUSES[:not_started] then [ "#{route} route proof has not started." ]
    when STATUSES[:dry_run] then [ "#{route} supervised live canary is required." ]
    when STATUSES[:recovery] then [ "#{route} recovery-proven; optional clean rerun required for READY_FOR_RANDOM." ]
    when STATUSES[:stale] then [ "#{route} proof is stale and must be repeated." ]
    when STATUSES[:failed] then [ "#{route} latest proof failed and needs repair." ]
    else [ "#{route} is not READY_FOR_RANDOM." ]
    end
  end

  def receipt_ref(event)
    return nil unless event

    event["receipt_path"]
  end

  def final_venue_for(event:, status:, to:)
    return nil unless event
    return to if status.in?([ STATUSES[:ready], STATUSES[:live] ]) && live_canary_proof?(event)

    event["final_venue"] || event["production_venue"] || event["to_venue"]
  end

  def final_readback_summary(event)
    return nil unless event

    {
      source_flat_after: event["source_flat_after"],
      target_holds_expected_short: event["target_holds_expected_short"],
      final_inside_tolerance: event["final_inside_tolerance"],
      production_venue_finalized: event["production_venue_finalized"]
    }.compact
  end

  def event_time(event)
    Time.zone.parse(event["timestamp"].to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def current_commit
    `git -C #{Rails.root} rev-parse --short HEAD 2>/dev/null`.strip.presence
  end
end
