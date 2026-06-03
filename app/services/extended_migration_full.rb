class ExtendedMigrationFull
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_FULLY_MIGRATES_HEDGE_FROM_ETHEREAL_TO_EXTENDED".freeze

  def initialize(env: ENV, extended_venue: HedgeVenues::Extended.new(env: env), nado_venue: HedgeVenues::Nado.new(env: env),
                 ethereal_service: EtherealHedgeExecutionService.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env),
                 extended_lifecycle_factory: nil, now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @extended_venue = extended_venue
    @nado_venue = nado_venue
    @ethereal_service = ethereal_service
    @signer_client = signer_client
    @extended_lifecycle_factory = extended_lifecycle_factory || ->(lifecycle_env) { ExtendedMainnetLifecycleCheck.new(env: lifecycle_env, venue: @extended_venue, signer_client: @signer_client, sleeper: @sleeper) }
    @now = now
    @sleeper = sleeper
  end

  def run(position:, dry_run: true, sequence: "extended_first", confirmation: nil, max_slippage: "0.01")
    state = read_state(position)
    plan = build_plan(position: position, state: state, sequence: sequence, max_slippage: max_slippage)
    blockers = preflight_blockers(position: position, plan: plan, state: state, dry_run: dry_run, confirmation: confirmation)
    return result(status: dry_run ? "dry_run" : "blocked_before_submit", position: position, plan: plan, state: state, blockers: blockers, dry_run: dry_run) if dry_run || blockers.any?

    extended_result = submit_extended_leg(position: position, plan: plan, max_slippage: max_slippage)
    unless extended_leg_confirmed?(extended_result, plan)
      return result(status: "blocked_or_extended_not_confirmed", position: position, plan: plan, state: state, blockers: extended_result.blockers, dry_run: false, extended_execution: extended_result.receipt)
    end

    ethereal_position_after_extended = @ethereal_service.read_position
    ethereal_result = @ethereal_service.auto_rebalance_short(
      position: position,
      delta_eth: -plan.fetch(:ethereal_reduce_size),
      current_position: ethereal_position_after_extended,
      max_slippage: max_slippage
    )
    final_state = read_state(position)
    final_status = final_status_for(ethereal_result: ethereal_result, final_state: final_state)
    result(
      status: final_status,
      position: position,
      plan: plan,
      state: state,
      blockers: ethereal_result.blockers,
      dry_run: false,
      extended_execution: extended_result.receipt,
      ethereal_execution: ethereal_result.receipt,
      final_state: final_state
    )
  end

  private

  def read_state(position)
    extended_position = @extended_venue.read_position(symbol: "ETH")
    ethereal_position = @ethereal_service.read_position
    nado_position = @nado_venue.read_position(symbol: "ETH")
    {
      target_short: target_short(position),
      tolerance: tolerance(position),
      extended_position: extended_position,
      ethereal_position: ethereal_position,
      nado_position: nado_position,
      extended_short: short_size(extended_position),
      ethereal_short: short_size(ethereal_position),
      nado_short: short_size(nado_position),
      extended_account_state: @extended_venue.account_state,
      signer_health: @signer_client.health.with_indifferent_access
    }
  end

  def build_plan(position:, state:, sequence:, max_slippage:)
    target = state[:target_short] || BigDecimal("0")
    raw_extended_add = [ target - state[:extended_short], BigDecimal("0") ].max
    extended_preview = extended_preview(delta: raw_extended_add, current_short: state[:extended_short], max_slippage: max_slippage)
    extended_add = rounded_preview_size(extended_preview, fallback: raw_extended_add)
    ethereal_reduce = state[:ethereal_short]
    expected_extended = state[:extended_short] + extended_add
    expected_ethereal = [ state[:ethereal_short] - ethereal_reduce, BigDecimal("0") ].max

    {
      migration_sequence: sequence,
      combined_short_before: state[:extended_short] + state[:ethereal_short],
      extended_short_before: state[:extended_short],
      raw_extended_add_size: raw_extended_add,
      extended_add_size: extended_add,
      ethereal_reduce_size: ethereal_reduce,
      expected_extended_short_after: expected_extended,
      expected_ethereal_short_after: expected_ethereal,
      expected_combined_short_after: expected_extended + expected_ethereal,
      planned_extended_leg: extended_preview,
      planned_ethereal_leg: ethereal_reduce_preview(position: position, reduce_size: ethereal_reduce, state: state, max_slippage: max_slippage)
    }
  end

  def preflight_blockers(position:, plan:, state:, dry_run:, confirmation:)
    blockers = []
    blockers << "sequence must be extended_first" unless plan[:migration_sequence] == "extended_first"
    blockers << "position hedge execution_venue must be ethereal for migration_full" unless position.hedge&.execution_venue == "ethereal"
    blockers << "EXTENDED_MIGRATION_FULL_ENABLED must be true" unless dry_run || bool_env("EXTENDED_MIGRATION_FULL_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false during migration_full" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "Disable Ethereal auto-rebalance before full migration; otherwise Ethereal may fight the migration." if !dry_run && ethereal_auto_enabled?
    blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" unless bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless dry_run || confirmation == CONFIRMATION
    blockers << "target short could not be computed" unless state[:target_short]&.positive?
    blockers << "current Extended position is long; manual action required" if state.dig(:extended_position, :side).to_s == "long"
    blockers << "current Ethereal position must be short" unless state.dig(:ethereal_position, :side).to_s == "short" && state[:ethereal_short].positive?
    blockers << "current Nado position must be flat before migration_full" if state[:nado_short].positive?
    blockers << "Extended migration_full requires open_orders_count=0" unless state.dig(:extended_account_state, :open_orders_count).to_i.zero?
    blockers.concat(Array(state.dig(:extended_account_state, :margin_gate, :blockers)))
    blockers.concat(signer_health_blockers(state[:signer_health])) unless dry_run
    blockers << "Extended add size is below Extended min order size" if extended_min_size && plan[:extended_add_size].positive? && plan[:extended_add_size] < extended_min_size
    blockers << "Extended is already at or above target; migration_full has no Extended add leg" unless plan[:extended_add_size].positive?
    blockers << "Ethereal reduce size must be positive" unless plan[:ethereal_reduce_size].positive?
    blockers << "planned Ethereal leg must be reduce-only buy" unless ethereal_reduce_only_buy?(plan[:planned_ethereal_leg])
    blockers.concat(Array(plan.dig(:planned_extended_leg, :payload, :validation_blockers)))
    blockers.concat(Array(plan.dig(:planned_ethereal_leg, :blockers)))
    blockers.uniq
  end

  def submit_extended_leg(position:, plan:, max_slippage:)
    mode = plan[:extended_short_before].zero? ? "open_only" : "rebalance_delta"
    lifecycle_env = @env.to_h.merge(
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_PROBE_MAX_SIZE_ETH" => plan[:extended_add_size].to_s("F")
    )
    @extended_lifecycle_factory.call(lifecycle_env).run(
      position: position,
      mode: mode,
      size_eth: plan[:extended_add_size],
      delta_eth: mode == "rebalance_delta" ? plan[:extended_add_size] : nil,
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      max_slippage: max_slippage
    )
  end

  def result(status:, position:, plan:, state:, blockers:, dry_run:, extended_execution: nil, ethereal_execution: nil, final_state: nil)
    final_state ||= state
    receipt = {
      venue: "extended",
      action: "migration_full",
      dry_run: dry_run,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      timestamp: @now.call.utc.iso8601,
      target_short_eth: decimal_string(state[:target_short]),
      ethereal_short_before: decimal_string(state[:ethereal_short]),
      extended_short_before: decimal_string(state[:extended_short]),
      combined_short_before: decimal_string(plan[:combined_short_before]),
      extended_add_size: decimal_string(plan[:extended_add_size]),
      ethereal_reduce_size: decimal_string(plan[:ethereal_reduce_size]),
      planned_extended_leg: summarize_extended_leg(plan[:planned_extended_leg]),
      planned_ethereal_leg: summarize_ethereal_leg(plan[:planned_ethereal_leg]),
      extended_short_expected_after: decimal_string(plan[:expected_extended_short_after]),
      ethereal_short_expected_after: decimal_string(plan[:expected_ethereal_short_after]),
      combined_short_expected_after: decimal_string(plan[:expected_combined_short_after]),
      migration_sequence: plan[:migration_sequence],
      ethereal_auto_enabled: ethereal_auto_enabled?,
      signer_health: sanitize_sensitive(state[:signer_health]),
      extended_execution: sanitize_sensitive(extended_execution),
      ethereal_execution: sanitize_sensitive(ethereal_execution),
      exchange_order_ids: exchange_order_ids(extended_execution, ethereal_execution),
      ethereal_short_after: decimal_string(final_state[:ethereal_short]),
      extended_short_after: decimal_string(final_state[:extended_short]),
      combined_short_after: decimal_string(final_combined_short(final_state)),
      ethereal_short_actual_after: decimal_string(final_state[:ethereal_short]),
      extended_short_actual_after: decimal_string(final_state[:extended_short]),
      combined_short_actual_after: decimal_string(final_combined_short(final_state)),
      combined_delta_after: decimal_string(combined_delta_after(final_state)),
      final_status: status,
      orders_placed: orders_placed(extended_execution, ethereal_execution),
      signatures_created: signatures_created(extended_execution),
      submitted: orders_placed(extended_execution, ethereal_execution).positive?,
      blockers: Array(blockers).uniq,
      warnings: warnings_for(status)
    }.compact
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def extended_preview(delta:, current_short:, max_slippage:)
    return zero_extended_preview if delta.zero?

    current_short.zero? ? @extended_venue.open_short_preview(symbol: "ETH", size_eth: delta, max_slippage: max_slippage) : @extended_venue.rebalance_preview(symbol: "ETH", delta_eth: delta, max_slippage: max_slippage)
  end

  def zero_extended_preview
    {
      payload: {
        action: "no_op",
        side: "none",
        extended_side: "NONE",
        reduce_only: false,
        requested_size_eth: "0",
        rounded_size_eth: "0",
        validation_blockers: []
      },
      blockers: []
    }
  end

  def ethereal_reduce_preview(position:, reduce_size:, state:, max_slippage:)
    return zero_ethereal_preview if reduce_size.zero?

    @ethereal_service.build_order_preview(position: position, action: "rebalance", size_eth: -reduce_size, current_position: state[:ethereal_position], max_slippage: max_slippage)
  end

  def zero_ethereal_preview
    {
      summary: {
        side: "buy",
        reduce_only: true,
        rounded_size_eth: "0",
        expected_after_short_eth: "0",
        estimated_notional_usd: "0"
      },
      blockers: [],
      warnings: []
    }
  end

  def extended_leg_confirmed?(extended_result, _plan)
    extended_result.status == "success"
  end

  def ethereal_reduce_only_buy?(preview)
    summary = preview.fetch(:summary, {})
    summary[:side].to_s == "buy" && summary[:reduce_only] == true
  end

  def signer_health_blockers(health)
    blockers = []
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless ActiveModel::Type::Boolean.new.cast(health[:ok]) && Array.wrap(health[:supported_exchanges]).include?("Extended") && Array.wrap(health[:supported_actions]).include?("sign_extended_order")
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    blockers
  end

  def target_short(position)
    valuation = PositionValuation.current(position)
    valuation.weth_exposure && position.hedge ? valuation.weth_exposure * position.hedge.target : nil
  end

  def tolerance(position)
    target = target_short(position)
    target && position.hedge ? target * position.hedge.tolerance : nil
  end

  def short_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?

    size = BigDecimal(position.fetch(:size, 0).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, KeyError
    BigDecimal("0")
  end

  def extended_min_size
    raw = @extended_venue.market_metadata_diagnostics[:min_size]
    return if raw.blank?

    BigDecimal(raw.to_s)
  rescue ArgumentError
    nil
  end

  def rounded_preview_size(preview, fallback:)
    BigDecimal(preview.dig(:payload, :rounded_size_eth).to_s)
  rescue ArgumentError
    fallback
  end

  def summarize_extended_leg(preview)
    preview.fetch(:payload).slice(:action, :side, :extended_side, :reduce_only, :requested_size_eth, :rounded_size_eth, :estimated_notional_usd)
  end

  def summarize_ethereal_leg(preview)
    preview.fetch(:summary).slice(:side, :reduce_only, :rounded_size_eth, :expected_after_short_eth, :estimated_notional_usd)
  end

  def orders_placed(extended_execution, ethereal_execution)
    extended_execution.to_h[:orders_placed].to_i + (ethereal_execution.to_h[:final_status] == "submitted_and_confirmed" || ethereal_execution.to_h[:final_status].to_s.start_with?("submitted_but") ? 1 : 0)
  end

  def signatures_created(extended_execution)
    extended_execution.to_h[:signatures_created].to_i
  end

  def exchange_order_ids(extended_execution, ethereal_execution)
    {
      extended: extended_execution.to_h[:exchange_order_id],
      ethereal: ethereal_execution.to_h[:exchange_order_id] || ethereal_execution.to_h.dig(:submitted_order_summary, :exchange_order_id)
    }.compact
  end

  def final_status_for(ethereal_result:, final_state:)
    return "partial_migration_manual_action_required" unless ethereal_result.status == "submitted_and_confirmed"
    return "combined_outside_tolerance_manual_action_required" unless combined_matches_target?(final_state[:target_short], final_combined_short(final_state), final_state[:tolerance])

    "success"
  end

  def combined_matches_target?(target, combined, tolerance)
    return false unless target && tolerance

    (target - combined).abs <= tolerance
  end

  def final_combined_short(final_state)
    final_state[:ethereal_short] + final_state[:extended_short]
  end

  def combined_delta_after(final_state)
    return unless final_state[:target_short]

    final_combined_short(final_state) - final_state[:target_short]
  end

  def warnings_for(status)
    warnings = [
      "Fast migration is Extended-first and temporarily overhedges until Ethereal close confirms.",
      "Production venue is not switched until migration_finalize succeeds."
    ]
    warnings << "Disable Ethereal auto-rebalance before live migration; otherwise Ethereal may fight the migration." if ethereal_auto_enabled?
    warnings << "Extended leg confirmed but Ethereal leg did not; total hedge may be temporarily over target by the Ethereal reduce size." if status == "partial_migration_manual_action_required"
    warnings << "Combined Ethereal + Extended short is outside hedge tolerance after full migration; manual review required." if status == "combined_outside_tolerance_manual_action_required"
    warnings
  end

  def ethereal_auto_enabled?
    bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: @env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature/i) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end
end
