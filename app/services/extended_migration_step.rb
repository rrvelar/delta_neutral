class ExtendedMigrationStep
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_MIGRATES_HEDGE_FROM_ETHEREAL_TO_EXTENDED".freeze

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

  def run(position:, step_size_eth: "0.01", dry_run: true, confirmation: nil, max_slippage: "0.01")
    state = read_state(position)
    plan = build_plan(position: position, state: state, step_size_eth: step_size_eth, max_slippage: max_slippage)
    blockers = preflight_blockers(position: position, plan: plan, state: state, dry_run: dry_run, confirmation: confirmation)
    return result(status: dry_run ? "dry_run" : "blocked_before_submit", position: position, plan: plan, state: state, blockers: blockers, dry_run: dry_run) if dry_run || blockers.any?

    extended_result = submit_extended_leg(position: position, plan: plan, max_slippage: max_slippage)
    unless extended_result.status == "success"
      return result(status: "extended_leg_not_confirmed", position: position, plan: plan, state: state, blockers: extended_result.blockers, dry_run: false, extended_execution: extended_result.receipt)
    end

    ethereal_position_after_extended = @ethereal_service.read_position
    ethereal_result = @ethereal_service.auto_rebalance_short(
      position: position,
      delta_eth: -plan.fetch(:step_size_eth),
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

  def build_plan(position:, state:, step_size_eth:, max_slippage:)
    step = BigDecimal(step_size_eth.to_s)
    max_step = BigDecimal((@env["EXTENDED_MIGRATION_MAX_STEP_SIZE_ETH"].presence || "0.02").to_s)
    extended_delta = step
    ethereal_delta = -step
    {
      step_size_eth: step,
      max_step_size_eth: max_step,
      migration_sequence: "extended_first",
      combined_short_before: state[:extended_short] + state[:ethereal_short],
      expected_extended_short_after: state[:extended_short] + step,
      expected_ethereal_short_after: [ state[:ethereal_short] - step, BigDecimal("0") ].max,
      expected_combined_short_after: state[:extended_short] + state[:ethereal_short],
      planned_extended_leg: extended_preview(delta: extended_delta, current_short: state[:extended_short], max_slippage: max_slippage),
      planned_ethereal_leg: @ethereal_service.build_order_preview(position: position, action: "rebalance", size_eth: ethereal_delta, current_position: state[:ethereal_position], max_slippage: max_slippage)
    }
  end

  def preflight_blockers(position:, plan:, state:, dry_run:, confirmation:)
    blockers = []
    blockers << "position hedge execution_venue must be ethereal for migration_step" unless position.hedge&.execution_venue == "ethereal"
    blockers << "EXTENDED_MIGRATION_STEP_ENABLED must be true" unless dry_run || bool_env("EXTENDED_MIGRATION_STEP_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false during migration_step" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "Disable Ethereal auto-rebalance before stepwise migration; otherwise Ethereal may fight the migration." if !dry_run && ethereal_auto_enabled?
    blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" unless bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless dry_run || confirmation == CONFIRMATION
    blockers << "current Extended position is long; manual action required" if state.dig(:extended_position, :side).to_s == "long"
    blockers << "current Ethereal position must be short" unless state.dig(:ethereal_position, :side).to_s == "short" && state[:ethereal_short].positive?
    blockers << "current Nado position must be flat before migration_step" if state[:nado_short].positive?
    blockers << "Extended migration_step requires open_orders_count=0" unless state.dig(:extended_account_state, :open_orders_count).to_i.zero?
    blockers.concat(Array(state.dig(:extended_account_state, :margin_gate, :blockers)))
    blockers.concat(signer_health_blockers(state[:signer_health])) unless dry_run
    blockers << "step_size_eth must be positive" unless plan[:step_size_eth].positive?
    blockers << "step_size_eth #{plan[:step_size_eth].to_s('F')} exceeds EXTENDED_MIGRATION_MAX_STEP_SIZE_ETH #{plan[:max_step_size_eth].to_s('F')}" if plan[:step_size_eth] > plan[:max_step_size_eth]
    blockers << "step_size_eth is below Extended min order size" if extended_min_size && plan[:step_size_eth] < extended_min_size
    blockers << "Ethereal current short is smaller than migration step" if state[:ethereal_short] < plan[:step_size_eth]
    blockers << "combined Ethereal + Extended short is not within hedge tolerance before migration_step" unless combined_matches_target?(state[:target_short], plan[:combined_short_before], state[:tolerance])
    blockers.concat(Array(plan.dig(:planned_extended_leg, :payload, :validation_blockers)))
    blockers.concat(Array(plan.dig(:planned_ethereal_leg, :blockers)))
    blockers.uniq
  end

  def submit_extended_leg(position:, plan:, max_slippage:)
    mode = plan[:expected_extended_short_after] == plan[:step_size_eth] ? "open_only" : "rebalance_delta"
    lifecycle_env = @env.to_h.merge(
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_PROBE_MAX_SIZE_ETH" => plan[:step_size_eth].to_s("F")
    )
    @extended_lifecycle_factory.call(lifecycle_env).run(
      position: position,
      mode: mode,
      size_eth: plan[:step_size_eth],
      delta_eth: mode == "rebalance_delta" ? plan[:step_size_eth] : nil,
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      max_slippage: max_slippage
    )
  end

  def result(status:, position:, plan:, state:, blockers:, dry_run:, extended_execution: nil, ethereal_execution: nil, final_state: nil)
    final_state ||= state
    receipt = {
      venue: "extended",
      action: "migration_step",
      dry_run: dry_run,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      timestamp: @now.call.utc.iso8601,
      target_short_eth: decimal_string(state[:target_short]),
      ethereal_short_before: decimal_string(state[:ethereal_short]),
      extended_short_before: decimal_string(state[:extended_short]),
      combined_short_before: decimal_string(plan[:combined_short_before]),
      step_size_eth: decimal_string(plan[:step_size_eth]),
      max_step_size_eth: decimal_string(plan[:max_step_size_eth]),
      migration_sequence: plan[:migration_sequence],
      planned_extended_leg: summarize_extended_leg(plan[:planned_extended_leg]),
      planned_ethereal_leg: summarize_ethereal_leg(plan[:planned_ethereal_leg]),
      ethereal_auto_enabled: ethereal_auto_enabled?,
      ethereal_short_expected_after: decimal_string(plan[:expected_ethereal_short_after]),
      extended_short_expected_after: decimal_string(plan[:expected_extended_short_after]),
      combined_short_expected_after: decimal_string(plan[:expected_combined_short_after]),
      signer_health: sanitize_sensitive(state[:signer_health]),
      extended_execution: sanitize_sensitive(extended_execution),
      ethereal_execution: sanitize_sensitive(ethereal_execution),
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
    current_short.zero? ? @extended_venue.open_short_preview(symbol: "ETH", size_eth: delta, max_slippage: max_slippage) : @extended_venue.rebalance_preview(symbol: "ETH", delta_eth: delta, max_slippage: max_slippage)
  end

  def signer_health_blockers(health)
    blockers = []
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless ActiveModel::Type::Boolean.new.cast(health[:ok]) && Array.wrap(health[:supported_exchanges]).include?("Extended") && Array.wrap(health[:supported_actions]).include?("sign_extended_order")
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    blockers
  end

  def combined_matches_target?(target, combined, tolerance)
    return false unless target && tolerance

    (target - combined).abs <= tolerance
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

  def warnings_for(status)
    warnings = [ "Migration is stepwise. Production venue is not switched until finalize succeeds." ]
    warnings << "Disable Ethereal auto-rebalance before live migration; otherwise Ethereal may fight the migration." if ethereal_auto_enabled?
    warnings << "Extended leg confirmed but Ethereal leg did not; total hedge may be temporarily over target by the step size." if status == "partial_migration_manual_action_required"
    warnings << "Combined Ethereal + Extended short is outside hedge tolerance after migration step; manual review required." if status == "combined_outside_tolerance_manual_action_required"
    warnings
  end

  def final_status_for(ethereal_result:, final_state:)
    return "partial_migration_manual_action_required" unless ethereal_result.status == "submitted_and_confirmed"
    return "combined_outside_tolerance_manual_action_required" unless combined_matches_target?(final_state[:target_short], final_combined_short(final_state), final_state[:tolerance])

    "success"
  end

  def final_combined_short(final_state)
    final_state[:ethereal_short] + final_state[:extended_short]
  end

  def combined_delta_after(final_state)
    return unless final_state[:target_short]

    final_combined_short(final_state) - final_state[:target_short]
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
