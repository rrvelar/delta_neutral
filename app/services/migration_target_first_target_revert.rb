# Reverts a target-first migration that left the target venue live (or possibly
# live) with the source still open. It closes ONLY the target venue reduce-only
# and PRESERVES the source venue as the surviving production leg. This is the
# mirror image of MigrationTargetFirstSourceRecovery (which completes the
# migration by closing the source). It is fail-closed: any ambiguity about
# which leg is intended, an unexpected third-venue short, open orders, or a
# missing/flat source aborts before submitting.
class MigrationTargetFirstTargetRevert
  CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_TARGET_AND_KEEPS_SOURCE".freeze
  LIVE_GATE = "MIGRATION_TARGET_FIRST_TARGET_REVERT_ENABLED".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_target_reverts")
  VENUES = %w[extended ethereal nado].freeze
  FLAT_EPSILON = BigDecimal("0.001")

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(position:, from:, to:, dry_run: nil, live: false, confirmation: nil, env: ENV,
                 extended_venue: nil, ethereal_venue: nil, nado_venue: nil,
                 leg_runner: nil, now: -> { Time.current }, receipt_dir: RECEIPT_DIR,
                 require_revert_live_gate: true)
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
    @leg_runner = leg_runner
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @require_revert_live_gate = require_revert_live_gate
  end

  def run
    context = build_context
    blockers = safety_blockers(context)
    execution = nil

    if live? && blockers.empty? && context.fetch(:target_short).positive?
      execution = leg_runner.call(context.fetch(:planned_target_close_leg), context: { position: position, confirmation: confirmation, receipt: context })
      context = context.merge(
        final_target_short: decimal_or_nil(execution[:after_short_eth]) || short_size(venue_for(to).read_position(symbol: "ETH")),
        execution: execution
      )
      blockers = Array(execution[:blockers]) unless revert_confirmed?(context)
      finalize_source_as_production_venue(context) if blockers.empty? && revert_confirmed?(context)
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

  attr_reader :position, :from, :to, :confirmation, :env, :now, :receipt_dir

  def live?
    @live && !@dry_run
  end

  def build_context
    positions = VENUES.index_with { |venue| venue_for(venue).read_position(symbol: "ETH") }
    shorts = positions.transform_values { |payload| short_size(payload) }
    source_short = shorts.fetch(from)
    target_short = shorts.fetch(to)
    planned_leg = planned_target_close_leg(target_short)

    {
      action: "revert_target_first_target_close",
      timestamp: now.call.utc.iso8601,
      positions: positions,
      shorts: shorts,
      source_short: source_short,
      target_short: target_short,
      other_venue_shorts: shorts.except(from, to),
      planned_target_close_leg: planned_leg,
      final_target_short: target_short,
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
    blockers.concat(production_venue_blockers)
    blockers << "#{HedgeVenues.label(to)} target short must be present to revert" unless context.fetch(:target_short).positive?
    blockers << "#{HedgeVenues.label(from)} source short must be preserved (a revert must keep exactly one live source leg)" unless context.fetch(:source_short) > FLAT_EPSILON
    blockers << "unexpected third-venue short is present during target revert" unless other_venues_flat?(context)
    blockers << "#{HedgeVenues.label(to)} target close preview unavailable" if context.fetch(:target_short).positive? && context.fetch(:planned_target_close_leg).nil?
    blockers.concat(open_order_blockers(context))
    blockers.concat(live_gate_blockers) if live?
    blockers.uniq
  end

  def open_order_blockers(context)
    [ from, to ].flat_map do |venue|
      state = venue_for(venue).account_state
      context.fetch(:account_states)[venue] = state
      count = state[:open_orders_count] || state["open_orders_count"]
      next [] if count.nil? || count.to_i.zero?

      [ "#{HedgeVenues.label(venue)} open_orders_count must be 0 for target revert" ]
    rescue => e
      [ "#{HedgeVenues.label(venue)} open orders readback unavailable for target revert: #{e.class}: #{e.message}" ]
    end
  end

  def live_gate_blockers
    blockers = []
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    if require_revert_live_gate?
      blockers << "#{LIVE_GATE} must be true" unless bool_env(LIVE_GATE)
    end
    blockers << "#{HedgeVenues.label(to)} live gate must be enabled" unless venue_live_enabled?(to)
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" if to == "extended" && !bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be false during target revert" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be false during target revert" if bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    blockers << "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be false during target revert" if bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    blockers
  end

  def production_venue_blockers
    production_venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    return [] if production_venue == from || production_venue == to

    [ "production venue must be #{from} or #{to} for target revert; current production venue is #{production_venue || 'unset'}" ]
  end

  def planned_target_close_leg(target_short)
    return nil unless target_short.positive?

    {
      venue: to,
      action: "close_short",
      side: "buy",
      reduce_only: true,
      size_eth: target_short.to_s("F"),
      expected_after_short_eth: "0",
      recovery_only: true
    }
  end

  def leg_runner
    @leg_runner ||= HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: env)
  end

  def revert_confirmed?(context)
    execution = context[:execution]
    return false unless execution
    return false unless execution[:confirmed] || execution[:status].to_s.in?(%w[success confirmed submitted_and_confirmed])

    final_state_verification(context).fetch(:status) == "confirmed"
  end

  # Success end-state for a revert: target flat, source preserved, third flat,
  # open orders clear. (This is the opposite of the source-close verifier.)
  def final_state_verification(context)
    final_target = context[:final_target_short] || context.fetch(:target_short)
    final_shorts = context.fetch(:shorts).merge(to => final_target)
    open_counts = context.fetch(:account_states, {}).transform_values do |state|
      state[:open_orders_count] || state["open_orders_count"]
    end
    target_flat = final_target <= FLAT_EPSILON
    source_preserved = final_shorts.fetch(from) > FLAT_EPSILON
    third_flat = final_shorts.except(from, to).values.all? { |short| short <= FLAT_EPSILON }
    open_orders_clear = [ from, to ].all? { |venue| c = open_counts[venue]; c.nil? || c.to_i.zero? }
    active_venues = final_shorts.select { |_venue, short| short > FLAT_EPSILON }.keys
    confirmed = target_flat && source_preserved && third_flat && open_orders_clear && active_venues == [ from ]
    {
      status: confirmed ? "confirmed" : "recheck_required",
      target_flat: target_flat,
      source_preserved: source_preserved,
      third_venue_flat: third_flat,
      open_orders_clear: open_orders_clear,
      exactly_one_active_venue: active_venues == [ from ],
      active_short_venues: active_venues
    }
  end

  def finalize_source_as_production_venue(context)
    return if context[:production_venue_finalized]
    return unless position.hedge
    return if HedgeVenues.normalize(position.hedge.execution_venue) == from

    position.hedge.update!(execution_venue: from)
    ActiveVenueAutoPolicy.new(position: position).enable_venue!(
      venue: from,
      reason: "target revert re-pointed production venue to preserved source"
    )
    context[:production_venue_finalized] = true
    context[:finalized_hedge_id] = position.hedge.id
  end

  def receipt_for(context:, blockers:, execution:)
    final_target = context[:final_target_short] || context.fetch(:target_short)
    verification = final_state_verification(context)
    target_already_flat = context.fetch(:target_short) <= FLAT_EPSILON
    {
      action: "revert_target_first_target_close",
      route: "#{from}->#{to}",
      sequence: "target_first",
      timestamp: context.fetch(:timestamp),
      position_id: position.id,
      from_venue: from,
      to_venue: to,
      source_venue: from,
      target_venue: to,
      dry_run: !live?,
      live: live?,
      production_venue: position.hedge&.execution_venue,
      current_extended_short_eth: decimal_string(context.dig(:shorts, "extended")),
      current_ethereal_short_eth: decimal_string(context.dig(:shorts, "ethereal")),
      current_nado_short_eth: decimal_string(context.dig(:shorts, "nado")),
      source_short_eth: decimal_string(context.fetch(:source_short)),
      target_short_eth: decimal_string(context.fetch(:target_short)),
      planned_venue: to,
      planned_side: "buy",
      reduce_only: true,
      size_eth: decimal_string(context.fetch(:target_short)),
      target_after_close_short: "0",
      target_already_flat: target_already_flat,
      planned_target_close_leg: context.fetch(:planned_target_close_leg),
      lifecycle_state: lifecycle_state(blockers: blockers, execution: execution, target_already_flat: target_already_flat, verification: verification),
      final_state_verification: verification,
      final_target_short_eth: decimal_string(final_target),
      final_source_short_eth: decimal_string(context.dig(:shorts, from)),
      target_flat_after: verification.fetch(:target_flat),
      source_preserved_after: verification.fetch(:source_preserved),
      third_venue_flat: verification.fetch(:third_venue_flat),
      open_orders_clear_after: verification.fetch(:open_orders_clear),
      exactly_one_active_venue: verification.fetch(:exactly_one_active_venue),
      active_short_venues_after: verification.fetch(:active_short_venues),
      readback_confirmed: execution ? revert_confirmed?(context) : target_already_flat,
      production_venue_finalized: context[:production_venue_finalized] == true,
      finalized_hedge_id: context[:finalized_hedge_id],
      live_gates: live_gates,
      execution_receipt: sanitize_sensitive(execution&.dig(:receipt)),
      submitted_order_id: execution&.dig(:exchange_order_id),
      orders_submitted: execution&.fetch(:orders_placed, 0).to_i,
      orders_placed: execution&.fetch(:orders_placed, 0).to_i,
      signatures_created: execution&.fetch(:signatures_created, 0).to_i,
      would_execute_live: execution&.fetch(:orders_placed, 0).to_i.positive?,
      finalization_command: "bin/rails migration:revert_target_first_target_close position_id=#{position.id} from=#{from} to=#{to} live=true confirmation=#{CONFIRMATION}",
      final_status: final_status(blockers: blockers, execution: execution, context: context, target_already_flat: target_already_flat),
      blockers: blockers,
      warnings: warnings(target_already_flat: target_already_flat),
      receipt_path: receipt_path.to_s
    }
  end

  def final_status(blockers:, execution:, context:, target_already_flat:)
    return live? ? "TARGET_REVERT_BLOCKED" : "dry_run" if blockers.any?
    return "TARGET_ALREADY_FLAT" if target_already_flat
    return "dry_run" unless live?

    execution && revert_confirmed?(context) ? "TARGET_REVERT_CONFIRMED" : "TARGET_REVERT_MANUAL_ACTION_REQUIRED"
  end

  def lifecycle_state(blockers:, execution:, target_already_flat:, verification:)
    return "REVERT_BLOCKED" if blockers.any?
    return "TARGET_ALREADY_FLAT" if target_already_flat
    return "TARGET_CLOSE_CONFIRMED" if execution && verification.fetch(:status) == "confirmed"

    live? ? "REVERT_REQUIRED" : "READY_FOR_TARGET_REVERT"
  end

  def live_gates
    {
      exact_confirmation: confirmation == CONFIRMATION,
      target_revert_enabled_required: require_revert_live_gate?,
      target_revert_enabled: bool_env(LIVE_GATE),
      target_live_enabled: venue_live_enabled?(to),
      extended_auto_disabled: !bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_disabled: !bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_disabled: !bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    }
  end

  def warnings(target_already_flat:)
    base = [ "Target revert never closes the source venue and never opens exposure; it only closes the target reduce-only and keeps the source." ]
    base << "Target is already flat; no target-close order is needed." if target_already_flat
    base
  end

  def other_venues_flat?(context)
    context.fetch(:other_venue_shorts).values.all? { |short| short <= FLAT_EPSILON }
  end

  def venue_for(venue)
    case venue
    when "extended" then @extended_venue
    when "ethereal" then @ethereal_venue
    when "nado" then @nado_venue
    else raise ArgumentError, "unsupported venue #{venue}"
    end
  end

  def venue_live_enabled?(venue)
    case venue
    when "extended" then bool_env("EXTENDED_LIVE_ENABLED") && @extended_venue.live_enabled?
    when "ethereal" then bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    when "nado" then bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED") && bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    else false
    end
  end

  def require_revert_live_gate?
    @require_revert_live_gate
  end

  def failure_receipt(error)
    {
      action: "revert_target_first_target_close",
      timestamp: now.call.utc.iso8601,
      position_id: position&.id,
      from_venue: from,
      to_venue: to,
      dry_run: !live?,
      live: live?,
      final_status: "TARGET_REVERT_BLOCKED",
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
