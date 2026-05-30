class MigrationTargetFirstSourceRecovery
  CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_EXTENDED_SOURCE_AFTER_TARGET_CONFIRMED".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_recoveries")

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(position:, from:, to:, dry_run: nil, live: false, confirmation: nil, env: ENV,
                 extended_venue: nil, ethereal_venue: nil, nado_venue: nil, fresh_target: nil,
                 lifecycle_factory: nil, now: -> { Time.current }, receipt_dir: RECEIPT_DIR)
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @dry_run = dry_run.nil? ? !@live : ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmation = confirmation.to_s
    @env = env
    @extended_venue = extended_venue || HedgeVenues::Extended.new(env: env)
    @ethereal_venue = ethereal_venue || HedgeVenues::Ethereal.new(env: env)
    @nado_venue = nado_venue || HedgeVenues::Nado.new(env: env)
    @fresh_target = fresh_target
    @lifecycle_factory = lifecycle_factory
    @now = now
    @receipt_dir = Pathname(receipt_dir)
  end

  def run
    context = build_context
    blockers = safety_blockers(context)
    execution = nil

    if live? && blockers.empty?
      execution = lifecycle(context).run(
        position: position,
        mode: "close_only",
        size_eth: context.fetch(:extended_short),
        confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
        dry_run: false,
        max_slippage: env.fetch("MIGRATION_RECOVERY_MAX_SLIPPAGE", env.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01"))
      )
      context = context.merge(final_extended_short: final_extended_short(execution), execution: execution)
      blockers = Array(execution.blockers) unless recovery_confirmed?(context)
    end

    receipt = receipt_for(context: context, blockers: blockers, execution: execution)
    write_receipt(receipt)
    Result.new(receipt.fetch(:final_status), blockers, receipt.fetch(:warnings), receipt)
  rescue => e
    receipt = failure_receipt(e)
    write_receipt(receipt)
    Result.new(receipt.fetch(:final_status), receipt.fetch(:blockers), receipt.fetch(:warnings), receipt)
  end

  private

  attr_reader :position, :from, :to, :confirmation, :env, :extended_venue, :ethereal_venue, :nado_venue, :now, :receipt_dir

  def live?
    @live && !@dry_run
  end

  def build_context
    target = fresh_target_report
    extended_position = extended_venue.read_position(symbol: "ETH")
    ethereal_position = ethereal_venue.read_position(symbol: "ETH")
    nado_position = nado_venue.read_position(symbol: "ETH")
    extended_short = short_size(extended_position)
    ethereal_short = short_size(ethereal_position)
    nado_short = short_size(nado_position)
    target_short = decimal_or_nil(target[:target_short_eth])
    tolerance = target_short && position.hedge ? target_short * BigDecimal(position.hedge.tolerance.to_s) : nil
    tolerance = [ tolerance || BigDecimal("0"), BigDecimal("0.001") ].max if target_short
    combined = extended_short + ethereal_short + nado_short
    expected_final_combined = ethereal_short + nado_short
    preview = extended_short.positive? ? extended_venue.close_preview(symbol: "ETH", size_eth: extended_short) : nil

    {
      action: "recover_target_first_source_close",
      timestamp: now.call.utc.iso8601,
      target_report: target,
      target_short_eth: target_short,
      tolerance_eth: tolerance,
      extended_position: extended_position,
      ethereal_position: ethereal_position,
      nado_position: nado_position,
      extended_short: extended_short,
      ethereal_short: ethereal_short,
      nado_short: nado_short,
      combined_short: combined,
      drift_before: target_short ? target_short - combined : nil,
      expected_final_extended_short: BigDecimal("0"),
      expected_final_combined: expected_final_combined,
      expected_final_inside_tolerance: target_short && tolerance ? (target_short - expected_final_combined).abs <= tolerance : nil,
      preview: preview,
      extended_account_state: nil,
      ethereal_account_state: nil
    }
  end

  def safety_blockers(context)
    blockers = []
    blockers << "from must be extended" unless from == "extended"
    blockers << "to must be ethereal" unless to == "ethereal"
    blockers << "position must be active" unless position.active?
    blockers << "active hedge is required" unless position.hedge&.active?
    blockers << "production venue must still be extended for source-close recovery" unless HedgeVenues.normalize(position.hedge&.execution_venue) == "extended"
    blockers.concat(Array(context.dig(:target_report, :blockers)))
    blockers << "fresh Mellow target is required before source-close recovery" unless context.dig(:target_report, :status) == "ok"
    blockers << "Extended source short must be present" unless context.fetch(:extended_short).positive?
    blockers << "Ethereal target short must be present" unless context.fetch(:ethereal_short).positive?
    blockers << "Nado must be flat before source-close recovery" unless context.fetch(:nado_short).zero?
    blockers << "Ethereal short must be within tolerance of fresh target" unless ethereal_target_confirmed?(context)
    blockers << "combined short must be overhedged before source-close recovery" unless combined_overhedged?(context)
    blockers.concat(preview_blockers(context))
    blockers.concat(open_order_blockers(context))
    blockers.concat(live_gate_blockers(context)) if live?
    blockers.uniq
  end

  def preview_blockers(context)
    preview = context.fetch(:preview)
    return [ "Extended close preview unavailable" ] unless preview

    payload = preview.fetch(:payload, {})
    blockers = []
    blockers << "recovery order must be buy" unless payload[:side].to_s == "buy"
    blockers << "recovery order must be reduce-only" unless payload[:reduce_only] == true
    blockers.concat(Array(payload[:validation_blockers]))
    blockers
  end

  def open_order_blockers(context)
    blockers = []
    extended_state = extended_venue.account_state
    context[:extended_account_state] = extended_state
    blockers << "Extended open_orders_count must be 0 for source-close recovery" unless extended_state[:open_orders_count].to_i.zero?

    ethereal_state = ethereal_venue.account_state
    context[:ethereal_account_state] = ethereal_state
    count = ethereal_state[:open_orders_count]
    blockers << "Ethereal open_orders_count must be 0 for source-close recovery" if !count.nil? && count.to_i.nonzero?
    blockers
  end

  def live_gate_blockers(_context)
    blockers = []
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true" unless bool_env("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED") && extended_venue.live_enabled?
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" unless bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    blockers
  end

  def lifecycle(context)
    lifecycle_env = env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => context.fetch(:extended_short).to_s("F"))
    if @lifecycle_factory
      @lifecycle_factory.call(lifecycle_env, extended_venue)
    else
      ExtendedMainnetLifecycleCheck.new(env: lifecycle_env, venue: extended_venue)
    end
  end

  def recovery_confirmed?(context)
    execution = context.fetch(:execution)
    return false unless execution.status == "success"

    final_extended = context.fetch(:final_extended_short)
    final_combined = final_extended + context.fetch(:ethereal_short) + context.fetch(:nado_short)
    final_extended <= BigDecimal("0.001") &&
      ethereal_target_confirmed?(context) &&
      context.fetch(:nado_short).zero? &&
      inside_tolerance?(final_combined, context)
  end

  def final_extended_short(execution)
    attempts = Array(execution.receipt[:readback_attempts])
    confirmed = attempts.reverse.find { |attempt| attempt[:confirmed] || attempt["confirmed"] }
    decimal_or_nil(confirmed&.fetch(:short_size, nil)) || short_size(extended_venue.read_position(symbol: "ETH"))
  end

  def receipt_for(context:, blockers:, execution:)
    final_extended = context[:final_extended_short] || context.fetch(:extended_short)
    final_combined = final_extended + context.fetch(:ethereal_short) + context.fetch(:nado_short)
    {
      action: "recover_target_first_source_close",
      timestamp: context.fetch(:timestamp),
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      dry_run: !live?,
      live: live?,
      production_venue: position.hedge&.execution_venue,
      target_source: context.dig(:target_report, :target_source),
      exposure_source: context.dig(:target_report, :exposure_source),
      exposure_refreshed_at: context.dig(:target_report, :exposure_refreshed_at),
      fresh_target_status: context.dig(:target_report, :status),
      target_short_eth: decimal_string(context.fetch(:target_short_eth)),
      tolerance_eth: decimal_string(context.fetch(:tolerance_eth)),
      current_extended_short_eth: decimal_string(context.fetch(:extended_short)),
      current_ethereal_short_eth: decimal_string(context.fetch(:ethereal_short)),
      current_nado_short_eth: decimal_string(context.fetch(:nado_short)),
      combined_short_eth: decimal_string(context.fetch(:combined_short)),
      drift_before: decimal_string(context.fetch(:drift_before)),
      planned_venue: "extended",
      planned_side: "buy",
      reduce_only: true,
      size_eth: decimal_string(context.fetch(:extended_short)),
      target_after_extended_short: "0",
      expected_final_combined: decimal_string(context.fetch(:expected_final_combined)),
      expected_inside_tolerance: context.fetch(:expected_final_inside_tolerance),
      extended_open_orders_count: context.dig(:extended_account_state, :open_orders_count),
      ethereal_open_orders_count: context.dig(:ethereal_account_state, :open_orders_count),
      live_gates: live_gates,
      preview_payload: context.dig(:preview, :payload)&.slice(:action, :side, :extended_side, :reduce_only, :requested_size_eth, :rounded_size_eth, :estimated_notional_usd, :validation_blockers),
      execution_receipt: sanitize_sensitive(execution&.receipt),
      submitted_order_id: execution&.receipt&.fetch(:exchange_order_id, nil),
      orders_submitted: execution&.receipt&.fetch(:orders_placed, 0).to_i,
      orders_placed: execution&.receipt&.fetch(:orders_placed, 0).to_i,
      signatures_created: execution&.receipt&.fetch(:signatures_created, 0).to_i,
      final_extended_short_eth: decimal_string(final_extended),
      final_combined_short_eth: decimal_string(final_combined),
      final_inside_tolerance: inside_tolerance?(final_combined, context),
      readback_confirmed: execution ? recovery_confirmed?(context.merge(final_extended_short: final_extended, execution: execution)) : false,
      final_status: final_status(blockers: blockers, execution: execution, final_combined: final_combined, context: context),
      blockers: blockers,
      warnings: [ "Recovery only closes the Extended source short after Ethereal target readback is already confirmed. It does not open Ethereal, close Ethereal, touch Nado, or change production venue." ],
      receipt_path: receipt_path.to_s
    }
  end

  def final_status(blockers:, execution:, final_combined:, context:)
    return live? ? "SOURCE_CLOSE_RECOVERY_BLOCKED" : "dry_run" if blockers.any?
    return "dry_run" unless live?

    execution&.status == "success" && inside_tolerance?(final_combined, context) ? "SOURCE_CLOSE_RECOVERY_CONFIRMED" : "SOURCE_CLOSE_RECOVERY_MANUAL_ACTION_REQUIRED"
  end

  def live_gates
    {
      exact_confirmation: confirmation == CONFIRMATION,
      migration_target_first_source_recovery_enabled: bool_env("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED"),
      extended_live_enabled: bool_env("EXTENDED_LIVE_ENABLED") && extended_venue.live_enabled?,
      extended_mainnet_probe_enabled: bool_env("EXTENDED_MAINNET_PROBE_ENABLED"),
      extended_auto_disabled: !bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_disabled: !bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_disabled: !bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    }
  end

  def fresh_target_report
    @fresh_target_report ||= (@fresh_target || HedgeFreshTarget.new(position: position, env: env)).resolve(refresh_if_stale: true)
  end

  def ethereal_target_confirmed?(context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    return false unless target && tolerance

    (context.fetch(:ethereal_short) - target).abs <= tolerance
  end

  def combined_overhedged?(context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    return false unless target && tolerance

    context.fetch(:combined_short) - target > tolerance
  end

  def inside_tolerance?(combined, context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    return nil unless target && tolerance

    (target - combined).abs <= tolerance
  end

  def failure_receipt(error)
    {
      action: "recover_target_first_source_close",
      timestamp: now.call.utc.iso8601,
      position_id: position&.id,
      from_venue: from,
      to_venue: to,
      dry_run: !live?,
      live: live?,
      final_status: "SOURCE_CLOSE_RECOVERY_BLOCKED",
      blockers: [ "#{error.class}: #{error.message}" ],
      warnings: [],
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      receipt_path: receipt_path.to_s
    }
  end

  def write_receipt(receipt)
    FileUtils.mkdir_p(receipt_dir)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(sanitize_sensitive(receipt))) }
  end

  def receipt_path
    receipt_dir.join("#{now.call.utc.strftime('%Y%m%d')}.jsonl")
  end

  def short_size(position_payload)
    BigDecimal(position_payload&.fetch(:short_size, 0).to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def decimal_string(value)
    return nil if value.nil?

    BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError, TypeError
    nil
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
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
    text = key.to_s
    return false if text == "signatures_created"

    text.match?(/api[_-]?key|private|authorization|cookie|signature|secret/i)
  end
end
