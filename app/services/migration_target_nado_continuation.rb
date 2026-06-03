require "digest"

class MigrationTargetNadoContinuation
  CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_SOURCE_AFTER_NADO_TARGET_CONFIRMED".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_nado_continuations")

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(position:, from:, to:, dry_run: nil, live: false, confirmation: nil, env: ENV,
                 canary_dir: MigrationManualLiveCanaryRunner::RECEIPT_DIR, receipt_dir: RECEIPT_DIR,
                 recovery_factory: nil, now: -> { Time.current })
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @dry_run = dry_run.nil? ? !@live : ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmation = confirmation.to_s
    @env = env
    @canary_dir = Pathname(canary_dir)
    @receipt_dir = Pathname(receipt_dir)
    @recovery_factory = recovery_factory
    @now = now
  end

  def run
    pending = latest_pending_canary
    recovery = nil
    blockers = base_blockers(pending)
    if blockers.empty?
      recovery = build_recovery(live: live?, confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION).run
      blockers = Array(recovery.blockers)
    end

    status = continuation_status(blockers: blockers, recovery: recovery)
    receipt = receipt_for(pending: pending, recovery: recovery, blockers: blockers, status: status)
    write_receipt(receipt)
    Result.new(status, blockers, receipt.fetch(:warnings), receipt)
  rescue => e
    receipt = failure_receipt(e)
    write_receipt(receipt)
    Result.new(receipt.fetch(:final_status), receipt.fetch(:blockers), receipt.fetch(:warnings), receipt)
  end

  private

  attr_reader :position, :from, :to, :confirmation, :env, :canary_dir, :receipt_dir, :now

  def live?
    @live && !@dry_run
  end

  def latest_pending_canary
    Dir.glob(canary_dir.join("*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map do |line|
        JSON.parse(line).merge("receipt_path" => path)
      rescue JSON::ParserError
        nil
      end
    rescue SystemCallError
      []
    end
      .select { |event| pending_target_nado_canary?(event) }
      .max_by { |event| event_time(event) || Time.zone.at(0) }
  end

  def pending_target_nado_canary?(event)
    event["position_id"].to_s == position.id.to_s &&
      event["from_venue"] == from &&
      event["to_venue"] == to &&
      event["target_leg_status"].to_s == "TARGET_SUBMITTED_PENDING_READBACK" &&
      event["final_status"].to_s.in?(%w[TARGET_ACCEPTED_AWAITING_CONTINUATION TARGET_SUBMITTED_BUT_NOT_CONFIRMED]) &&
      event["exchange_order_ids"].present?
  end

  def base_blockers(pending)
    blockers = []
    blockers << "continuation only supports target=Nado routes" unless to == "nado"
    blockers << "pending accepted Nado target canary receipt is required" unless pending
    blockers << "submitted confirmation must equal #{CONFIRMATION}" if live? && confirmation != CONFIRMATION
    blockers
  end

  def build_recovery(live:, confirmation:)
    if @recovery_factory
      return @recovery_factory.call(position: position, from: from, to: to, dry_run: !live, live: live, confirmation: confirmation)
    end

    MigrationTargetFirstSourceRecovery.new(
      position: position,
      from: from,
      to: to,
      dry_run: !live,
      live: live,
      confirmation: confirmation,
      env: env,
      require_recovery_live_gate: false
    )
  end

  def continuation_status(blockers:, recovery:)
    if recovery&.receipt&.fetch(:target_confirmed, nil) == false
      return "TARGET_STILL_PENDING"
    end
    return "CONTINUATION_BLOCKED" if blockers.any?
    recovery_status = recovery.status.to_s
    receipt = recovery.receipt
    return "READY_TO_CLOSE_SOURCE" if !live? && recovery_status == "dry_run" && receipt[:target_confirmed] == true && receipt[:source_already_flat] == false
    return "TARGET_STILL_PENDING" if receipt[:target_confirmed] == false
    return "MIGRATION_FINALIZED" if recovery_status.in?(%w[SOURCE_CLOSE_RECOVERY_CONFIRMED MIGRATION_FINALIZED ALREADY_FINALIZED SOURCE_ALREADY_FLAT_READY_TO_FINALIZE])

    recovery_status.presence || "CONTINUATION_RECHECK_REQUIRED"
  end

  def receipt_for(pending:, recovery:, blockers:, status:)
    recovery_receipt = recovery&.receipt || {}
    target_digest = pending && (pending["nado_target_digest"].presence || Array(pending["exchange_order_ids"]).first)
    {
      action: "continue_target_first_after_nado_confirmed",
      route: "#{from}->#{to}",
      sequence: "target_first",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      dry_run: !live?,
      live: live?,
      original_live_canary_receipt: pending&.fetch("receipt_path", nil),
      pending_migration_id: pending_migration_id(pending),
      nado_target_digest: target_digest,
      nado_target_exchange_order_id: target_digest,
      target_leg_status: pending&.fetch("target_leg_status", nil),
      source_close_plan: pending&.fetch("planned_source_leg", nil) || pending&.fetch("source_close_preview", nil),
      expected_nado_target_short_eth: pending&.dig("planned_target_leg", "expected_after_short_eth") || pending&.fetch("target_short_eth", nil),
      target_confirmation_evidence: recovery_receipt[:final_state_verification] || recovery_receipt[:target_venue_short_eth],
      recovery_receipt: sanitize_sensitive(recovery_receipt),
      recovery_receipt_path: recovery_receipt[:receipt_path],
      source_leg_submitted: recovery_receipt[:orders_submitted].to_i.positive?,
      source_leg_exchange_order_id: recovery_receipt[:submitted_order_id],
      target_confirmed: recovery_receipt[:target_confirmed],
      source_already_flat: recovery_receipt[:source_already_flat],
      source_close_confirmed: recovery_receipt[:readback_confirmed],
      final_inside_tolerance: recovery_receipt[:final_inside_tolerance],
      production_venue_finalized: recovery_receipt[:production_venue_finalized],
      final_status: status,
      blockers: blockers,
      warnings: warnings(status),
      continuation_command: continuation_command(live: true),
      orders_submitted: recovery_receipt[:orders_submitted].to_i,
      orders_placed: recovery_receipt[:orders_placed].to_i,
      signatures_created: recovery_receipt[:signatures_created].to_i,
      manual_exchange_intervention: false,
      continuation_of_accepted_nado_target: pending.present?
    }
  end

  def failure_receipt(error)
    {
      action: "continue_target_first_after_nado_confirmed",
      timestamp: now.call.utc.iso8601,
      position_id: position&.id,
      from_venue: from,
      to_venue: to,
      dry_run: !live?,
      live: live?,
      final_status: "CONTINUATION_BLOCKED",
      blockers: [ "#{error.class}: #{error.message}" ],
      warnings: [],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  def pending_migration_id(pending)
    return nil unless pending

    Digest::SHA256.hexdigest([ pending["position_id"], pending["from_venue"], pending["to_venue"], Array(pending["exchange_order_ids"]).first ].join(":"))[0, 16]
  end

  def continuation_command(live:)
    mode = live ? "live=true confirmation=#{CONFIRMATION}" : "dry_run=true"
    "bin/rails migration:continue_target_first_after_nado_confirmed position_id=#{position.id} from=#{from} to=#{to} #{mode}"
  end

  def warnings(status)
    base = [ "Continuation closes only the source venue after accepted Nado target readback confirms." ]
    base << "Nado target is still pending; source close was not submitted." if status == "TARGET_STILL_PENDING"
    base
  end

  def write_receipt(receipt)
    FileUtils.mkdir_p(receipt_dir)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(sanitize_sensitive(receipt.merge(receipt_path: receipt_path.to_s)))) }
  end

  def receipt_path
    receipt_dir.join("#{now.call.utc.strftime('%Y%m%d')}.jsonl")
  end

  def event_time(event)
    Time.zone.parse(event["timestamp"].to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = sensitive_key?(key) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end

  def sensitive_key?(key)
    key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature|secret/i)
  end
end
