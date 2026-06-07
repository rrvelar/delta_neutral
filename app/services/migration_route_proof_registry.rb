class MigrationRouteProofRegistry
  ROUTES = MigrationLiveRouteCapability::ROUTES
  STATUSES = {
    not_started: "NOT_STARTED",
    dry_run: "DRY_RUN_PROVEN",
    live: "LIVE_CANARY_PROVEN",
    recovery: "RECOVERY_PROVEN",
    ready: "READY_FOR_RANDOM",
    not_safe_latency: "NOT_PRODUCTION_SAFE_LATENCY",
    stale: "STALE",
    failed: "FAILED_NEEDS_REPAIR"
  }.freeze

  def initialize(route_proof_dir: HedgeVenueMigrationRouteMatrix::PROOF_RECEIPT_DIR, canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR, recovery_dir: MigrationTargetFirstSourceRecovery::RECEIPT_DIR, continuation_dir: MigrationTargetNadoContinuation::RECEIPT_DIR, random_dir: Rails.root.join("storage/hedge_migration_random_rehearsals"), latency_proof_dir: Rails.root.join("storage/hedge_migration_route_latency_proofs"), now: -> { Time.current }, source_commit: nil, stale_after: 30.days, env: ENV, route_policy: nil)
    @route_proof_dir = Pathname(route_proof_dir)
    @canary_dir = Pathname(canary_dir)
    @recovery_dirs = Array(recovery_dir).map { |dir| Pathname(dir) }
    @continuation_dir = Pathname(continuation_dir)
    @random_dir = Pathname(random_dir)
    @latency_proof_dir = Pathname(latency_proof_dir)
    @now = now
    @source_commit = source_commit || current_commit
    @stale_after = stale_after
    @env = env
    @route_policy = route_policy || MigrationRouteOperationalPolicy.new(env: env)
  end

  def report(position:)
    routes = ROUTES.map { |from, to| route_status(position: position, from: from, to: to) }
    route_policy_health = route_policy.report.fetch(:route_policy_health)
    {
      action: "migration_route_proofs",
      position_id: position.id,
      source_commit: source_commit,
      route_policy_health: route_policy_health,
      route_policy_blocker: route_policy_health == "all_disabled" ? "Route policies are disabled. Use migration:route_policy_restore_defaults." : nil,
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
    latency = latest_event(position: position, from: from, to: to, dirs: [ latency_proof_dir ]) do |event|
      route_latency_proof?(event)
    end
    recovery = latest_event(position: position, from: from, to: to, dirs: recovery_dirs) do |event|
      recovery_proof?(event)
    end
    failed = latest_event(position: position, from: from, to: to, dirs: [ route_proof_dir, canary_dir, continuation_dir, latency_proof_dir, *recovery_dirs, random_dir ]) do |event|
      failed_proof?(event)
    end
    latest = [ dry, live, continuation, latency, recovery, failed ].compact.max_by { |event| event_time(event) || Time.zone.at(0) }
    status = status_for(dry: dry, live: live, continuation: continuation, latency: latency, recovery: recovery, failed: failed, latest: latest)
    proof_event = proof_event_for(status: status, dry: dry, live: live, continuation: continuation, latency: latency, recovery: recovery, failed: failed, latest: latest)
    route_policy_status = route_policy.route_status(from: from, to: to)
    if status == STATUSES[:ready] && !route_policy_status.fetch(:enabled)
      status = STATUSES[:not_safe_latency]
    end

    {
      route: route,
      from_venue: from,
      to_venue: to,
      status: status,
      dry_run_receipt: receipt_ref(dry),
      live_canary_receipt: receipt_ref(live),
      continuation_receipt: receipt_ref(continuation),
      latency_proof_receipt: receipt_ref(latency),
      recovery_receipt: receipt_ref(recovery),
      finalization_receipt: receipt_ref(proof_event),
      proof_timestamp: proof_event&.fetch("timestamp", nil),
      source_commit: proof_event&.fetch("source_commit", nil) || proof_event&.fetch("commit_sha", nil),
      final_venue: final_venue_for(event: proof_event, status: status, to: to),
      final_readback_summary: final_readback_summary(proof_event),
      route_enabled: route_policy_status.fetch(:enabled),
      route_disabled_reason: route_policy_status[:disabled_reason],
      route_policy_key: route_policy_status[:key],
      route_strategy_key: route_policy_status[:strategy_key],
      route_strategy: route_policy_status[:strategy],
      migration_sequence: route_policy_status[:migration_sequence],
      route_production_safe: production_safe_latency?(proof_event),
      latency_proof_status: latency_proof_status(proof_event),
      target_confirmation_source: proof_event&.fetch("target_confirmation_source", nil),
      source_flat_to_execution_confirmed_seconds: proof_event&.fetch("source_flat_to_execution_confirmed_seconds", nil),
      double_exposure_seconds: proof_event&.fetch("double_exposure_seconds", nil),
      underhedge_seconds: proof_event&.fetch("underhedge_seconds", nil),
      total_route_seconds: proof_event&.fetch("total_route_seconds", nil) || proof_event&.fetch("total_migration_latency_seconds", nil),
      orders_submitted: proof_event&.fetch("orders_submitted", 0).to_i,
      orders_placed: proof_event&.fetch("orders_placed", 0).to_i,
      signatures_created: proof_event&.fetch("signatures_created", 0).to_i,
      manual_intervention: manual_intervention?(proof_event),
      blockers: blockers_for(status, route, route_policy_status: route_policy_status, proof_event: proof_event)
    }
  end

  def resolved_nado_target_continuation?(position:, pending_event:)
    return false unless pending_event["to_venue"] == "nado"

    from = pending_event["from_venue"]
    to = pending_event["to_venue"]
    route = route_status(position: position, from: from, to: to)
    return false unless route[:status].in?([ STATUSES[:ready], STATUSES[:not_safe_latency] ])
    return true if finalized_route_readback?(route, to: to)

    continuation_events(position: position, from: from, to: to).any? do |event|
      continuation_finalized_route?(event) && continuation_matches_pending?(continuation: event, pending: pending_event)
    end
  end

  def canary_receipt_dir
    canary_dir
  end

  private

  attr_reader :route_proof_dir, :canary_dir, :recovery_dirs, :continuation_dir, :random_dir, :latency_proof_dir, :now, :source_commit, :stale_after, :env, :route_policy

  def status_for(dry:, live:, continuation:, latency:, recovery:, failed:, latest:)
    return STATUSES[:not_started] unless latest

    if continuation && !manual_intervention?(continuation) && production_safe_latency?(continuation) && later_than?(continuation, recovery) && later_than?(continuation, live) && later_than?(continuation, latency) && later_than?(continuation, failed)
      return stale?(continuation) ? STATUSES[:stale] : STATUSES[:ready]
    end

    if latency && !manual_intervention?(latency) && production_safe_latency?(latency) && later_than?(latency, recovery) && later_than?(latency, live) && later_than?(latency, continuation) && later_than?(latency, failed)
      return stale?(latency) ? STATUSES[:stale] : STATUSES[:ready]
    end

    if live && !manual_intervention?(live) && production_safe_latency?(live) && later_than?(live, recovery) && later_than?(live, latency) && later_than?(live, failed)
      return stale?(live) ? STATUSES[:stale] : STATUSES[:ready]
    end

    return stale?(latest) ? STATUSES[:stale] : STATUSES[:not_safe_latency] if latest && latency_unsafe?(latest)
    return stale?(recovery) ? STATUSES[:stale] : STATUSES[:ready] if recovery && recovery_ready_for_random?(recovery)
    return stale?(recovery) ? STATUSES[:stale] : STATUSES[:recovery] if recovery

    if failed && event_time(failed) == event_time(latest)
      return stale?(failed) ? STATUSES[:stale] : STATUSES[:not_safe_latency] if latency_unsafe?(failed)

      return stale?(failed) ? STATUSES[:stale] : STATUSES[:failed]
    end

    return stale?(live) ? STATUSES[:stale] : STATUSES[:ready] if live && !manual_intervention?(live) && production_safe_latency?(live)
    return STATUSES[:live] if live
    return stale?(dry) ? STATUSES[:stale] : STATUSES[:dry_run] if dry

    STATUSES[:not_started]
  end

  def proof_event_for(status:, dry:, live:, continuation:, latency:, recovery:, failed:, latest:)
    case status
    when STATUSES[:ready], STATUSES[:live]
      [ continuation, latency, live, recovery ].compact.max_by { |event| event_time(event) || Time.zone.at(0) }
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

  def finalized_route_readback?(route, to:)
    summary = route[:final_readback_summary] || {}
    return false unless route[:final_venue] == to
    return false unless summary[:production_venue_finalized] == true
    return false unless summary[:final_inside_tolerance] == true

    source_flat = summary[:source_flat_after] == true || summary[:source_already_flat] == true || summary[:source_close_confirmed] == true
    target_confirmed = summary[:target_holds_expected_short] == true || summary[:target_confirmed] == true
    venue_flat = summary[:other_venues_flat] != false && summary[:third_venue_flat] != false
    open_orders_clear = summary[:open_orders_clear_after] != false
    source_flat && target_confirmed && venue_flat && open_orders_clear
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
      event["open_orders_after"].to_i.zero? &&
      production_safe_latency?(event)
  end

  def route_latency_proof?(event)
    return false unless truthy?(event["route_latency_proof"])
    return false if manual_intervention?(event)

    if source_first_nado_target_latency_proof?(event)
      return source_first_nado_target_finalized_safely?(event) && production_safe_latency?(event)
    end

    clean_live_final_status?(event["final_status"]) &&
      finalized_target_first_event?(event) &&
      production_safe_latency?(event)
  end

  def source_first_nado_target_latency_proof?(event)
    event["to_venue"].to_s == "nado" &&
      (event["migration_sequence"].to_s == "source_first" || event["strategy"].to_s == "source_first")
  end

  def source_first_nado_target_finalized_safely?(event)
    clean_live_final_status?(event["final_status"]) &&
      truthy?(event["production_venue_finalized"]) &&
      truthy?(event["route_complete_by_readback"]) &&
      truthy?(event["final_inside_tolerance"]) &&
      (truthy?(event["source_flat_after"]) || truthy?(event["source_close_confirmed"]) || truthy?(event["source_already_flat"])) &&
      (truthy?(event["target_holds_expected_short"]) || truthy?(event["target_confirmed"])) &&
      (event["third_venue_flat"] != false && event["other_venues_flat"] != false) &&
      (event["open_orders_clear"] != false && event["open_orders_clear_after"] != false && event["open_orders_after"].to_i.zero?)
  end

  def clean_live_final_status?(status)
    status.to_s.in?([
      MigrationLiveCanaryChecker::CONFIRMED_STATUS,
      "MIGRATION_FINALIZED",
      "MIGRATION_CONFIRMED_LATE",
      "SOURCE_FIRST_FINALIZED_BY_LATE_NADO_READBACK",
      "SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK",
      "ALREADY_MIGRATED_CONFIRMED_BY_READBACK",
      "STALE_ACTION_IGNORED_ROUTE_ALREADY_COMPLETE",
      MigrationRouteCompletionReconciler::FINALIZED_STATUS
    ])
  end

  def recovery_proof?(event)
    event["action"] == "recover_target_first_source_close" &&
      event["final_status"].to_s.in?(%w[MIGRATION_FINALIZED ALREADY_FINALIZED SOURCE_ALREADY_FLAT_READY_TO_FINALIZE SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK SOURCE_CLOSE_RECOVERY_CONFIRMED]) &&
      event["target_confirmed"] == true &&
      (event["source_already_flat"] == true || event["source_close_confirmed"] == true || event["readback_confirmed"] == true) &&
      event["other_venues_flat"] == true &&
      event["final_inside_tolerance"] == true &&
      event["production_venue_finalized"] == true &&
      !manual_exchange_intervention?(event) &&
      production_safe_latency?(event)
  end

  def recovery_ready_for_random?(event)
    recovery_proof?(event) &&
      event["production_venue_finalized"] == true &&
      (event["final_venue"].blank? || event["final_venue"] == event["to_venue"] || event["production_venue"] == event["to_venue"]) &&
      !manual_intervention?(event)
  end

  def continuation_proof?(event)
    event["action"] == "continue_target_first_after_nado_confirmed" &&
      continuation_finalized_route?(event) &&
      !manual_exchange_intervention?(event) &&
      production_safe_latency?(event)
  end

  def continuation_finalized_route?(event)
    event["action"] == "continue_target_first_after_nado_confirmed" &&
      event["final_status"].to_s.in?(%w[MIGRATION_FINALIZED SOURCE_CLOSE_RECOVERY_CONFIRMED]) &&
      event["continuation_of_accepted_nado_target"] == true &&
      event["nado_target_digest"].present? &&
      event["target_confirmed"] == true &&
      (event["source_close_confirmed"] == true || event["source_already_flat"] == true) &&
      event["final_inside_tolerance"] == true &&
      event["production_venue_finalized"] == true
  end

  def failed_proof?(event)
    return false if recovery_proof?(event)
    return false if continuation_proof?(event)

    latency_unsafe?(event) ||
      event["final_status"].to_s.match?(/FAILED|BLOCKED|MANUAL_ACTION/i) ||
      event["manual_action_required"] == true
  end

  def production_safe_latency?(event)
    !latency_unsafe?(event)
  end

  def latency_unsafe?(event)
    return false unless event
    return true if event["final_status"].to_s == STATUSES[:not_safe_latency]
    return true if event["latency_incident"] == true
    return true if explicit_route_production_safe?(event) == false

    return true if nado_target_without_latency_proof?(event)
    return true if latency_value_exceeds?(event["double_exposure_seconds"], max_double_exposure_seconds)
    return true if latency_value_exceeds?(source_first_underhedge_latency(event), max_unhedged_seconds)
    return false if source_first_event?(event)

    return true if latency_value_exceeds?(event["total_route_seconds"] || event["total_migration_latency_seconds"], max_total_route_seconds)

    false
  rescue ArgumentError, TypeError
    false
  end

  def nado_target_without_latency_proof?(event)
    event["to_venue"].to_s == "nado" &&
      finalized_latency_proof_required_event?(event) &&
      event["double_exposure_seconds"].blank? &&
      event["underhedge_seconds"].blank? &&
      event["route_latency_proof"] != true &&
      event["production_safe_route"] != true &&
      event["route_production_safe"] != true
  end

  def finalized_latency_proof_required_event?(event)
    status = event["final_status"].to_s
    clean_live_final_status?(status) ||
      status.in?(%w[MIGRATION_FINALIZED SOURCE_CLOSE_RECOVERY_CONFIRMED SOURCE_ALREADY_FLAT_FINALIZED_BY_READBACK])
  end

  def latency_value_exceeds?(value, threshold)
    value.present? && BigDecimal(value.to_s) > threshold
  end

  def source_first_event?(event)
    event["migration_sequence"].to_s == "source_first"
  end

  def source_first_underhedge_latency(event)
    return event["underhedge_seconds"] unless source_first_event?(event)
    if source_first_nado_execution_proof_usable?(event)
      return event["source_flat_to_execution_confirmed_seconds"]
    end

    event["source_flat_to_target_confirmed_seconds"].presence ||
      event["underhedge_seconds"].presence ||
      event["source_flat_to_finalized_seconds"]
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def source_first_nado_execution_proof_usable?(event)
    source = event["target_confirmation_source"].to_s
    source_first_nado_target_latency_proof?(event) &&
      source.in?(%w[archive_order gateway_order fill trade digest]) &&
      truthy?(event["route_complete_by_readback"]) &&
      event["source_flat_to_execution_confirmed_seconds"].present?
  end

  def explicit_route_production_safe?(event)
    return truthy?(event["route_production_safe"]) unless event["route_production_safe"].nil?
    return truthy?(event["production_safe_route"]) unless event["production_safe_route"].nil?
    return truthy?(event["production_safe"]) unless event["production_safe"].nil?

    nil
  end

  def latency_proof_status(event)
    return nil unless event

    event["latency_proof_status"] || (production_safe_latency?(event) ? "passed" : "failed_latency_threshold")
  end

  def max_double_exposure_seconds
    BigDecimal(env.fetch("MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS", "5").to_s)
  rescue ArgumentError
    BigDecimal("5")
  end

  def max_unhedged_seconds
    BigDecimal(env.fetch("MIGRATION_MAX_UNHEDGED_SECONDS", "10").to_s)
  rescue ArgumentError
    BigDecimal("10")
  end

  def max_total_route_seconds
    BigDecimal(env.fetch("MIGRATION_MAX_TOTAL_ROUTE_SECONDS", "30").to_s)
  rescue ArgumentError
    BigDecimal("30")
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

  def blockers_for(status, route, route_policy_status:, proof_event:)
    return [ route_policy_status.fetch(:blocker) ] if status == STATUSES[:not_safe_latency] && !route_policy_status.fetch(:enabled)

    case status
    when STATUSES[:ready] then []
    when STATUSES[:not_safe_latency]
      [ "#{route} temporarily disabled pending latency fix/proof#{latency_detail(proof_event)}." ]
    when STATUSES[:not_started] then [ "#{route} route proof has not started." ]
    when STATUSES[:dry_run] then [ "#{route} supervised live canary is required." ]
    when STATUSES[:recovery] then [ "#{route} recovery-proven; optional clean rerun required for READY_FOR_RANDOM." ]
    when STATUSES[:stale] then [ "#{route} proof is stale and must be repeated." ]
    when STATUSES[:failed] then [ "#{route} latest proof failed and needs repair." ]
    else [ "#{route} is not READY_FOR_RANDOM." ]
    end
  end

  def latency_detail(event)
    seconds = event&.fetch("double_exposure_seconds", nil)
    return "" if seconds.blank?

    " (double_exposure_seconds=#{seconds}, max=#{max_double_exposure_seconds.to_s('F')})"
  end

  def receipt_ref(event)
    return nil unless event

    event["receipt_path"]
  end

  def final_venue_for(event:, status:, to:)
    return nil unless event
    return to if status.in?([ STATUSES[:ready], STATUSES[:live] ]) && live_canary_proof?(event)
    return to if status == STATUSES[:not_safe_latency] && finalized_target_first_event?(event)

    event["final_venue"] || event["production_venue"] || event["to_venue"]
  end

  def finalized_target_first_event?(event)
    event["source_flat_after"] == true &&
      event["target_holds_expected_short"] == true &&
      event["final_inside_tolerance"] == true
  end

  def final_readback_summary(event)
    return nil unless event

    {
      source_flat_after: event["source_flat_after"],
      target_holds_expected_short: event["target_holds_expected_short"],
      source_already_flat: event["source_already_flat"],
      source_close_confirmed: event["source_close_confirmed"],
      target_confirmed: event["target_confirmed"],
      other_venues_flat: event["other_venues_flat"],
      third_venue_flat: event["third_venue_flat"],
      open_orders_clear_after: event["open_orders_clear_after"],
      final_inside_tolerance: event["final_inside_tolerance"],
      production_venue_finalized: event["production_venue_finalized"],
      double_exposure_started_at: event["double_exposure_started_at"],
      double_exposure_ended_at: event["double_exposure_ended_at"],
      double_exposure_seconds: event["double_exposure_seconds"],
      underhedge_started_at: event["underhedge_started_at"],
      underhedge_ended_at: event["underhedge_ended_at"],
      underhedge_seconds: event["underhedge_seconds"],
      total_route_seconds: event["total_route_seconds"] || event["total_migration_latency_seconds"],
      source_close_order_submitted_at: event["source_close_order_submitted_at"],
      source_close_exchange_latency_seconds: event["source_close_exchange_latency_seconds"],
      source_close_readback_latency_seconds: event["source_close_readback_latency_seconds"],
      latency_incident: event["latency_incident"]
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
