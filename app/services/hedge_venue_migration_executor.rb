class HedgeVenueMigrationExecutor
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_MIGRATES_HEDGE_BETWEEN_VENUES".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_checks")

  def initialize(env: ENV, planner: HedgeVenueMigrationPlanner.new, leg_runner: nil, now: -> { Time.current })
    @env = env
    @planner = planner
    @leg_runner = leg_runner || FailClosedLegRunner.new
    @now = now
  end

  def run(position:, from_venue:, to_venue:, mode: "preview", dry_run: true, confirmation: nil, step_size_eth: nil, full_migration_allowed: false)
    plan = @planner.plan(
      position: position,
      from_venue: from_venue,
      to_venue: to_venue,
      mode: mode,
      step_size_eth: step_size_eth,
      full_migration_allowed: full_migration_allowed
    )
    receipt = plan.receipt.merge(
      action: "hedge_venue_migration",
      dry_run: dry_run,
      live: !dry_run,
      confirmation_present: confirmation.present?,
      final_status: dry_run ? plan.status : "blocked_before_submit"
    )
    blockers = Array(plan.blockers) + live_blockers(position: position, receipt: receipt, dry_run: dry_run, confirmation: confirmation)
    if dry_run || blockers.any?
      receipt[:blockers] = blockers.uniq
      receipt[:final_status] = dry_run ? "dry_run" : "blocked_before_submit"
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    first_leg = @leg_runner.call(receipt.fetch(:planned_to_leg))
    receipt[:to_leg_execution] = sanitize_sensitive(first_leg)
    unless leg_confirmed?(first_leg)
      receipt[:final_status] = "first_leg_not_confirmed"
      receipt[:blockers] = Array(first_leg[:blockers]).presence || [ "Target venue leg was not confirmed; source leg was not submitted." ]
      write_receipt(receipt)
      return Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
    end

    second_leg = @leg_runner.call(receipt.fetch(:planned_from_leg))
    receipt[:from_leg_execution] = sanitize_sensitive(second_leg)
    receipt[:orders_placed] = leg_order_count(first_leg) + leg_order_count(second_leg)
    receipt[:signatures_created] = leg_signature_count(first_leg) + leg_signature_count(second_leg)
    receipt[:submitted] = receipt[:orders_placed].positive?
    receipt[:final_status] = leg_confirmed?(second_leg) ? "success" : "partial_migration_manual_action_required"
    receipt[:blockers] = Array(second_leg[:blockers]).uniq
    write_receipt(receipt)
    Result.new(receipt[:final_status], receipt[:blockers], Array(receipt[:warnings]), receipt)
  end

  class FailClosedLegRunner
    def call(_leg)
      {
        status: "blocked",
        confirmed: false,
        orders_placed: 0,
        signatures_created: 0,
        blockers: [ "Generic dashboard migration live execution is not implemented for this direction yet." ]
      }
    end
  end

  private

  def live_blockers(position:, receipt:, dry_run:, confirmation:)
    return [] if dry_run

    blockers = []
    blockers << "MIGRATION_LIVE_ENABLED must be true" unless bool_env("MIGRATION_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "Nado must be flat before dashboard migration." unless nado_flat?(position.position_dashboard_snapshot)
    blockers << "target venue readiness failed or is not cached." unless target_readiness_cached?(position.position_dashboard_snapshot, receipt[:to_venue])
    blockers << "source current position must exist." unless decimal(receipt[:from_short_before]).positive?
    blockers << "target/source open orders must be zero." unless open_orders_clear?(position.position_dashboard_snapshot, receipt[:from_venue], receipt[:to_venue])
    blockers
  end

  def target_readiness_cached?(snapshot, venue)
    return false unless snapshot
    return true if venue == "ethereal"
    return false unless venue == "extended"

    snapshot.open_orders_count_extended.to_i.zero? && snapshot.leverage_margin_gate_status.to_s.in?(%w[ok pass passed ready confirmed])
  end

  def open_orders_clear?(snapshot, from, to)
    return false unless snapshot
    return true unless [ from, to ].include?("extended")

    snapshot.open_orders_count_extended.to_i.zero?
  end

  def nado_flat?(snapshot)
    snapshot && BigDecimal(snapshot.nado_short_eth.to_s).zero?
  rescue ArgumentError
    false
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def leg_confirmed?(leg)
    ActiveModel::Type::Boolean.new.cast(leg[:confirmed]) || leg[:status] == "confirmed"
  end

  def leg_order_count(leg)
    leg[:orders_placed].to_i
  end

  def leg_signature_count(leg)
    leg[:signatures_created].to_i
  end

  def write_receipt(receipt)
    FileUtils.mkdir_p(RECEIPT_DIR)
    path = RECEIPT_DIR.join("#{@now.call.utc.strftime('%Y%m%d')}.jsonl")
    File.open(path, "a") { |file| file.puts(JSON.generate(sanitize_sensitive(receipt))) }
  rescue SystemCallError => e
    Rails.logger.warn("Hedge migration receipt write failed: #{e.class}: #{e.message}")
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature|secret/i) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end
end
