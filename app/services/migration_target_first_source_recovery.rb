class MigrationTargetFirstSourceRecovery
  CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_SOURCE_AFTER_TARGET_CONFIRMED".freeze
  LEGACY_EXTENDED_ETHEREAL_CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_EXTENDED_SOURCE_AFTER_TARGET_CONFIRMED".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_recoveries")
  VENUES = %w[extended ethereal nado].freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(position:, from:, to:, dry_run: nil, live: false, confirmation: nil, env: ENV,
                 extended_venue: nil, ethereal_venue: nil, nado_venue: nil, fresh_target: nil,
                 lifecycle_factory: nil, leg_runner: nil, now: -> { Time.current }, receipt_dir: RECEIPT_DIR,
                 require_recovery_live_gate: true)
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
    @leg_runner = leg_runner
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @require_recovery_live_gate = require_recovery_live_gate
  end

  def run
    context = build_context
    blockers = safety_blockers(context)
    execution = nil

    if live? && blockers.empty? && context.fetch(:source_short).positive?
      execution = leg_runner.call(context.fetch(:planned_source_close_leg), context: { position: position, confirmation: confirmation, receipt: context })
      context = context.merge(
        final_source_short: decimal_or_nil(execution[:after_short_eth]) || short_size(venue_for(from).read_position(symbol: "ETH")),
        execution: execution
      )
      blockers = Array(execution[:blockers]) unless recovery_confirmed?(context)
    end

    finalize_production_venue(context) if live? && blockers.empty? && finalization_safe?(context)
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
    positions = VENUES.index_with { |venue| venue_for(venue).read_position(symbol: "ETH") }
    shorts = positions.transform_values { |payload| short_size(payload) }
    target_short = decimal_or_nil(target[:target_short_eth])
    tolerance = target_short && position.hedge ? target_short * BigDecimal(position.hedge.tolerance.to_s) : nil
    tolerance = [ tolerance || BigDecimal("0"), BigDecimal("0.001") ].max if target_short
    combined = shorts.values.sum(BigDecimal("0"))
    source_short = shorts.fetch(from)
    target_venue_short = shorts.fetch(to)
    final_source_short = source_short
    expected_final_combined = combined - source_short
    planned_leg = planned_source_close_leg(source_short)

    {
      action: "recover_target_first_source_close",
      timestamp: now.call.utc.iso8601,
      target_report: target,
      target_short_eth: target_short,
      tolerance_eth: tolerance,
      positions: positions,
      shorts: shorts,
      source_short: source_short,
      target_venue_short: target_venue_short,
      other_venue_shorts: other_venue_shorts(shorts),
      combined_short: combined,
      drift_before: target_short ? target_short - combined : nil,
      expected_final_source_short: BigDecimal("0"),
      expected_final_combined: expected_final_combined,
      expected_final_inside_tolerance: target_short && tolerance ? (target_short - expected_final_combined).abs <= tolerance : nil,
      planned_source_close_leg: planned_leg,
      source_close_preview: planned_leg,
      final_source_short: final_source_short,
      account_states: {}
    }
  end

  def safety_blockers(context)
    blockers = []
    blockers << "from venue must be one of #{VENUES.join(', ')}" unless VENUES.include?(from)
    blockers << "to venue must be one of #{VENUES.join(', ')}" unless VENUES.include?(to)
    blockers << "from and to venues must differ" if from == to
    blockers << "position must be active" unless position.active?
    blockers << "active hedge is required" unless position.hedge&.active?
    blockers.concat(production_venue_blockers(context))
    blockers.concat(Array(context.dig(:target_report, :blockers)))
    blockers << "fresh Mellow target is required before source-close recovery" unless context.dig(:target_report, :status) == "ok"
    blockers << "#{HedgeVenues.label(to)} target short must be present" unless context.fetch(:target_venue_short).positive?
    blockers << "#{HedgeVenues.label(to)} short must be within tolerance of fresh target" unless target_confirmed?(context)
    blockers << "unexpected third-venue short is present during source-close recovery" unless other_venues_flat?(context)
    blockers << "combined short must be overhedged before source-close recovery" if context.fetch(:source_short).positive? && !combined_overhedged?(context)
    blockers << "#{HedgeVenues.label(from)} source close preview unavailable" if context.fetch(:source_short).positive? && context.fetch(:planned_source_close_leg).nil?
    blockers.concat(open_order_blockers(context))
    blockers.concat(live_gate_blockers(context)) if live?
    blockers.uniq
  end

  def open_order_blockers(context)
    [ from, to ].flat_map do |venue|
      state = venue_for(venue).account_state
      context.fetch(:account_states)[venue] = state
      count = state[:open_orders_count] || state["open_orders_count"]
      next [] if count.nil? || count.to_i.zero?

      [ "#{HedgeVenues.label(venue)} open_orders_count must be 0 for source-close recovery" ]
    rescue => e
      [ "#{HedgeVenues.label(venue)} open orders readback unavailable for source-close recovery: #{e.class}: #{e.message}" ]
    end
  end

  def live_gate_blockers(context)
    blockers = []
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation_valid?
    if require_recovery_live_gate?
      blockers << "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true" unless bool_env("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED")
    end
    if context.fetch(:source_short).positive?
      blockers << "#{HedgeVenues.label(from)} live gate must be enabled" unless venue_live_enabled?(from)
      blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" if from == "extended" && !bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    end
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be false during source-close recovery" if bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    blockers
  end

  def planned_source_close_leg(source_short)
    return nil unless source_short.positive?

    {
      venue: from,
      action: "close_short",
      side: "buy",
      reduce_only: true,
      size_eth: source_short.to_s("F"),
      expected_after_short_eth: "0",
      recovery_only: true
    }
  end

  def leg_runner
    @leg_runner ||= HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: env)
  end

  def recovery_confirmed?(context)
    execution = context.fetch(:execution)
    return false unless execution[:confirmed] || execution[:status].to_s.in?(%w[success confirmed submitted_and_confirmed])

    finalization_safe?(context)
  end

  def finalization_safe?(context)
    final_state_verification(context).fetch(:status) == "confirmed"
  end

  def finalize_production_venue(context)
    return if context[:production_venue_finalized]
    return unless position.hedge

    position.hedge.update!(execution_venue: to)
    ActiveVenueAutoPolicy.new(position: position).enable_venue!(
      venue: to,
      reason: "source-close recovery finalized production venue"
    )
    context[:production_venue_finalized] = true
    context[:finalized_hedge_id] = position.hedge.id
  end

  def receipt_for(context:, blockers:, execution:)
    final_source = context[:final_source_short] || context.fetch(:source_short)
    final_combined = final_source + context.fetch(:target_venue_short) + context.fetch(:other_venue_shorts).values.sum(BigDecimal("0"))
    source_already_flat = context.fetch(:source_short) <= BigDecimal("0.001")
    safe_to_finalize = finalization_safe?(context)
    {
      action: "recover_target_first_source_close",
      route: "#{from}->#{to}",
      sequence: "target_first",
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
      current_extended_short_eth: decimal_string(context.dig(:shorts, "extended")),
      current_ethereal_short_eth: decimal_string(context.dig(:shorts, "ethereal")),
      current_nado_short_eth: decimal_string(context.dig(:shorts, "nado")),
      source_short_eth: decimal_string(context.fetch(:source_short)),
      target_venue_short_eth: decimal_string(context.fetch(:target_venue_short)),
      combined_short_eth: decimal_string(context.fetch(:combined_short)),
      drift_before: decimal_string(context.fetch(:drift_before)),
      planned_venue: from,
      planned_side: "buy",
      reduce_only: true,
      size_eth: decimal_string(context.fetch(:source_short)),
      target_after_source_short: "0",
      expected_final_combined: decimal_string(context.fetch(:expected_final_combined)),
      expected_inside_tolerance: context.fetch(:expected_final_inside_tolerance),
      source_already_flat: source_already_flat,
      lifecycle_state: lifecycle_state(blockers: blockers, execution: execution, source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize),
      target_confirmed: target_confirmed?(context),
      other_venues_flat: other_venues_flat?(context),
      third_venue_flat: final_state_verification(context).fetch(:third_venue_flat),
      open_orders_clear_after: final_state_verification(context).fetch(:open_orders_clear),
      final_state_verification: final_state_verification(context),
      finalization_recommended: !live? && source_already_flat && safe_to_finalize && HedgeVenues.normalize(position.hedge&.execution_venue) != to,
      finalization_command: "bin/rails migration:recover_target_first_source_close position_id=#{position.id} from=#{from} to=#{to} live=true confirmation=#{CONFIRMATION}",
      live_gates: live_gates,
      planned_source_close_leg: context.fetch(:planned_source_close_leg),
      execution_receipt: sanitize_sensitive(execution&.dig(:receipt)),
      submitted_order_id: execution&.dig(:exchange_order_id),
      orders_submitted: execution&.fetch(:orders_placed, 0).to_i,
      orders_placed: execution&.fetch(:orders_placed, 0).to_i,
      signatures_created: execution&.fetch(:signatures_created, 0).to_i,
      would_execute_live: execution&.fetch(:orders_placed, 0).to_i.positive?,
      final_source_short_eth: decimal_string(final_source),
      final_combined_short_eth: decimal_string(final_combined),
      final_inside_tolerance: inside_tolerance?(final_combined, context),
      readback_confirmed: execution ? recovery_confirmed?(context.merge(final_source_short: final_source, execution: execution)) : source_already_flat && safe_to_finalize,
      production_venue_finalized: context[:production_venue_finalized] == true || already_finalized?(source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize),
      already_finalized: already_finalized?(source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize),
      finalized_hedge_id: context[:finalized_hedge_id],
      final_status: final_status(blockers: blockers, execution: execution, context: context, source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize),
      blockers: blockers,
      warnings: warnings(context, source_already_flat: source_already_flat),
      receipt_path: receipt_path.to_s
    }
  end

  def final_status(blockers:, execution:, context:, source_already_flat:, safe_to_finalize:)
    return live? ? "SOURCE_CLOSE_RECOVERY_BLOCKED" : "dry_run" if blockers.any?
    return "ALREADY_FINALIZED" if already_finalized?(source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize)
    return "SOURCE_ALREADY_FLAT_READY_TO_FINALIZE" if !live? && source_already_flat && safe_to_finalize && HedgeVenues.normalize(position.hedge&.execution_venue) != to
    return "dry_run" unless live?
    return "MIGRATION_FINALIZED" if source_already_flat && safe_to_finalize

    execution && recovery_confirmed?(context.merge(execution: execution)) ? "SOURCE_CLOSE_RECOVERY_CONFIRMED" : "SOURCE_CLOSE_RECOVERY_MANUAL_ACTION_REQUIRED"
  end

  def lifecycle_state(blockers:, execution:, source_already_flat:, safe_to_finalize:)
    return "RECOVERY_BLOCKED" if blockers.any?
    return "MIGRATION_FINALIZED" if already_finalized?(source_already_flat: source_already_flat, safe_to_finalize: safe_to_finalize)
    return "SOURCE_ALREADY_FLAT_READY_TO_FINALIZE" if source_already_flat && safe_to_finalize && !live?
    return "MIGRATION_FINALIZED" if source_already_flat && safe_to_finalize && live?
    return "SOURCE_CLOSE_CONFIRMED" if execution && (execution[:confirmed] || execution[:status].to_s.in?(%w[success confirmed submitted_and_confirmed]))

    live? ? "RECOVERY_REQUIRED" : "READY_FOR_TARGET_FIRST"
  end

  def live_gates
    {
      exact_confirmation: confirmation_valid?,
      migration_target_first_source_recovery_enabled_required: require_recovery_live_gate?,
      migration_target_first_source_recovery_enabled: bool_env("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED"),
      source_live_enabled: venue_live_enabled?(from),
      extended_auto_disabled: !bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_disabled: !bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_disabled: !bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    }
  end

  def warnings(_context, source_already_flat:)
    base = [ "Recovery is target-first only: it never opens more target exposure and never closes the target venue." ]
    if source_already_flat && HedgeVenues.normalize(position.hedge&.execution_venue) == to
      base << "Migration already finalized; no recovery action required."
    elsif source_already_flat
      base << "Source is already flat; no source-close order is needed. Finalize production venue if readbacks remain safe."
    end
    base
  end

  def production_venue_blockers(context)
    production_venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    return [] if production_venue == from || production_venue == to

    [ "production venue must be #{from} or #{to} for source-close recovery; current production venue is #{production_venue || 'unset'}" ]
  end

  def already_finalized?(source_already_flat:, safe_to_finalize:)
    !live? && source_already_flat && safe_to_finalize && HedgeVenues.normalize(position.hedge&.execution_venue) == to
  end

  def fresh_target_report
    @fresh_target_report ||= (@fresh_target || HedgeFreshTarget.new(position: position, env: env)).resolve(refresh_if_stale: true)
  end

  def target_confirmed?(context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    return false unless target && tolerance

    (context.fetch(:target_venue_short) - target).abs <= tolerance
  end

  def other_venue_shorts(shorts)
    shorts.except(from, to)
  end

  def other_venues_flat?(context)
    context.fetch(:other_venue_shorts).values.all? { |short| short <= BigDecimal("0.001") }
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

  def final_state_verification(context)
    final_source = context[:final_source_short] || context.fetch(:source_short)
    final_shorts = context.fetch(:shorts).merge(from => final_source)
    open_order_counts = context.fetch(:account_states, {}).transform_values do |state|
      state[:open_orders_count] || state["open_orders_count"]
    end
    MigrationTargetFirstFinalVerifier.evaluate(
      from: from,
      to: to,
      target_short: context.fetch(:target_short_eth),
      tolerance_eth: context.fetch(:tolerance_eth),
      shorts: final_shorts,
      open_order_counts: open_order_counts,
      readback_source: "recovery_readback"
    )
  end

  def venue_for(venue)
    case venue
    when "extended" then extended_venue
    when "ethereal" then ethereal_venue
    when "nado" then nado_venue
    else raise ArgumentError, "unsupported venue #{venue}"
    end
  end

  def venue_live_enabled?(venue)
    case venue
    when "extended" then bool_env("EXTENDED_LIVE_ENABLED") && extended_venue.live_enabled?
    when "ethereal" then bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    when "nado" then bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED") && bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    else false
    end
  end

  def confirmation_valid?
    return true if confirmation == CONFIRMATION

    from == "extended" && to == "ethereal" && confirmation == LEGACY_EXTENDED_ETHEREAL_CONFIRMATION
  end

  def require_recovery_live_gate?
    @require_recovery_live_gate
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
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

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
