class ExtendedAutoRebalanceOnce
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_REBALANCE_ORDERS".freeze
  DEFAULT_RECENT_REBALANCE_GUARD_SECONDS = 60
  PRE_SUBMIT_EPSILON_ETH = BigDecimal("0.00000001")

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), nado_venue: HedgeVenues::Nado.new(env: env), now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) }, fresh_target_factory: nil)
    @env = env
    @venue = venue
    @signer_client = signer_client
    @nado_venue = nado_venue
    @now = now
    @sleeper = sleeper
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
  end

  def run(position:, dry_run: true, confirmation: nil, max_slippage: "0.01", one_shot: true, mode: nil, probe: false, max_size_eth: nil)
    return run_unlocked(position: position, dry_run: dry_run, confirmation: confirmation, max_slippage: max_slippage, one_shot: one_shot, mode: mode, probe: probe, max_size_eth: max_size_eth) if dry_run || one_shot

    result = nil
    ran = JobConcurrencyGuard.with_lock("extended_auto:position:#{position.id}") do
      result = run_unlocked(position: position, dry_run: dry_run, confirmation: confirmation, max_slippage: max_slippage, one_shot: one_shot, mode: mode, probe: probe, max_size_eth: max_size_eth)
    end
    return result if ran

    Result.new(
      "blocked_before_submit",
      [ "Extended auto rebalance already running for position #{position.id}" ],
      [],
      {
        venue: "extended",
        action: "auto_rebalance_once",
        source: "continuous_auto",
        dry_run: false,
        position_id: position.id,
        final_status: "blocked_before_submit",
        orders_placed: 0,
        signatures_created: 0,
        submitted: false,
        blockers: [ "Extended auto rebalance already running for position #{position.id}" ],
        warnings: []
      }
    )
  end

  private

  def run_unlocked(position:, dry_run:, confirmation:, max_slippage:, one_shot:, mode:, probe:, max_size_eth:)
    current_position = @venue.read_position(symbol: "ETH")
    account_state = @venue.account_state
    signer_health = signer_health_for_diagnostics
    plan = build_plan(
      position: position,
      current_position: current_position,
      max_slippage: max_slippage,
      probe_mode: probe_mode?(mode: mode, probe: probe),
      max_size_eth: max_size_eth,
      one_shot: one_shot
    )
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

    pre_submit_blockers = pre_submit_readback_blockers(plan)
    if pre_submit_blockers.any?
      return result(
        status: "blocked_before_submit",
        blockers: pre_submit_blockers,
        position: position,
        plan: plan,
        current_position: current_position,
        account_state: account_state,
        signer_health: signer_health,
        conflict_state: conflict_state,
        dry_run: false
      )
    end

    lifecycle = ExtendedMainnetLifecycleCheck.new(env: lifecycle_env(plan), venue: @venue, signer_client: @signer_client, sleeper: @sleeper).run(
      position: position,
      mode: lifecycle_mode_for(plan),
      size_eth: plan.fetch(:order_size_eth),
      delta_eth: lifecycle_mode_for(plan) == "rebalance_delta" ? plan.fetch(:delta_eth) : nil,
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

  def build_plan(position:, current_position:, max_slippage:, probe_mode:, max_size_eth:, one_shot:)
    fresh_target = @fresh_target_factory.call(position).resolve(refresh_if_stale: true)
    target = fresh_target[:target_short_eth]
    current_short = short_size(current_position)
    tolerance = target && position.hedge ? target * position.hedge.tolerance : nil
    delta = target ? target - current_short : nil
    action = intended_action(delta: delta, tolerance: tolerance)
    cap = one_shot ? one_shot_cap(max_size_eth) : auto_cap
    requested_order_size = order_size_decimal(action: action, delta: delta)
    cap_exceeded = requested_order_size && requested_order_size > cap
    partial_auto = !one_shot && cap_exceeded == true && auto_partial_allowed?
    capped_delta = (probe_mode || partial_auto) && cap_exceeded ? capped_delta(delta: delta, cap: cap) : delta
    preview = preview_for(action: action, delta: capped_delta, current_short: current_short, max_slippage: max_slippage)

    {
      source: one_shot ? source_for_one_shot(probe_mode: probe_mode) : "continuous_auto",
      target_short_eth: decimal_string(target),
      target_source: fresh_target[:target_source],
      target_fresh: fresh_target[:target_fresh],
      exposure_source: fresh_target[:exposure_source],
      exposure_refreshed_at: fresh_target[:exposure_refreshed_at],
      exposure_stale: fresh_target[:exposure_stale],
      exposure_blockers: Array(fresh_target[:blockers]),
      current_short_eth: current_short.to_s("F"),
      current_side: current_position&.fetch(:side, nil),
      raw_delta_eth: decimal_string(delta),
      delta_eth: decimal_string(capped_delta),
      tolerance_eth: decimal_string(tolerance),
      intended_action: action,
      requested_order_size_eth: decimal_string(requested_order_size),
      capped_order_size_eth: order_size_for(action: action, delta: capped_delta),
      order_size_eth: order_size_for(action: action, delta: capped_delta),
      cap_eth: cap.to_s("F"),
      auto_max_rebalance_size_eth: one_shot ? nil : cap.to_s("F"),
      probe_mode: probe_mode,
      cap_exceeded: cap_exceeded == true,
      partial_probe: probe_mode && cap_exceeded == true,
      partial_auto_rebalance: partial_auto,
      migration_mode: migration_mode?,
      auto_partial_allowed: auto_partial_allowed?,
      intended_order: preview&.fetch(:payload, nil),
      order_validation_blockers: Array(preview&.dig(:payload, :validation_blockers)),
      preview_blockers: preview&.fetch(:blockers, []) || []
    }
  end

  def readiness_blockers(position:, plan:, account_state:, signer_health:, conflict_state:, dry_run:, confirmation:, one_shot:)
    blockers = []
    blockers.concat(Array(plan[:exposure_blockers]))
    blockers.concat(dry_run ? plan.fetch(:preview_blockers) : plan.fetch(:order_validation_blockers))
    blockers.concat(Array(account_state.dig(:margin_gate, :blockers)))
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    if one_shot
      blockers << "EXTENDED_ONE_SHOT_REBALANCE_ENABLED must be true" unless dry_run || bool_env("EXTENDED_ONE_SHOT_REBALANCE_ENABLED")
      blockers << "submitted confirmation must equal #{CONFIRMATION}" unless dry_run || confirmation == CONFIRMATION
      blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false for Extended probe_rebalance" if plan[:probe_mode] && bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    else
      blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must be true" unless dry_run || bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    end
    blockers << "EXTENDED_ISOLATED_ACCOUNT_CONFIRMED must be true" unless bool_env("EXTENDED_ISOLATED_ACCOUNT_CONFIRMED")
    blockers << "Extended account balance/collateral unavailable" if account_state[:account_value_usd].blank? && account_state[:collateral_usd].blank?
    blockers << "Extended market metadata unavailable" unless account_state[:market_metadata_available]
    blockers << "#{one_shot ? 'Extended one-shot' : 'Extended continuous auto'} requires open_orders_count=0" unless account_state[:open_orders_count].to_i.zero?
    blockers << "Current Extended position is long; manual action required" if plan[:current_side].to_s == "long"
    if one_shot
      blockers << "Extended one-shot order size #{plan[:requested_order_size_eth]} exceeds EXTENDED_ONE_SHOT_MAX_SIZE_ETH #{plan[:cap_eth]}; use probe mode or explicit migration gate" if plan[:cap_exceeded] && !plan[:partial_probe] && !plan[:migration_mode]
      blockers << "EXTENDED_MIGRATION_REBALANCE_ENABLED must be true for full-target Extended one-shot migration" if plan[:cap_exceeded] && !plan[:partial_probe] && !migration_mode?
      blockers << "Extended probe_rebalance must be a capped partial probe; full target orders require migration mode" if plan[:probe_mode] && !plan[:partial_probe] && plan[:intended_action] != "no_op"
    else
      blockers << "Extended continuous auto order size #{plan[:requested_order_size_eth]} exceeds EXTENDED_AUTO_MAX_REBALANCE_SIZE_ETH #{plan[:auto_max_rebalance_size_eth]} and EXTENDED_AUTO_ALLOW_PARTIAL_REBALANCE is false" if plan[:cap_exceeded] && !plan[:partial_auto_rebalance]
    end
    blockers << "Position hedge execution_venue must be extended for Extended live rebalance" if !dry_run && !plan[:partial_probe] && position.hedge&.execution_venue != "extended"
    blockers << "Current Nado position must be flat before Extended live rebalance" if conflict_state[:nado_short_eth].to_d.positive?
    blockers.concat(recent_rebalance_blockers(position: position, dry_run: dry_run, one_shot: one_shot))
    blockers.concat(signer_health_blockers(signer_health)) unless dry_run
    blockers.uniq
  end

  def pre_submit_readback_blockers(plan)
    fresh_position = @venue.read_position(symbol: "ETH")
    fresh_short = short_size(fresh_position)
    planned_old_short = BigDecimal(plan.fetch(:current_short_eth).to_s)
    return [] if (fresh_short - planned_old_short).abs <= PRE_SUBMIT_EPSILON_ETH

    [ "Extended pre-submit readback changed from planned old_short_size #{planned_old_short.to_s('F')} to #{fresh_short.to_s('F')}; aborting before signing/submission." ]
  rescue => e
    [ "Extended pre-submit readback failed before signing/submission: #{e.class}: #{e.message}" ]
  end

  def result(status:, blockers:, position:, plan:, current_position:, account_state:, signer_health:, conflict_state:, dry_run:, execution: nil)
    receipt = {
      venue: "extended",
      action: "auto_rebalance_once",
      source: plan[:source],
      dry_run: dry_run,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      timestamp: @now.call.utc.iso8601,
      target_short_eth: plan[:target_short_eth],
      target_source: plan[:target_source],
      target_fresh: plan[:target_fresh],
      exposure_source: plan[:exposure_source],
      exposure_refreshed_at: plan[:exposure_refreshed_at],
      exposure_stale: plan[:exposure_stale],
      exposure_blockers: plan[:exposure_blockers],
      current_short_eth: plan[:current_short_eth],
      raw_delta_eth: plan[:raw_delta_eth],
      delta_eth: plan[:delta_eth],
      tolerance_eth: plan[:tolerance_eth],
      intended_action: plan[:intended_action],
      requested_order_size_eth: plan[:requested_order_size_eth],
      capped_order_size_eth: plan[:capped_order_size_eth],
      cap_eth: plan[:cap_eth],
      auto_max_rebalance_size_eth: plan[:auto_max_rebalance_size_eth],
      probe_mode: plan[:probe_mode],
      cap_exceeded: plan[:cap_exceeded],
      partial_probe: plan[:partial_probe],
      partial_auto_rebalance: plan[:partial_auto_rebalance],
      migration_mode: plan[:migration_mode],
      selected_hedge_venue: position.hedge&.execution_venue,
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
      warnings: warnings_for(plan)
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

  def order_size_decimal(action:, delta:)
    return nil if action == "no_op" || delta.nil?

    delta.abs
  end

  def capped_delta(delta:, cap:)
    return delta unless delta

    delta.negative? ? -cap : cap
  end

  def one_shot_cap(max_size_eth)
    BigDecimal((max_size_eth.presence || @env["EXTENDED_ONE_SHOT_MAX_SIZE_ETH"].presence || "0.02").to_s)
  rescue ArgumentError
    BigDecimal("0.02")
  end

  def auto_cap
    BigDecimal((@env["EXTENDED_AUTO_MAX_REBALANCE_SIZE_ETH"].presence || "0.10").to_s)
  rescue ArgumentError
    BigDecimal("0.10")
  end

  def auto_partial_allowed?
    ActiveModel::Type::Boolean.new.cast(@env.fetch("EXTENDED_AUTO_ALLOW_PARTIAL_REBALANCE", "true"))
  end

  def probe_mode?(mode:, probe:)
    ActiveModel::Type::Boolean.new.cast(probe) || mode.to_s == "probe_rebalance"
  end

  def migration_mode?
    bool_env("EXTENDED_MIGRATION_REBALANCE_ENABLED") == true
  end

  def source_for_one_shot(probe_mode:)
    return "one_shot_probe" if probe_mode
    return "migration" if migration_mode?

    "one_shot"
  end

  def warnings_for(plan)
    warnings = [ plan[:source] == "continuous_auto" ? "Extended continuous auto is gated by production venue, flat venue conflicts, signer health, and leverage/margin checks." : "Extended one-shot auto is manual-only; continuous auto remains separately gated." ]
    warnings << "Extended probe mode capped the intended order to #{plan[:capped_order_size_eth]} ETH; this is a partial probe, not a full rebalance." if plan[:partial_probe]
    warnings << "Extended continuous auto capped the intended order to #{plan[:capped_order_size_eth]} ETH; this is a partial auto rebalance." if plan[:partial_auto_rebalance]
    warnings << "Extended full-target one-shot exceeds probe cap and requires explicit migration mode." if plan[:source] != "continuous_auto" && plan[:cap_exceeded] && !plan[:partial_probe] && !plan[:migration_mode]
    warnings
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

  def recent_rebalance_blockers(position:, dry_run:, one_shot:)
    return [] if dry_run || one_shot || !position.is_a?(Position) || position.hedge.nil?

    recent = position.hedge.short_rebalances
      .where(venue: "extended", asset: [ nil, "ETH", "WETH" ])
      .where(status: [ ShortRebalance::STATUS_SUCCESS, ShortRebalance::STATUS_PENDING ])
      .where("rebalanced_at >= ? OR created_at >= ?", recent_rebalance_guard_seconds.seconds.ago, recent_rebalance_guard_seconds.seconds.ago)
      .order(rebalanced_at: :desc, created_at: :desc)
      .first
    return [] unless recent

    [ "Recent Extended rebalance ##{recent.id} is within #{recent_rebalance_guard_seconds}s guard window; skipping duplicate auto submit." ]
  end

  def recent_rebalance_guard_seconds
    Integer(@env.fetch("EXTENDED_AUTO_RECENT_REBALANCE_GUARD_SECONDS", DEFAULT_RECENT_REBALANCE_GUARD_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_RECENT_REBALANCE_GUARD_SECONDS
  end

  def lifecycle_env(plan)
    @env.to_h.merge(
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "EXTENDED_PROBE_MAX_SIZE_ETH" => plan.fetch(:order_size_eth).to_s
    )
  end

  def lifecycle_mode_for(plan)
    return "open_only" if plan[:intended_action] == "increase_short" && BigDecimal(plan[:current_short_eth].to_s).zero?

    "rebalance_delta"
  rescue ArgumentError
    "rebalance_delta"
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
