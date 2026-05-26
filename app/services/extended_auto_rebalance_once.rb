class ExtendedAutoRebalanceOnce
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_REBALANCE_ORDERS".freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), nado_venue: HedgeVenues::Nado.new(env: env), now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @venue = venue
    @signer_client = signer_client
    @nado_venue = nado_venue
    @now = now
    @sleeper = sleeper
  end

  def run(position:, dry_run: true, confirmation: nil, max_slippage: "0.01", one_shot: true)
    current_position = @venue.read_position(symbol: "ETH")
    account_state = @venue.account_state
    signer_health = signer_health_for_diagnostics
    plan = build_plan(position: position, current_position: current_position, max_slippage: max_slippage)
    conflict_state = conflict_state_for(position: position, dry_run: dry_run)
    blockers = readiness_blockers(
      position: position,
      plan: plan,
      account_state: account_state,
      signer_health: signer_health,
      conflict_state: conflict_state,
      dry_run: dry_run,
      confirmation: confirmation,
      one_shot: one_shot
    )

    if dry_run || blockers.any? || plan[:intended_action] == "no_op"
      return result(
        status: dry_run ? "dry_run" : (plan[:intended_action] == "no_op" ? "no_op" : "blocked_before_submit"),
        blockers: blockers,
        position: position,
        plan: plan,
        current_position: current_position,
        account_state: account_state,
        signer_health: signer_health,
        conflict_state: conflict_state,
        dry_run: dry_run
      )
    end

    lifecycle = ExtendedMainnetLifecycleCheck.new(env: lifecycle_env, venue: @venue, signer_client: @signer_client, sleeper: @sleeper).run(
      position: position,
      mode: "rebalance_delta",
      size_eth: plan.fetch(:order_size_eth),
      delta_eth: plan.fetch(:delta_eth),
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      max_slippage: max_slippage
    )
    result(
      status: lifecycle.status,
      blockers: lifecycle.blockers,
      position: position,
      plan: plan,
      current_position: current_position,
      account_state: account_state,
      signer_health: signer_health,
      conflict_state: conflict_state,
      dry_run: false,
      execution: lifecycle.receipt
    )
  end

  private

  def build_plan(position:, current_position:, max_slippage:)
    valuation = PositionValuation.current(position)
    target = valuation.weth_exposure && position.hedge ? valuation.weth_exposure * position.hedge.target : nil
    current_short = short_size(current_position)
    tolerance = target && position.hedge ? target * position.hedge.tolerance : nil
    delta = target ? target - current_short : nil
    action = intended_action(delta: delta, tolerance: tolerance)
    preview = preview_for(action: action, delta: delta, current_short: current_short, max_slippage: max_slippage)

    {
      target_short_eth: decimal_string(target),
      current_short_eth: current_short.to_s("F"),
      current_side: current_position&.fetch(:side, nil),
      delta_eth: decimal_string(delta),
      tolerance_eth: decimal_string(tolerance),
      intended_action: action,
      order_size_eth: order_size_for(action: action, delta: delta),
      intended_order: preview&.fetch(:payload, nil),
      order_validation_blockers: Array(preview&.dig(:payload, :validation_blockers)),
      preview_blockers: preview&.fetch(:blockers, []) || []
    }
  end

  def readiness_blockers(position:, plan:, account_state:, signer_health:, conflict_state:, dry_run:, confirmation:, one_shot:)
    blockers = []
    blockers.concat(dry_run ? plan.fetch(:preview_blockers) : plan.fetch(:order_validation_blockers))
    blockers.concat(Array(account_state.dig(:margin_gate, :blockers)))
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    if one_shot
      blockers << "EXTENDED_ONE_SHOT_REBALANCE_ENABLED must be true" unless dry_run || bool_env("EXTENDED_ONE_SHOT_REBALANCE_ENABLED")
      blockers << "submitted confirmation must equal #{CONFIRMATION}" unless dry_run || confirmation == CONFIRMATION
    else
      blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be true" unless dry_run || bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    end
    blockers << "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED must be true" unless bool_env("EXTENDED_ISOLATED_ACCOUNT_CONFIRMED")
    blockers << "Extended account balance/collateral unavailable" if account_state[:account_value_usd].blank? && account_state[:collateral_usd].blank?
    blockers << "Extended market metadata unavailable" unless account_state[:market_metadata_available]
    blockers << "Extended one-shot requires open_orders_count=0" unless account_state[:open_orders_count].to_i.zero?
    blockers << "Current Extended position is long; manual action required" if plan[:current_side].to_s == "long"
    blockers << "Position hedge execution_venue must be extended for Extended live rebalance" if !dry_run && position.hedge&.execution_venue != "extended"
    blockers << "Current Nado position must be flat before Extended live rebalance" if conflict_state[:nado_short_eth].to_d.positive?
    blockers.concat(signer_health_blockers(signer_health)) unless dry_run
    blockers.uniq
  end

  def result(status:, blockers:, position:, plan:, current_position:, account_state:, signer_health:, conflict_state:, dry_run:, execution: nil)
    receipt = {
      venue: "extended",
      action: "auto_rebalance_once",
      dry_run: dry_run,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      timestamp: @now.call.utc.iso8601,
      target_short_eth: plan[:target_short_eth],
      current_short_eth: plan[:current_short_eth],
      delta_eth: plan[:delta_eth],
      tolerance_eth: plan[:tolerance_eth],
      intended_action: plan[:intended_action],
      intended_order: plan[:intended_order],
      readiness_gates: {
        live_enabled: bool_env("EXTENDED_LIVE_ENABLED"),
        one_shot_enabled: bool_env("EXTENDED_ONE_SHOT_REBALANCE_ENABLED"),
        continuous_auto_enabled: bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
        isolated_account_confirmed: bool_env("EXTENDED_ISOLATED_ACCOUNT_CONFIRMED"),
        margin_gate: account_state[:margin_gate],
        open_orders_count: account_state[:open_orders_count],
        market_metadata_available: account_state[:market_metadata_available],
        account_value_usd: account_state[:account_value_usd],
        collateral_usd: account_state[:collateral_usd]
      },
      conflict_checks: conflict_state,
      signer_health: sanitize_sensitive(signer_health),
      signer_request: execution && execution[:signer_request],
      signer_response: execution && execution[:signer_response],
      submit_payload: execution && execution[:submit_payload],
      submit_response: execution && execution[:submit_response],
      exchange_order_id: execution && execution[:exchange_order_id],
      readback_attempts: execution ? execution[:readback_attempts] : [],
      final_status: status,
      orders_placed: execution ? execution[:orders_placed] : 0,
      signatures_created: execution ? execution[:signatures_created] : 0,
      submitted: execution ? execution[:submitted] : false,
      blockers: blockers.uniq,
      warnings: [ "Extended one-shot auto is manual-only; continuous auto remains separately gated." ]
    }.compact
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def intended_action(delta:, tolerance:)
    return "blocked" unless delta && tolerance
    return "no_op" if delta.abs <= tolerance

    delta.positive? ? "increase_short" : "decrease_short"
  end

  def preview_for(action:, delta:, current_short:, max_slippage:)
    case action
    when "increase_short"
      @venue.rebalance_preview(symbol: "ETH", delta_eth: delta, max_slippage: max_slippage)
    when "decrease_short"
      @venue.rebalance_preview(symbol: "ETH", delta_eth: delta, max_slippage: max_slippage)
    when "no_op"
      nil
    else
      @venue.rebalance_preview(symbol: "ETH", delta_eth: BigDecimal("0"), max_slippage: max_slippage)
    end
  end

  def order_size_for(action:, delta:)
    return nil if action == "no_op" || delta.nil?

    delta.abs.to_s("F")
  end

  def short_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)

    BigDecimal(position[:short_size].to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def conflict_state_for(position:, dry_run:)
    state = {
      selected_hedge_venue: position.hedge&.execution_venue,
      nado_position_checked: !dry_run,
      nado_short_eth: "0"
    }
    return state if dry_run

    nado_position = @nado_venue.read_position(symbol: "ETH")
    state[:nado_short_eth] = short_size(nado_position).to_s("F")
    state[:nado_position_present] = nado_position.present?
    state
  rescue => e
    state.merge(nado_position_error: "#{e.class}: #{e.message}")
  end

  def signer_health_for_diagnostics
    @signer_client.health.with_indifferent_access
  end

  def signer_health_blockers(health)
    blockers = []
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless ActiveModel::Type::Boolean.new.cast(health[:ok]) && Array.wrap(health[:supported_exchanges]).include?("Extended") && Array.wrap(health[:supported_actions]).include?("sign_extended_order")
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    blockers
  end

  def lifecycle_env
    @env.to_h.merge(
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false"
    )
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def bool_env(key)
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
