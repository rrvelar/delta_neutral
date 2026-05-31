require "digest"
require "net/http"

class NadoHedgeExecutionService
  DEFAULT_SYMBOL = "ETH-PERP".freeze
  DEFAULT_MAX_SLIPPAGE = BigDecimal("0.01")
  DEFAULT_ORDER_TTL_SECONDS = 3600
  RECEIVE_TIME_BUFFER_SECONDS = 5
  MAX_RECEIVE_TIME_FUTURE_SECONDS = 100
  POST_SUBMIT_READBACK_ATTEMPTS = 12
  POST_SUBMIT_READBACK_DELAY_SECONDS = 0.25
  POST_SUBMIT_CLOSE_READBACK_ATTEMPTS = 12
  POST_SUBMIT_CLOSE_READBACK_DELAY_SECONDS = 0.25
  EXECUTE_BODY_SHAPE = "execute_place_orders_batch".freeze
  DEFAULT_MARGIN_MODE = "isolated".freeze
  DEFAULT_REQUESTED_LEVERAGE = BigDecimal("1")
  UI_EQUIVALENT_ISOLATED_CLOSE_APPENDIX = 2817
  DELTA_PROBE_CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_DELTA_PROBE_ORDERS".freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, venue: nil, http_get: nil, http_post: nil, signer_post: nil, now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @venue = venue || HedgeVenues::Nado.new(env: env, http_get: http_get)
    @http_get = http_get || method(:http_get)
    @http_post = http_post || method(:http_post)
    @signer_post = signer_post || method(:signer_post)
    @now = now
    @sleeper = sleeper
  end

  def preflight(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:)
    if action.to_s == "rebalance"
      plan = plan_rebalance(
        target_size_eth: short_size(current_position) + BigDecimal(size_eth.to_s),
        current_position: current_position,
        tolerance_eth: BigDecimal("0")
      )
      return close_reopen_preflight(position: position, plan: plan, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage) if plan[:action] == "isolated_full_close_then_reopen"
    end

    order = build_order_preview(position: position, action: action, size_eth: size_eth, max_slippage: max_slippage, current_position: current_position)
    blockers = live_blockers(
      position: position,
      action: action,
      size_eth: size_eth,
      current_position: current_position,
      confirmation: confirmation,
      order: order
    )
    {
      venue: "Nado",
      mode: @venue.live_mode_state,
      live_supported: true,
      live_enabled: @venue.live_enabled?,
      action: action,
      action_plan: action.to_s == "rebalance" ? plan_rebalance(target_size_eth: short_size(current_position) + BigDecimal(size_eth.to_s), current_position: current_position, tolerance_eth: BigDecimal("0")) : nil,
      target_hedge_size_eth: decimal_string(size_eth),
      rounded_order_size_eth: order.dig(:summary, :rounded_size_eth),
      estimated_notional_usd: order.dig(:summary, :estimated_notional_usd),
      intended_side: order.dig(:summary, :side),
      symbol: DEFAULT_SYMBOL,
      reduce_only_close_available: true,
      current_venue_position: serialize_position(current_position),
      current_venue_open_orders: "not_available",
      order_summary: sanitized_order_summary(order),
      max_slippage: max_slippage.to_s,
      submitted: false,
      manual_action_required: blockers.any?,
      next_action: blockers.any? ? "Resolve Nado live blockers before submitting." : "Submit through dashboard live action with exact Nado confirmation.",
      blockers: blockers,
      warnings: order.fetch(:warnings)
    }
  end

  def open_short(position:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute(position: position, action: "open", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation || !migration)
  end

  def close_short(position:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute(position: position, action: "close", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation || !migration)
  end

  def rebalance_short(position:, delta_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute_rebalance(position: position, delta_eth: BigDecimal(delta_eth.to_s), current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation || !migration)
  end

  def plan_rebalance(target_size_eth:, current_position:, tolerance_eth:)
    current_short = short_size(current_position)
    target_short = BigDecimal(target_size_eth.to_s)
    tolerance = BigDecimal(tolerance_eth.to_s)
    delta = target_short - current_short
    action = if current_position == :unavailable
      "blocked"
    elsif position_size(current_position).positive?
      "blocked"
    elsif delta.abs <= tolerance
      "no_op"
    elsif target_short.zero? && current_short.positive?
      "isolated_full_close"
    elsif delta.positive?
      "isolated_increase"
    elsif margin_mode(current_position) == "isolated" && isolated_decrease_strategy == "delta_reduce"
      "isolated_decrease"
    elsif margin_mode(current_position) == "isolated" && isolated_decrease_strategy == "close_reopen"
      "isolated_full_close_then_reopen"
    elsif delta.negative?
      "isolated_decrease"
    else
      "blocked"
    end

    {
      action: action,
      current_size_eth: decimal_string(current_short),
      target_size_eth: decimal_string(target_short),
      delta_eth: decimal_string(delta),
      tolerance_eth: decimal_string(tolerance),
      current_margin_mode: margin_mode(current_position),
      desired_margin_mode: desired_margin_mode,
      isolated_decrease_strategy: isolated_decrease_strategy,
      partial_isolated_reduce_supported: partial_isolated_reduce_supported?,
      partial_isolated_reduce_evidence: partial_isolated_reduce_evidence,
      blocked_reason: action == "blocked" ? blocked_plan_reason(current_position: current_position, delta: delta) : nil,
      strategy: action == "isolated_full_close_then_reopen" ? "full_close_then_reopen" : action
    }
  end

  def auto_rebalance_short(position:, delta_eth:, current_position:, max_slippage:)
    execute_rebalance(position: position, delta_eth: BigDecimal(delta_eth.to_s), current_position: current_position, confirmation: nil, max_slippage: max_slippage, require_confirmation: false)
  end

  def resume_reopen_after_close(position:, target_size_eth:, confirmation:, max_slippage:, require_confirmation: true)
    current_position = read_position
    blocker = "Nado resume reopen requires flat readback; current short is #{decimal_string(short_size(current_position))} ETH."
    plan = {
      action: "resume_reopen_after_delayed_flat",
      current_size_eth: decimal_string(short_size(current_position)),
      target_size_eth: decimal_string(target_size_eth),
      delta_eth: decimal_string(BigDecimal(target_size_eth.to_s) - short_size(current_position)),
      tolerance_eth: "0",
      current_margin_mode: margin_mode(current_position),
      desired_margin_mode: desired_margin_mode,
      partial_isolated_reduce_supported: false,
      strategy: "resume_reopen_after_close"
    }
    unless current_position.nil? || short_size(current_position).zero?
      return Result.new("blocked_before_submit", [ blocker ], [], {
        timestamp: @now.call.utc.iso8601,
        action: "resume_reopen_after_close",
        venue: "nado",
        position_id: position.id,
        action_plan: plan,
        pre_submit_readback: serialize_position(current_position),
        final_status: "blocked_before_submit",
        final_message: "Nado resume reopen requires flat readback.",
        manual_action_required: true,
        blockers: [ blocker ],
        warnings: []
      })
    end

    reopen_result = execute(
      position: position,
      action: "open",
      size_eth: target_size_eth,
      current_position: nil,
      confirmation: confirmation,
      max_slippage: max_slippage,
      require_confirmation: require_confirmation
    )
    receipt = reopen_result.receipt.merge(
      action: "resume_reopen_after_close",
      action_plan: plan,
      resume_after_delayed_flat: true
    )
    Result.new(reopen_result.status, reopen_result.blockers, reopen_result.warnings, receipt)
  end

  def build_delta_probe_preview(position:, direction:, size_eth:, current_position:, max_slippage:)
    normalized_direction = normalize_delta_probe_direction(direction)
    build_delta_probe_order_preview(
      position: position,
      direction: normalized_direction,
      size_eth: size_eth,
      max_slippage: max_slippage,
      current_position: current_position
    )
  end

  def delta_probe(position:, direction:, size_eth:, current_position:, confirmation:, max_slippage:, dry_run: true)
    normalized_direction = normalize_delta_probe_direction(direction)
    order = build_delta_probe_preview(
      position: position,
      direction: normalized_direction,
      size_eth: size_eth,
      current_position: current_position,
      max_slippage: max_slippage
    )
    blockers = dry_run ? order.fetch(:blockers) : delta_probe_live_blockers(position: position, confirmation: confirmation, order: order, current_position: current_position)
    return delta_probe_result("dry_run", blockers, order, position, normalized_direction, current_position, nil, nil, nil, dry_run: true) if dry_run
    return delta_probe_result("blocked_before_submit", blockers, order, position, normalized_direction, current_position, nil, nil, nil, dry_run: false) if blockers.any?

    signing = sign(order.fetch(:typed_data), order: order, action: "nado_isolated_delta_probe")
    unless signing[:status] == "signed"
      return delta_probe_result("failed_before_submit", [ signing[:reason] || "Nado signer did not return a signature" ], order, position, normalized_direction, current_position, nil, nil, nil, dry_run: false)
    end

    payload = submit_payload(order: order, signature: signing.fetch(:signature))
    response = post_execute(payload)
    parsed = parse_submit_response(response)
    expected_short = BigDecimal(order.dig(:summary, :expected_after_short_eth).to_s)
    readback_poll = parsed[:status] == "submitted" ? poll_post_submit_readback(action: "rebalance", expected_short: expected_short) : { attempts: [], position: nil, confirmed: false }
    post_position = readback_poll.fetch(:position)
    status = parsed[:status] == "submitted" && readback_poll[:confirmed] ? "submitted_and_confirmed" : parsed[:status] == "submitted" ? "submitted_but_readback_pending" : "failed_before_submit"
    delta_probe_result(status, [], order, position, normalized_direction, current_position, parsed, post_position, readback_poll, dry_run: false)
  rescue => e
    delta_probe_result("failed_before_submit", [ "#{e.class}: #{e.message}" ], order || {}, position, normalized_direction || direction, current_position, nil, nil, nil, dry_run: dry_run)
  end

  def round_trip_delta_probe(position:, size_eth:, current_position:, confirmation:, max_slippage:, dry_run: true)
    initial_position = current_position
    decrease = delta_probe(
      position: position,
      direction: "decrease",
      size_eth: size_eth,
      current_position: initial_position,
      confirmation: confirmation,
      max_slippage: max_slippage,
      dry_run: dry_run
    )
    if dry_run
      increase = nil
      if decrease.blockers.empty?
        after_decrease = synthetic_position_after_probe(current_position, decrease.receipt.dig(:payload_summary, :expected_after_short_eth))
        increase = delta_probe(
          position: position,
          direction: "increase",
          size_eth: size_eth,
          current_position: after_decrease,
          confirmation: confirmation,
          max_slippage: max_slippage,
          dry_run: true
        )
      end
      return round_trip_delta_probe_result(position: position, initial_position: initial_position, decrease_result: decrease, increase_result: increase, dry_run: true)
    end
    return round_trip_delta_probe_result(position: position, initial_position: initial_position, decrease_result: decrease, increase_result: nil, dry_run: dry_run) if decrease.status != "submitted_and_confirmed"

    after_decrease = read_position
    increase = delta_probe(
      position: position,
      direction: "increase",
      size_eth: size_eth,
      current_position: after_decrease,
      confirmation: confirmation,
      max_slippage: max_slippage,
      dry_run: false
    )
    round_trip_delta_probe_result(position: position, initial_position: initial_position, decrease_result: decrease, increase_result: increase, dry_run: false)
  end

  def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position: nil)
    if isolated_delta_reduce_order?(action: action, size_eth: size_eth, current_position: current_position)
      return build_delta_reduce_preview(position: position, size_eth: size_eth, max_slippage: max_slippage, current_position: current_position, probe: false)
    end

    side = order_side(action: action, size_eth: size_eth)
    reduce_only = reduce_only_order?(action: action, size_eth: size_eth)
    full_close = isolated_full_close?(action: action, current_position: current_position)
    order_size = full_close ? short_size(current_position) : order_size(size_eth)
    product = product_metadata
    price = order_price(position: position, side: side, max_slippage: max_slippage, product: product)
    rounded_price = round_price(price, side: side, product: product)
    rounded_size = round_size(order_size, product: product)
    amount_x18 = decimal_to_x18(rounded_size)
    amount_x18 = -amount_x18 if side == "sell"
    now = @now.call
    ui_equivalent_full_close = full_close && use_ui_equivalent_isolated_close?(current_position)
    margin = margin_plan(action: action, reduce_only: reduce_only, rounded_size: rounded_size, rounded_price: rounded_price, current_position: current_position, ui_equivalent_full_close: ui_equivalent_full_close)
    order_fields = nado_order_fields(
      side: side,
      reduce_only: reduce_only,
      price: rounded_price,
      amount_x18: amount_x18,
      product: product,
      now: now,
      isolated_margin_x6: margin[:isolated_margin_x6],
      sender: ui_equivalent_full_close ? nado_default_1_sender : subaccount,
      appendix_override: ui_equivalent_full_close ? UI_EQUIVALENT_ISOLATED_CLOSE_APPENDIX : nil,
      expiration_milliseconds: ui_equivalent_full_close
    )
    typed_data = product[:product_id] && product[:chain_id] ? typed_data(product: product, order_fields: order_fields) : nil
    timing = order_timing_summary(order_fields, local_time: now)

    {
      ok: product.fetch(:blockers).empty? && timing.fetch(:blockers).empty? && rounded_size.positive? && rounded_price.positive? && typed_data.present?,
      summary: {
        venue: "Nado",
        symbol: DEFAULT_SYMBOL,
        action: action,
        side: side,
        reduce_only: reduce_only,
        full_close: full_close,
        close_strategy: ui_equivalent_full_close ? "ui_market_close_position_equivalent" : nil,
        current_short_size_eth: full_close ? decimal_string(short_size(current_position)) : nil,
        product_id: product[:product_id],
        rounded_size_eth: decimal_string(rounded_size),
        rounded_price: decimal_string(rounded_price),
        estimated_notional_usd: decimal_string(rounded_size * rounded_price),
        amount_x18: amount_x18.to_s,
        sender: order_fields[:sender],
        current_position_subaccount: isolated_position_subaccount(current_position),
        order_sender_kind: ui_equivalent_full_close ? "default_1" : "configured_subaccount",
        appendix: order_fields[:appendix],
        order_type: "ioc",
        isolated: appendix_isolated?(order_fields[:appendix].to_i),
        margin_mode: margin[:margin_mode],
        requested_leverage: margin[:requested_leverage]&.to_s("F"),
        isolated_margin_usd: margin[:isolated_margin_usd]&.to_s("F"),
        isolated_margin_x6: margin[:isolated_margin_x6],
        current_position_isolated_margin_x6: isolated_margin_x6_from_position(current_position),
        appendix_decoded: decode_appendix(order_fields[:appendix]),
        recv_time_ms: timing.dig(:diagnostics, :recv_time_ms),
        seconds_until_recv_time: timing.dig(:diagnostics, :seconds_until_recv_time),
        order_expiration: timing.dig(:diagnostics, :order_expiration)
      },
      timing: timing.fetch(:diagnostics),
      typed_data: typed_data,
      order_fields: order_fields,
      product: product,
      blockers: product.fetch(:blockers) + timing.fetch(:blockers) + margin.fetch(:blockers) + full_close_size_blockers(full_close: full_close, order_size: order_size, rounded_size: rounded_size),
      warnings: product.fetch(:warnings)
    }
  end

  def read_position
    safe_read_position
  end

  private

  def normalize_delta_probe_direction(direction)
    normalized = direction.to_s.downcase
    return normalized if normalized.in?(%w[decrease increase])

    raise ArgumentError, "direction must be decrease or increase"
  end

  def build_delta_probe_order_preview(position:, direction:, size_eth:, max_slippage:, current_position:)
    if direction == "increase"
      order = build_order_preview(position: position, action: "rebalance", size_eth: size_eth, max_slippage: max_slippage, current_position: current_position)
      return annotate_delta_probe_order(order: order, direction: direction, current_position: current_position)
    end

    build_delta_reduce_preview(position: position, size_eth: size_eth, max_slippage: max_slippage, current_position: current_position, probe: true)
  end

  def build_delta_reduce_preview(position:, size_eth:, max_slippage:, current_position:, probe:)
    product = product_metadata
    order_size = order_size(size_eth)
    price = order_price(position: position, side: "buy", max_slippage: max_slippage, product: product)
    rounded_price = round_price(price, side: "buy", product: product)
    rounded_size = round_size(order_size, product: product)
    amount_x18 = decimal_to_x18(rounded_size)
    now = @now.call
    order_fields = nado_order_fields(
      side: "buy",
      reduce_only: true,
      price: rounded_price,
      amount_x18: amount_x18,
      product: product,
      now: now,
      isolated_margin_x6: nil,
      sender: nado_default_1_sender,
      appendix_override: UI_EQUIVALENT_ISOLATED_CLOSE_APPENDIX,
      expiration_milliseconds: true
    )
    typed_data = product[:product_id] && product[:chain_id] ? typed_data(product: product, order_fields: order_fields) : nil
    timing = order_timing_summary(order_fields, local_time: now)
    before_short = short_size(current_position)
    expected_after = before_short - rounded_size
    blockers = product.fetch(:blockers) + timing.fetch(:blockers) + delta_probe_position_blockers(direction: "decrease", current_position: current_position, rounded_size: rounded_size)
    warnings = product.fetch(:warnings) + [ delta_reduce_warning(probe: probe) ]

    {
      ok: blockers.empty? && rounded_size.positive? && rounded_price.positive? && typed_data.present?,
      summary: {
        venue: "Nado",
        symbol: DEFAULT_SYMBOL,
        action: probe ? "isolated_delta_probe" : "rebalance",
        probe_direction: probe ? "decrease" : nil,
        delta_probe: probe,
        delta_only: true,
        partial_reduce_candidate: true,
        close_reopen: false,
        full_close: false,
        side: "buy",
        reduce_only: true,
        product_id: product[:product_id],
        rounded_size_eth: decimal_string(rounded_size),
        rounded_price: decimal_string(rounded_price),
        estimated_notional_usd: decimal_string(rounded_size * rounded_price),
        amount_x18: amount_x18.to_s,
        amount_sign: "positive",
        sender: order_fields[:sender],
        current_position_subaccount: isolated_position_subaccount(current_position),
        order_sender_kind: "default_1",
        appendix: order_fields[:appendix],
        order_type: "ioc",
        isolated: appendix_isolated?(order_fields[:appendix].to_i),
        margin_mode: probe ? "isolated_delta_probe_reduce_only" : "isolated_delta_reduce_only",
        requested_leverage: nil,
        isolated_margin_usd: position_value(current_position, :isolated_margin_usd)&.to_s,
        isolated_margin_x6: nil,
        current_position_isolated_margin_x6: isolated_margin_x6_from_position(current_position),
        isolated_margin_handling: "omitted from appendix high bits; UI-equivalent isolated reduce-only low bits only",
        appendix_decoded: decode_appendix(order_fields[:appendix]),
        recv_time_ms: timing.dig(:diagnostics, :recv_time_ms),
        seconds_until_recv_time: timing.dig(:diagnostics, :seconds_until_recv_time),
        order_expiration: timing.dig(:diagnostics, :order_expiration),
        before_short_eth: decimal_string(before_short),
        expected_after_short_eth: decimal_string(expected_after)
      },
      timing: timing.fetch(:diagnostics),
      typed_data: typed_data,
      order_fields: order_fields,
      product: product,
      blockers: blockers,
      warnings: warnings
    }
  end

  def delta_reduce_warning(probe:)
    return "Nado isolated delta decrease probe uses UI-equivalent isolated reduce-only low bits (appendix=2817) with delta size; production auto-rebalance still uses close_reopen until live proof exists." if probe

    "Nado isolated delta decrease uses the production-proven reduce-only buy payload: default_1 sender, appendix=2817, place_orders batch, no isolated margin high bits."
  end

  def annotate_delta_probe_order(order:, direction:, current_position:)
    before_short = short_size(current_position)
    rounded_size = BigDecimal(order.dig(:summary, :rounded_size_eth).to_s)
    expected_after = before_short + rounded_size
    summary = order.fetch(:summary).merge(
      action: "isolated_delta_probe",
      probe_direction: direction,
      delta_probe: true,
      close_reopen: false,
      full_close: false,
      partial_reduce_candidate: false,
      amount_sign: "negative",
      before_short_eth: decimal_string(before_short),
      expected_after_short_eth: decimal_string(expected_after),
      isolated_margin_handling: "isolated 1x margin encoded in appendix high bits"
    )
    blockers = order.fetch(:blockers) + delta_probe_position_blockers(direction: direction, current_position: current_position, rounded_size: rounded_size)
    warnings = order.fetch(:warnings) + [
      "Nado isolated delta increase probe uses the same isolated 1x sell semantics as the working Nado open/increase path."
    ]
    order.merge(summary: summary, blockers: blockers.uniq, warnings: warnings.uniq)
  end

  def delta_probe_position_blockers(direction:, current_position:, rounded_size:)
    blockers = []
    blockers << "current Nado readback is unavailable" if current_position == :unavailable
    blockers << "current Nado position must be an isolated short" unless isolated_short_position?(current_position)
    blockers << "delta probe size must be positive after rounding" unless rounded_size.positive?
    blockers << "decrease delta must be smaller than current isolated short" if direction == "decrease" && short_size(current_position) <= rounded_size
    blockers
  end

  def isolated_short_position?(position)
    position.present? && position != :unavailable && margin_mode(position) == "isolated" && short_size(position).positive?
  end

  def delta_probe_live_blockers(position:, confirmation:, order:, current_position:)
    blockers = []
    blockers << "AERODROME_NADO_DELTA_PROBE_ENABLED must be true" unless delta_probe_enabled?
    blockers << "submitted confirmation must equal #{DELTA_PROBE_CONFIRMATION}" unless confirmation.to_s == DELTA_PROBE_CONFIRMATION
    blockers << "position must be active" unless position.active?
    blockers << "active hedge-ready Mellow Autopilot position is required" unless position.mellow_autopilot? && position.hedge_ready?
    blockers << "Nado signer service is not configured" if signer_url.blank?
    blockers << "Nado signer service is unavailable" if signer_url.present? && !signer_available?
    blockers << "Nado submit URL is not configured" if submit_base_url.blank?
    blockers << "NADO_ACCOUNT_SUBACCOUNT or derivable NADO_ACCOUNT_ADDRESS is required" if subaccount.blank?
    blockers.concat(delta_probe_position_blockers(direction: order.dig(:summary, :probe_direction), current_position: current_position, rounded_size: BigDecimal(order.dig(:summary, :rounded_size_eth).to_s)))
    blockers.concat(order.fetch(:blockers, []))
    blockers.uniq
  end

  def delta_probe_enabled?
    ActiveModel::Type::Boolean.new.cast(@env["AERODROME_NADO_DELTA_PROBE_ENABLED"])
  end

  def delta_probe_result(status, blockers, order, position, direction, pre_position, submit_result, post_position, readback_poll, dry_run:)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "isolated_delta_probe",
      venue: "nado",
      direction: direction,
      dry_run: dry_run,
      position_id: position.id,
      source: position.position_source,
      source_external_id: position.external_id,
      before_readback: serialize_position(pre_position),
      delta_size_eth: order.dig(:summary, :rounded_size_eth),
      expected_after_short_eth: order.dig(:summary, :expected_after_short_eth),
      payload_summary: sanitized_order_summary(order),
      submit_response_classification: submit_result,
      exchange_order_id: submit_result&.dig(:exchange_order_id),
      poll_attempts: readback_poll&.fetch(:attempts, []),
      after_readback: serialize_position(post_position),
      final_status: status,
      final_message: delta_probe_final_message(status, submit_result, dry_run: dry_run),
      manual_action_required: manual_action_required?(status),
      blockers: blockers,
      warnings: order.fetch(:warnings, [])
    }
    Result.new(status, blockers, order.fetch(:warnings, []), receipt)
  end

  def round_trip_delta_probe_result(position:, initial_position:, decrease_result:, increase_result:, dry_run:)
    final_position = increase_result&.receipt&.dig(:after_readback) || decrease_result.receipt[:after_readback]
    status = if dry_run
      "dry_run"
    elsif decrease_result.status != "submitted_and_confirmed"
      decrease_result.status
    else
      increase_result&.status || "failed_before_submit"
    end
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "isolated_delta_probe_round_trip",
      venue: "nado",
      dry_run: dry_run,
      position_id: position.id,
      before_readback: serialize_position(initial_position),
      decrease_leg: decrease_result.receipt,
      increase_leg: increase_result&.receipt,
      after_readback: final_position,
      final_status: status,
      final_message: round_trip_delta_probe_message(decrease_result: decrease_result, increase_result: increase_result, dry_run: dry_run),
      manual_action_required: manual_action_required?(status),
      blockers: decrease_result.blockers + (increase_result&.blockers || []),
      warnings: decrease_result.warnings + (increase_result&.warnings || [])
    }
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def synthetic_position_after_probe(position, expected_short_eth)
    return position unless position && position != :unavailable && expected_short_eth.present?

    updated = position.deep_dup
    expected = BigDecimal(expected_short_eth.to_s)
    updated[:size] = -expected
    updated[:short_size] = expected
    updated["size"] = -expected if updated.key?("size")
    updated["short_size"] = expected if updated.key?("short_size")
    updated
  end

  def delta_probe_final_message(status, submit_result, dry_run:)
    return "Nado isolated delta probe dry-run only; no signature or order submission." if dry_run
    return "Nado isolated delta probe submitted and confirmed by readback." if status == "submitted_and_confirmed"
    return "Nado isolated delta probe submit accepted but readback did not confirm expected delta." if status.to_s.start_with?("submitted_but")

    submit_result&.dig(:message) || status
  end

  def round_trip_delta_probe_message(decrease_result:, increase_result:, dry_run:)
    return "Nado isolated delta round-trip dry-run only; no signature or order submission." if dry_run
    return "Nado isolated delta decrease did not confirm; increase leg was not submitted." unless decrease_result.status == "submitted_and_confirmed"
    return "Nado isolated delta round-trip completed and confirmed." if increase_result&.status == "submitted_and_confirmed"

    increase_result&.receipt&.dig(:final_message) || "Nado isolated delta increase leg did not confirm."
  end

  def execute_rebalance(position:, delta_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true)
    target_size = short_size(current_position) + BigDecimal(delta_eth.to_s)
    plan = plan_rebalance(target_size_eth: target_size, current_position: current_position, tolerance_eth: BigDecimal("0"))
    return no_op_result(position: position, plan: plan, current_position: current_position) if plan[:action] == "no_op"
    return blocked_plan_result(position: position, plan: plan, current_position: current_position) if plan[:action] == "blocked"
    return execute_close_then_reopen(position: position, target_size: target_size, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation, plan: plan) if plan[:action] == "isolated_full_close_then_reopen"
    return execute(position: position, action: "close", size_eth: short_size(current_position), current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation) if plan[:action] == "isolated_full_close"

    execute(
      position: position,
      action: "rebalance",
      size_eth: delta_eth,
      current_position: current_position,
      confirmation: confirmation,
      max_slippage: max_slippage,
      require_confirmation: require_confirmation
    )
  end

  def close_reopen_preflight(position:, plan:, current_position:, confirmation:, max_slippage:)
    close_order = build_order_preview(position: position, action: "close", size_eth: short_size(current_position), max_slippage: max_slippage, current_position: current_position)
    close_blockers = live_blockers(position: position, action: "close", size_eth: short_size(current_position), current_position: current_position, confirmation: confirmation, order: close_order)
    reopen_order = nil
    reopen_blockers = []
    target_size = BigDecimal(plan.fetch(:target_size_eth))
    if close_blockers.empty? && target_size.positive?
      reopen_order = build_order_preview(position: position, action: "open", size_eth: target_size, max_slippage: max_slippage, current_position: nil)
      reopen_blockers = live_blockers(position: position, action: "open", size_eth: target_size, current_position: nil, confirmation: confirmation, order: reopen_order)
    end

    {
      venue: "Nado",
      mode: @venue.live_mode_state,
      live_supported: true,
      live_enabled: @venue.live_enabled?,
      action: "rebalance",
      action_plan: plan,
      target_hedge_size_eth: plan.fetch(:target_size_eth),
      rounded_order_size_eth: reopen_order&.dig(:summary, :rounded_size_eth),
      estimated_notional_usd: reopen_order&.dig(:summary, :estimated_notional_usd),
      intended_side: "close_then_sell",
      symbol: DEFAULT_SYMBOL,
      reduce_only_close_available: true,
      current_venue_position: serialize_position(current_position),
      current_venue_open_orders: "not_available",
      order_summary: {
        strategy: "full_close_then_reopen",
        close_leg: sanitized_order_summary(close_order),
        reopen_leg: reopen_order ? sanitized_order_summary(reopen_order) : nil
      },
      max_slippage: max_slippage.to_s,
      submitted: false,
      manual_action_required: (close_blockers + reopen_blockers).any?,
      next_action: (close_blockers + reopen_blockers).any? ? "Resolve Nado live blockers before submitting." : "Nado isolated rebalance will close current isolated short and reopen target size.",
      blockers: (close_blockers + reopen_blockers).uniq,
      warnings: (close_order.fetch(:warnings) + (reopen_order&.fetch(:warnings) || [])).uniq
    }
  end

  def execute_close_then_reopen(position:, target_size:, current_position:, confirmation:, max_slippage:, require_confirmation:, plan:)
    close_result = execute(
      position: position,
      action: "close",
      size_eth: short_size(current_position),
      current_position: current_position,
      confirmation: confirmation,
      max_slippage: max_slippage,
      require_confirmation: require_confirmation
    )
    return combined_rebalance_result(position: position, plan: plan, current_position: current_position, close_result: close_result, reopen_result: nil, status: close_result.status) unless close_result.status == "submitted_and_confirmed"

    reopen_result = execute(
      position: position,
      action: "open",
      size_eth: target_size,
      current_position: nil,
      confirmation: confirmation,
      max_slippage: max_slippage,
      require_confirmation: require_confirmation
    )
    combined_rebalance_result(position: position, plan: plan, current_position: current_position, close_result: close_result, reopen_result: reopen_result, status: reopen_result.status)
  end

  def combined_rebalance_result(position:, plan:, current_position:, close_result:, reopen_result:, status:)
    final_readback = reopen_result&.receipt&.dig(:post_submit_readback) || close_result.receipt[:post_submit_readback]
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "rebalance",
      venue: "nado",
      position_id: position.id,
      source: position.position_source,
      source_external_id: position.external_id,
      action_plan: plan,
      full_close_reopen: true,
      current_size_eth: plan[:current_size_eth],
      target_size_eth: plan[:target_size_eth],
      delta_eth: plan[:delta_eth],
      pre_submit_readback: serialize_position(current_position),
      close_leg: close_result.receipt,
      reopen_leg: reopen_result&.receipt,
      post_submit_readback: final_readback,
      final_status: status,
      final_message: combined_rebalance_message(close_result: close_result, reopen_result: reopen_result),
      exchange_order_id: [ close_result.receipt[:exchange_order_id], reopen_result&.receipt&.dig(:exchange_order_id) ].compact.join(",").presence,
      manual_action_required: manual_action_required?(status),
      next_manual_instruction: manual_instruction(status),
      blockers: close_result.blockers + (reopen_result&.blockers || []),
      warnings: close_result.warnings + (reopen_result&.warnings || [])
    }
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def combined_rebalance_message(close_result:, reopen_result:)
    return "Nado close leg did not confirm flat; reopen was not submitted." unless close_result.status == "submitted_and_confirmed"
    return reopen_result.receipt[:final_message] if reopen_result

    close_result.receipt[:final_message]
  end

  def no_op_result(position:, plan:, current_position:)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "rebalance",
      venue: "nado",
      position_id: position.id,
      source: position.position_source,
      source_external_id: position.external_id,
      action_plan: plan,
      submitted: false,
      pre_submit_readback: serialize_position(current_position),
      post_submit_readback: serialize_position(current_position),
      final_status: "no_op",
      final_message: "Nado isolated short is within tolerance; no order submitted.",
      manual_action_required: false,
      blockers: [],
      warnings: []
    }
    Result.new("no_op", [], [], receipt)
  end

  def blocked_plan_result(position:, plan:, current_position:)
    blocker = plan[:blocked_reason] || "Nado isolated planner blocked"
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "rebalance",
      venue: "nado",
      position_id: position.id,
      source: position.position_source,
      source_external_id: position.external_id,
      action_plan: plan,
      submitted: false,
      pre_submit_readback: serialize_position(current_position),
      post_submit_readback: serialize_position(current_position),
      final_status: "blocked_before_submit",
      final_message: blocker,
      manual_action_required: true,
      blockers: [ blocker ],
      warnings: []
    }
    Result.new("blocked_before_submit", [ blocker ], [], receipt)
  end

  def execute(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true)
    order = build_order_preview(position: position, action: action, size_eth: size_eth, max_slippage: max_slippage, current_position: current_position)
    blockers = live_blockers(position: position, action: action, size_eth: size_eth, current_position: current_position, confirmation: confirmation, order: order, require_confirmation: require_confirmation)
    return result("blocked_before_submit", blockers, order, position, action, current_position, nil, nil, nil) if blockers.any?

    signing = sign(order.fetch(:typed_data), order: order, action: action)
    unless signing[:status] == "signed"
      return result("failed_before_submit", [ signing[:reason] || "Nado signer did not return a signature" ], order, position, action, current_position, nil, nil, nil)
    end

    payload = submit_payload(order: order, signature: signing.fetch(:signature))
    response = post_execute(payload)
    parsed = parse_submit_response(response)
    expected_short = expected_short_after(action: action, size_eth: size_eth, current_position: current_position)
    readback_poll = parsed[:status] == "submitted" ? poll_post_submit_readback(action: action, expected_short: expected_short) : { attempts: [], position: nil }
    post_position = readback_poll.fetch(:position)
    status = final_status(parsed, post_position: post_position, action: action, expected_short: expected_short, confirmed: readback_poll[:confirmed])
    result(status, [], order, position, action, current_position, parsed, post_position, readback_poll)
  rescue => e
    result("failed_before_submit", [ "#{e.class}: #{e.message}" ], order || {}, position, action, current_position, nil, nil, nil)
  end

  def reconcile_pending_result(result)
    return result unless result.status.to_s.start_with?("submitted_but")

    receipt = result.receipt
    expected_short = pending_expected_short(receipt)
    return result unless expected_short

    current_position = read_position
    return result unless expected_short_confirmed?(current_short: short_size(current_position), expected_short: expected_short)

    updated_receipt = receipt.merge(
      post_submit_readback: serialize_position(current_position),
      after_readback: serialize_position(current_position),
      final_status: "submitted_and_confirmed",
      final_message: "Nado submit confirmed by later readback.",
      reconciled_after_pending: true,
      manual_action_required: false,
      next_manual_instruction: nil
    )
    Result.new("submitted_and_confirmed", [], result.warnings, updated_receipt)
  rescue
    result
  end
  public :reconcile_pending_result

  def live_blockers(position:, action:, size_eth:, current_position:, confirmation:, order:, require_confirmation: true)
    requested_order_size = order_size(size_eth)
    preview_order_size = decimal_or_nil(order.dig(:summary, :rounded_size_eth)) || requested_order_size
    blockers = []
    blockers << "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true" unless @venue.live_flag_enabled?
    blockers << "submitted confirmation must equal #{@venue.live_confirmation_phrase}" if require_confirmation && !(confirmation.to_s == @venue.live_confirmation_phrase && @venue.live_confirmation_phrase.present?)
    blockers << "position must be active" unless position.active?
    blockers << "active hedge-ready Mellow Autopilot position is required" unless position.mellow_autopilot? && position.hedge_ready?
    blockers << "target hedge size must be positive" if action.to_s == "open" && !requested_order_size.positive?
    blockers << "rebalance delta must be non-zero" if action.to_s == "rebalance" && requested_order_size.zero?
    blockers << "close size must be positive" if action.to_s == "close" && !preview_order_size.positive?
    blockers << "Nado signer service is not configured" if signer_url.blank?
    blockers << "Nado signer service is unavailable" if signer_url.present? && !signer_available?
    blockers << "Nado submit URL is not configured" if submit_base_url.blank?
    blockers << "NADO_ACCOUNT_SUBACCOUNT or derivable NADO_ACCOUNT_ADDRESS is required" if subaccount.blank?
    blockers << "Nado readback is unavailable" if current_position == :unavailable
    blockers << "Nado raw positions are present but parser could not normalize ETH-PERP; refusing to submit another order." if current_position.nil? && @venue.respond_to?(:raw_positions_present_but_unnormalized?) && @venue.raw_positions_present_but_unnormalized?
    blockers << "current Nado position is long; manual action required" if position_size(current_position).positive?
    blockers << "Existing Nado position is cross-margin but desired mode is isolated; close existing position before reopening." if isolated_increase?(action, size_eth) && margin_mode(current_position) == "cross"
    blockers << "Existing Nado position margin mode is unknown; close existing position before reopening isolated." if isolated_increase?(action, size_eth) && margin_mode(current_position) == "unknown"
    blockers << "current Nado position already exists; use close/readback before opening" if action.to_s == "open" && position_size(current_position).nonzero?
    blockers << "no current Nado short to close" if action.to_s == "close" && short_size(current_position).zero?
    blockers << "no current Nado short to reduce" if action.to_s == "rebalance" && BigDecimal(size_eth.to_s).negative? && short_size(current_position).zero?
    blockers << isolated_partial_reduce_blocker if isolated_partial_reduce?(action: action, size_eth: size_eth, order_size: preview_order_size, current_position: current_position) && !partial_isolated_reduce_supported?
    blockers.concat(order.fetch(:blockers, []))
    blockers.uniq
  end

  def result(status, blockers, order, position, action, pre_position, submit_result, post_position, readback_poll)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: action,
      venue: "nado",
      position_id: position.id,
      source: position.position_source,
      source_external_id: position.external_id,
      action_plan: nado_execution_action_plan(action: action, pre_position: pre_position, order: order),
      target_size_eth: order.dig(:summary, :rounded_size_eth),
      rounded_size_eth: order.dig(:summary, :rounded_size_eth),
      estimated_notional_usd: order.dig(:summary, :estimated_notional_usd),
      pre_submit_readback: serialize_position(pre_position),
      submitted_order_summary: sanitized_order_summary(order),
      submit_response_classification: submit_result,
      raw_submit_response_summary: submit_result&.dig(:response_summary),
      exchange_order_id: submit_result&.dig(:exchange_order_id),
      post_submit_readback_poll_attempts: readback_poll&.fetch(:attempts, []),
      post_submit_readback: serialize_position(post_position),
      final_status: status,
      final_message: final_message(status, submit_result),
      manual_action_required: manual_action_required?(status),
      next_manual_instruction: manual_instruction(status),
      blockers: blockers,
      warnings: order.fetch(:warnings, [])
    }
    Result.new(status, blockers, order.fetch(:warnings, []), receipt)
  end

  def nado_execution_action_plan(action:, pre_position:, order:)
    return nil unless action.to_s == "rebalance"

    current_short = short_size(pre_position)
    rounded_size = BigDecimal(order.dig(:summary, :rounded_size_eth).to_s)
    delta = order.dig(:summary, :side).to_s == "buy" ? -rounded_size : rounded_size
    {
      action: delta.negative? ? "isolated_decrease" : "isolated_increase",
      strategy: order.dig(:summary, :delta_only) ? "delta_only" : "isolated_increase",
      current_size_eth: decimal_string(current_short),
      target_size_eth: decimal_string(current_short + delta),
      delta_eth: decimal_string(delta),
      expected_after_short_eth: decimal_string(current_short + delta),
      partial_isolated_reduce_supported: partial_isolated_reduce_supported?,
      payload: delta.negative? ? "ui_equivalent_delta_reduce_appendix_2817" : "isolated_1x_increase"
    }
  rescue ArgumentError
    nil
  end

  def pending_expected_short(receipt)
    raw = receipt[:expected_after_short_eth] ||
      receipt.dig(:action_plan, :expected_after_short_eth) ||
      receipt.dig(:submitted_order_summary, :expected_after_short_eth)
    return BigDecimal(raw.to_s) if raw.present?

    pre = receipt[:pre_submit_readback] || receipt[:before_readback]
    delta = receipt.dig(:action_plan, :delta_eth)
    return nil unless pre && delta

    short_size(pre) + BigDecimal(delta.to_s)
  rescue ArgumentError
    nil
  end

  def product_metadata
    return @product_metadata if defined?(@product_metadata)

    configured = configured_product_metadata
    return @product_metadata = configured if configured

    product = resolve_product_from_gateway
    domain = resolve_domain(product[:product_id])
    @product_metadata = product.merge(domain).then do |merged|
      product_hash(
        product_id: merged[:product_id],
        chain_id: merged[:chain_id],
        price_increment_x18: merged[:price_increment_x18],
        size_increment_x18: merged[:size_increment_x18],
        market_price: merged[:market_price],
        source: merged[:source],
        blockers: product.fetch(:blockers, [])
      )
    end
  end

  def configured_product_metadata
    raw = @env["NADO_ETH_PERP_PRODUCT_METADATA_JSON"].presence
    return nil unless raw

    data = JSON.parse(raw).with_indifferent_access
    product_id = positive_integer(data[:product_id] || data[:productId])
    chain_id = positive_integer(data[:chain_id] || data[:chainId] || @env["NADO_EIP712_CHAIN_ID"])
    price_increment_x18 = positive_integer(data[:price_increment_x18] || data[:priceIncrementX18])
    size_increment_x18 = positive_integer(data[:size_increment] || data[:sizeIncrement] || data[:size_increment_x18])
    product_hash(
      product_id: product_id,
      chain_id: chain_id,
      price_increment_x18: price_increment_x18,
      size_increment_x18: size_increment_x18,
      market_price: decimal_or_nil(data[:market_price] || data[:marketPrice]),
      source: "configured NADO_ETH_PERP_PRODUCT_METADATA_JSON"
    )
  rescue JSON::ParserError
    product_hash(source: "configured NADO_ETH_PERP_PRODUCT_METADATA_JSON", blockers: [ "NADO_ETH_PERP_PRODUCT_METADATA_JSON is invalid JSON" ])
  end

  def resolve_product_from_gateway
    return product_hash(blockers: [ "NADO_GATEWAY_QUERY_BASE_URL or NADO_API_BASE_URL is required for Nado product metadata" ]) if query_base_url.blank?

    symbols = get_query(type: "symbols", product_type: "perp")
    all_products = get_query(type: "all_products")
    candidates = response_rows(symbols).select { |row| nado_eth_perp_candidate?(row) }
    return product_hash(blockers: [ "Nado ETH-PERP product metadata missing" ]) if candidates.empty?
    return product_hash(blockers: [ "Nado ETH-PERP product metadata ambiguous" ]) if candidates.size > 1

    symbol_row = candidates.first
    product_id = positive_integer(symbol_row["product_id"] || symbol_row["productId"])
    product_row = response_rows(all_products).find { |row| positive_integer(row["product_id"] || row["productId"]) == product_id } || {}
    product_hash(
      product_id: product_id,
      price_increment_x18: positive_integer(product_row["price_increment_x18"] || product_row["priceIncrementX18"] || product_row.dig("book_info", "price_increment_x18")),
      size_increment_x18: positive_integer(product_row["size_increment"] || product_row["sizeIncrement"] || product_row.dig("book_info", "size_increment")),
      market_price: resolve_market_price(product_id),
      source: "GET /query?type=symbols + GET /query?type=all_products"
    )
  rescue => e
    product_hash(blockers: [ "Nado product metadata unavailable: #{e.class}: #{e.message}" ])
  end

  def resolve_domain(product_id)
    chain_id = positive_integer(@env["NADO_EIP712_CHAIN_ID"])
    if chain_id.nil? && query_base_url.present?
      contracts = get_query(type: "contracts")
      data = contracts["data"].is_a?(Hash) ? contracts["data"] : contracts
      chain_id = positive_integer(data["chain_id"] || data["chainId"])
    end
    { chain_id: chain_id, domain_source: chain_id ? "configured/query chain_id" : nil }
  rescue
    { chain_id: nil, domain_source: nil }
  end

  def product_hash(product_id: nil, chain_id: nil, price_increment_x18: nil, size_increment_x18: nil, market_price: nil, source: nil, blockers: [])
    blockers = blockers.dup
    blockers << "Nado ETH-PERP product_id is unavailable" unless product_id
    blockers << "Nado EIP-712 chain_id is unavailable" unless chain_id
    blockers << "Nado price_increment_x18 is unavailable" unless price_increment_x18
    blockers << "Nado size_increment is unavailable" unless size_increment_x18
    {
      product_id: product_id,
      chain_id: chain_id,
      price_increment_x18: price_increment_x18 || 1_000_000_000_000_000,
      size_increment_x18: size_increment_x18 || fallback_size_increment_x18,
      market_price: market_price,
      source: source,
      blockers: blockers,
      warnings: [ "Nado order builder mirrors perp-hedge-research-bot NadoExecutionAdapter: EIP-712 Order, IOC appendix, x18 price/amount rounding." ]
    }
  end

  def order_price(position:, side:, max_slippage:, product:)
    base = product[:market_price] || position_eth_price(position)
    slippage = BigDecimal((max_slippage.presence || DEFAULT_MAX_SLIPPAGE).to_s)
    side == "buy" ? base * (1 + slippage) : base * (1 - slippage)
  end

  def position_eth_price(position)
    if position.mellow_autopilot? && position.mellow_weth_exposure&.positive? && position.mellow_current_value_usd
      usdc = position.mellow_usdc_exposure || BigDecimal("0")
      return (position.mellow_current_value_usd - usdc) / position.mellow_weth_exposure
    end

    BigDecimal(position.asset0_price_usd.to_s)
  end

  def round_price(price, side:, product:)
    increment = BigDecimal(product[:price_increment_x18].to_s) / BigDecimal(10**18)
    ratio = BigDecimal(price.to_s) / increment
    ticks = side == "buy" ? ratio.ceil : ratio.floor
    ticks * increment
  end

  def fallback_size_increment_x18
    decimal_to_x18(@env["NADO_SIZE_INCREMENT"].presence || "0.001")
  rescue ArgumentError
    1_000_000_000_000_000
  end

  def round_size(size_eth, product:)
    increment = BigDecimal(product[:size_increment_x18].to_s) / BigDecimal(10**18)
    (BigDecimal(size_eth.to_s) / increment).floor * increment
  end

  def product_size_increment
    BigDecimal(product_metadata[:size_increment_x18].to_s) / BigDecimal(10**18)
  rescue
    BigDecimal("0.001")
  end

  def nado_order_fields(side:, reduce_only:, price:, amount_x18:, product:, now:, isolated_margin_x6:, sender:, appendix_override: nil, expiration_milliseconds: false)
    expiration = now.to_i + DEFAULT_ORDER_TTL_SECONDS
    expiration = ((now.to_f + DEFAULT_ORDER_TTL_SECONDS) * 1000).to_i if expiration_milliseconds
    {
      sender: sender,
      priceX18: decimal_to_x18(price).to_s,
      amount: amount_x18.to_s,
      expiration: expiration.to_s,
      nonce: nado_receive_time_nonce(seed: "#{side}:#{amount_x18}:#{now.to_f}", now: now).to_s,
      appendix: (appendix_override || build_appendix(reduce_only: reduce_only, isolated_margin_x6: isolated_margin_x6)).to_s
    }
  end

  def typed_data(product:, order_fields:)
    {
      types: {
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" }
        ],
        Order: [
          { name: "sender", type: "bytes32" },
          { name: "priceX18", type: "int128" },
          { name: "amount", type: "int128" },
          { name: "expiration", type: "uint64" },
          { name: "nonce", type: "uint64" },
          { name: "appendix", type: "uint128" }
        ]
      },
      primaryType: "Order",
      domain: {
        name: "Nado",
        version: "0.0.1",
        chainId: product.fetch(:chain_id),
        verifyingContract: verifying_contract(product.fetch(:product_id))
      },
      message: order_fields
    }
  end

  def sign(typed_data, order:, action:)
    response = @signer_post.call(URI.join(signer_url.end_with?("/") ? signer_url : "#{signer_url}/", "sign/eip712"), {
      exchange: "Nado",
      action: "place_order",
      signing_standard: "eip712",
      canonical_symbol: "ETH-PERP",
      exchange_symbol: "ETH-PERP",
      side: order.dig(:summary, :side),
      size_base: order.dig(:summary, :rounded_size_eth),
      notional_usd: order.dig(:summary, :estimated_notional_usd),
      order_type: "protected_taker",
      price: order.dig(:summary, :rounded_price),
      reduce_only: order.dig(:summary, :reduce_only),
      subaccount_id: order.dig(:summary, :sender) || subaccount,
      typed_data: typed_data,
      typed_data_hash: typed_data_hash(typed_data),
      expected_signer_address: @env["NADO_LINKED_SIGNER_ADDRESS"],
      forbidden_signer_address: @env["NADO_ACCOUNT_ADDRESS"],
      client_request_id: "delta-neutral-nado-#{SecureRandom.hex(8)}",
      payload_preview: sanitized_order_summary(order)
    })
    data = response.is_a?(Hash) ? response.with_indifferent_access : {}
    return { status: data[:status], signature: data[:signature], signer_id: data[:signer_id] } if data[:status] == "signed" && data[:signature].present?

    { status: data[:status] || "blocked", reason: data[:reason] || "signer response missing signature" }
  end

  def submit_payload(order:, signature:)
    {
      place_orders: {
        orders: [
          {
            id: order_id(order),
            product_id: order.dig(:product, :product_id),
            borrow_margin: nil,
            spot_leverage: nil,
            order: order.fetch(:order_fields),
            signature: signature
          }
        ],
        stop_on_failure: nil
      }
    }
  end

  def post_execute(payload)
    uri = URI.join(submit_base_url.end_with?("/") ? submit_base_url : "#{submit_base_url}/", "execute")
    response = @http_post.call(uri, payload)
    response.is_a?(Hash) ? response.merge("_endpoint" => "POST #{uri.path}") : response
  rescue => e
    {
      "_http_error" => true,
      "_endpoint" => "POST #{uri.path}",
      "error" => "#{e.class}: #{e.message}"
    }
  end

  def parse_submit_response(response)
    data = response.is_a?(Hash) ? response.with_indifferent_access : {}
    response_summary = sanitized_submit_response_summary(data)
    return submit_parse_result("http_error", nil, http_error_message(data), response_summary) if data[:_http_error]

    return submit_parse_result("unknown", nil, "Nado execute_place_orders response was not an object.", response_summary) unless response.is_a?(Hash)

    status_text = data[:status].to_s.downcase
    row = place_orders_response_rows(data).find { |candidate| candidate[:error].present? || candidate[:error_code].present? }
    return submit_parse_result("rejected", nil, nado_place_orders_error_message(row || data), response_summary) if status_text.in?(%w[failure failed error rejected])
    return submit_parse_result("rejected", nil, nado_place_orders_error_message(row), response_summary) if row

    digest = accepted_digest(data)
    if status_text.in?(%w[success submitted accepted])
      if valid_digest?(digest)
        return submit_parse_result("submitted", digest, "Nado execute_place_orders accepted order.", response_summary)
      end

      return submit_parse_result("unknown", nil, "Nado execute_place_orders response missing digest: #{compact_response_text(response_summary)}", response_summary)
    end

    submit_parse_result("unknown", nil, "Nado execute_place_orders returned status=#{data[:status].inspect}.", response_summary)
  end

  def final_status(parsed, post_position:, action:, expected_short:, confirmed:)
    return "failed_before_submit" unless parsed[:status] == "submitted"
    return action.to_s == "close" ? "submitted_but_not_confirmed" : "submitted_but_readback_pending" unless confirmed

    current_short = short_size(post_position)
    if action.to_s.in?(%w[open rebalance])
      expected_short_confirmed?(current_short: current_short, expected_short: expected_short) ? "submitted_and_confirmed" : "submitted_but_readback_pending"
    else
      current_short.zero? ? "submitted_and_confirmed" : "submitted_but_not_confirmed"
    end
  end

  def poll_post_submit_readback(action:, expected_short:)
    attempts = []
    readback_attempts(action).times do |index|
      @sleeper.call(readback_delay_seconds(action)) if index.positive?
      position = safe_read_position
      serialized = serialize_position(position)
      attempts << {
        attempt: index + 1,
        position_present: serialized.present?,
        confirmed: readback_confirms_action?(position, action, expected_short: expected_short),
        readback: serialized
      }
      return { attempts: attempts, position: position, confirmed: true } if attempts.last.fetch(:confirmed)
    end
    { attempts: attempts, position: nil, confirmed: false }
  end

  def readback_attempts(action)
    action.to_s == "close" ? POST_SUBMIT_CLOSE_READBACK_ATTEMPTS : POST_SUBMIT_READBACK_ATTEMPTS
  end

  def readback_delay_seconds(action)
    action.to_s == "close" ? POST_SUBMIT_CLOSE_READBACK_DELAY_SECONDS : POST_SUBMIT_READBACK_DELAY_SECONDS
  end

  def readback_confirms_action?(position, action, expected_short:)
    return false if position == :unavailable

    current_short = short_size(position)
    action.to_s == "close" ? current_short.zero? : expected_short_confirmed?(current_short: current_short, expected_short: expected_short)
  end

  def expected_short_after(action:, size_eth:, current_position:)
    case action.to_s
    when "open"
      order_size(size_eth)
    when "rebalance"
      short_size(current_position) + BigDecimal(size_eth.to_s)
    else
      BigDecimal("0")
    end
  end

  def expected_short_confirmed?(current_short:, expected_short:)
    expected = BigDecimal(expected_short.to_s)
    return current_short.zero? if expected.zero?

    (current_short - expected).abs <= product_size_increment
  end

  def safe_read_position
    @venue.read_position(symbol: "ETH")
  rescue
    :unavailable
  end

  def sanitized_order_summary(order)
    order.fetch(:summary).merge(
      endpoint: "POST /execute",
      body_shape: EXECUTE_BODY_SHAPE,
      request_type: "place_orders",
      signature: "<redacted>",
      typed_data_hash: typed_data_hash(order[:typed_data]),
      recv_time_diagnostics: order[:timing]
    )
  end

  def submit_parse_result(status, exchange_order_id, message, response_summary)
    {
      status: status,
      exchange_order_id: exchange_order_id,
      message: message,
      response_summary: response_summary
    }
  end

  def place_orders_response_rows(data)
    rows = data[:data].is_a?(Array) ? data[:data] : []
    rows.filter_map { |row| row.is_a?(Hash) ? row.with_indifferent_access : nil }
  end

  def accepted_digest(data)
    place_orders_response_rows(data).each do |row|
      return row[:digest] if row[:digest].present?
    end

    payload = data[:data].is_a?(Hash) ? data[:data].with_indifferent_access : nil
    payload&.dig(:digest) || data[:digest]
  end

  def valid_digest?(digest)
    digest.to_s.match?(/\A0x[0-9a-fA-F]{64}\z/)
  end

  def nado_place_orders_error_message(payload)
    code = payload[:error_code]
    error = (payload[:error] || payload[:message] || "unknown error").to_s
    error = "recv_time expired" if code.to_i == 2011 && error.include?("recv_time")
    code_text = code.present? ? "error_code=#{code} " : ""
    "Nado execute_place_orders rejected order: #{code_text}#{error}."
  end

  def http_error_message(data)
    raw = data[:error].presence || data[:message].presence || data[:body].presence || "unknown error"
    "#{data[:_endpoint] || "POST /execute"} HTTP error: #{raw}"
  end

  def compact_response_text(value)
    JSON.generate(value).truncate(300)
  end

  def sanitized_submit_response_summary(value)
    case value
    when Hash
      value.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = sensitive_key?(key) ? "<redacted>" : sanitized_submit_response_summary(nested)
      end
    when Array
      value.map { |nested| sanitized_submit_response_summary(nested) }
    else
      value
    end
  end

  def sensitive_key?(key)
    key.to_s.downcase.in?(%w[signature private_key privatekey authorization cookie auth_header])
  end

  def manual_action_required?(status)
    status.in?(%w[submitted_but_not_confirmed submitted_but_readback_pending failed_before_submit manual_action_required])
  end

  def final_message(status, submit_result)
    return submit_result&.dig(:message) if status == "submitted_and_confirmed"
    return "Nado submit accepted but readback did not confirm ETH-PERP position." if status.to_s.start_with?("submitted_but")

    submit_result&.dig(:message) || status
  end

  def manual_instruction(status)
    case status
    when "submitted_but_not_confirmed"
      "Use Nado UI/API readback and close any remaining ETH-PERP short with reduce-only buy only."
    when "submitted_but_readback_pending"
      "Refresh Nado read-only data before submitting another hedge action."
    when "failed_before_submit", "blocked_before_submit"
      "No Nado order was submitted. Resolve blockers and preview again."
    else
      nil
    end
  end

  def get_query(params)
    uri = URI.join(query_base_url.end_with?("/") ? query_base_url : "#{query_base_url}/", "query")
    uri.query = URI.encode_www_form(params)
    @http_get.call(uri)
  end

  def http_get(uri)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 2) do |http|
      http.get(uri.request_uri)
    end
    raise "GET #{uri.path} failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def http_post(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
    raise "POST #{uri.path} failed with HTTP #{response.code}: #{response.body.to_s[0, 160]}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def signer_post(uri, payload)
    http_post(uri, payload)
  end

  def signer_available?
    return true unless @signer_post.is_a?(Method)

    uri = URI.join(signer_url.end_with?("/") ? signer_url : "#{signer_url}/", "health")
    response = Net::HTTP.get_response(uri)
    response.is_a?(Net::HTTPSuccess) && JSON.parse(response.body)["ok"] == true
  rescue
    false
  end

  def response_rows(response)
    rows = []
    collect_rows(response["data"] || response, rows)
    rows
  end

  def collect_rows(value, rows)
    if value.is_a?(Array)
      value.each { |item| collect_rows(item, rows) }
    elsif value.is_a?(Hash)
      if value.keys.any? { |key| key.to_s.in?(%w[product_id productId symbol ticker_id tickerId]) }
        rows << value
      else
        value.values.each { |item| collect_rows(item, rows) }
      end
    end
  end

  def nado_eth_perp_candidate?(row)
    symbol = (row["symbol"] || row["ticker_id"] || row["tickerId"]).to_s.upcase
    type = (row["type"] || row["product_type"] || row["productType"]).to_s.downcase
    type == "perp" && !symbol.include?("BTC") && (symbol.include?("ETH") || symbol.include?("WETH"))
  end

  def resolve_market_price(product_id)
    return nil unless product_id && query_base_url.present?

    response = get_query(type: "market_price", product_id: product_id)
    data = response["data"].is_a?(Hash) ? response["data"] : response
    bid = x18_to_decimal(data["bid_x18"])
    ask = x18_to_decimal(data["ask_x18"])
    bid && ask ? (bid + ask) / 2 : nil
  rescue
    nil
  end

  def build_appendix(reduce_only:, isolated_margin_x6:)
    version = 1
    isolated_bit = isolated_margin_x6 ? 1 << 8 : 0
    order_type_ioc = 1 << 9
    reduce_only_bit = reduce_only ? 1 << 11 : 0
    value_bits = (isolated_margin_x6 || 0) << 64
    value_bits | version | isolated_bit | order_type_ioc | reduce_only_bit
  end

  def order_side(action:, size_eth:)
    return "buy" if action.to_s == "close"
    return BigDecimal(size_eth.to_s).negative? ? "buy" : "sell" if action.to_s == "rebalance"

    "sell"
  end

  def reduce_only_order?(action:, size_eth:)
    action.to_s == "close" || (action.to_s == "rebalance" && BigDecimal(size_eth.to_s).negative?)
  end

  def isolated_partial_reduce?(action:, size_eth:, order_size:, current_position:)
    return false unless %w[close rebalance].include?(action.to_s)
    return false if action.to_s == "rebalance" && !BigDecimal(size_eth.to_s).negative?
    return false unless margin_mode(current_position) == "isolated"
    return false unless short_size(current_position).positive?

    BigDecimal(order_size.to_s) < short_size(current_position)
  end

  def isolated_full_close?(action:, current_position:)
    action.to_s == "close" && margin_mode(current_position) == "isolated" && short_size(current_position).positive?
  end

  def full_close_size_blockers(full_close:, order_size:, rounded_size:)
    return [] unless full_close
    return [] if BigDecimal(rounded_size.to_s) == BigDecimal(order_size.to_s)

    [ "Nado isolated full close size is not divisible by size increment; refusing partial close." ]
  end

  def isolated_partial_reduce_blocker
    "Nado isolated partial reduce is disabled; close the full isolated short and reopen the target size."
  end

  def order_size(size_eth)
    BigDecimal(size_eth.to_s).abs
  end

  def appendix_isolated?(appendix)
    (appendix & (1 << 8)).positive?
  end

  def margin_plan(action:, reduce_only:, rounded_size:, rounded_price:, current_position:, ui_equivalent_full_close: false)
    if reduce_only
      return ui_equivalent_close_margin_plan(current_position) if ui_equivalent_full_close

      return reduce_only_margin_plan(current_position)
    end

    blockers = []
    mode = desired_margin_mode
    leverage = requested_leverage
    blockers << "Nado margin mode must be isolated for live open/increase; refusing cross-margin submit." unless mode == "isolated"
    blockers << "Nado requested leverage must be positive." unless leverage&.positive?
    notional = rounded_size * rounded_price
    margin = leverage&.positive? ? notional / leverage : nil
    margin_x6 = margin ? (margin * BigDecimal(1_000_000)).round(0).to_i : nil
    blockers << "Nado isolated-margin order builder unavailable; refusing cross-margin submit." if mode == "isolated" && (!margin_x6 || margin_x6 <= 0)
    {
      margin_mode: mode,
      requested_leverage: leverage,
      isolated_margin_usd: margin ? BigDecimal(margin_x6.to_s) / BigDecimal(1_000_000) : nil,
      isolated_margin_x6: blockers.empty? ? margin_x6 : nil,
      blockers: blockers
    }
  end

  def reduce_only_margin_plan(current_position)
    return { margin_mode: "reduce_only", requested_leverage: nil, isolated_margin_usd: nil, isolated_margin_x6: nil, blockers: [] } unless margin_mode(current_position) == "isolated"

    margin_x6 = isolated_margin_x6_from_position(current_position)
    blockers = []
    blockers << "Nado isolated reduce-only close requires isolated margin readback." unless margin_x6
    {
      margin_mode: "isolated_reduce_only",
      requested_leverage: nil,
      isolated_margin_usd: margin_x6 ? BigDecimal(margin_x6.to_s) / BigDecimal(1_000_000) : nil,
      isolated_margin_x6: margin_x6,
      blockers: blockers
    }
  end

  def ui_equivalent_close_margin_plan(current_position)
    margin_x6 = isolated_margin_x6_from_position(current_position)
    {
      margin_mode: "isolated_ui_equivalent_close",
      requested_leverage: nil,
      isolated_margin_usd: margin_x6 ? BigDecimal(margin_x6.to_s) / BigDecimal(1_000_000) : nil,
      isolated_margin_x6: nil,
      blockers: []
    }
  end

  def desired_margin_mode
    (@env["AERODROME_NADO_MARGIN_MODE"].presence || DEFAULT_MARGIN_MODE).to_s.downcase
  end

  def isolated_decrease_strategy
    strategy = @env["AERODROME_NADO_ISOLATED_DECREASE_STRATEGY"].presence || "delta_reduce"
    strategy.to_s.downcase
  end

  def partial_isolated_reduce_supported?
    isolated_decrease_strategy == "delta_reduce"
  end

  def partial_isolated_reduce_evidence
    if partial_isolated_reduce_supported?
      "Production live delta probe proved Nado isolated delta decrease with reduce-only buy size 0.005 ETH from 0.404 to 0.399, then isolated delta increase back to 0.404 by later readback. Payload: default_1 sender, appendix=2817, place_orders batch, no isolated margin high bits."
    else
      "Operator selected close_reopen fallback with AERODROME_NADO_ISOLATED_DECREASE_STRATEGY=close_reopen."
    end
  end

  def blocked_plan_reason(current_position:, delta:)
    return "current Nado readback is unavailable" if current_position == :unavailable
    return "current Nado position is long" if position_size(current_position).positive?

    "Nado isolated planner blocked"
  end

  def isolated_delta_reduce_order?(action:, size_eth:, current_position:)
    action.to_s == "rebalance" &&
      BigDecimal(size_eth.to_s).negative? &&
      margin_mode(current_position) == "isolated" &&
      short_size(current_position).positive? &&
      partial_isolated_reduce_supported?
  end

  def requested_leverage
    BigDecimal((@env["AERODROME_NADO_REQUESTED_LEVERAGE"].presence || DEFAULT_REQUESTED_LEVERAGE).to_s)
  rescue ArgumentError
    nil
  end

  def decode_appendix(appendix)
    value = appendix.to_i
    low_flags = value & ((1 << 64) - 1)
    margin_x6 = value >> 64
    isolated = appendix_isolated?(value)
    {
      appendix: value.to_s,
      low_flags: low_flags,
      version: low_flags & 0xFF,
      isolated: isolated,
      order_type: ((low_flags >> 9) & 0b11) == 1 ? "ioc" : "default",
      reduce_only: (low_flags & (1 << 11)).positive?,
      isolated_margin_x6: isolated ? margin_x6 : nil,
      isolated_margin_usd: isolated ? (BigDecimal(margin_x6.to_s) / BigDecimal(1_000_000)).to_s("F") : nil
    }
  end

  def isolated_margin_x6_from_position(position)
    raw = position_value(position, :isolated_margin_usd)
    return nil if raw.blank?

    (BigDecimal(raw.to_s) * BigDecimal(1_000_000)).round(0).to_i
  rescue ArgumentError
    nil
  end

  def use_ui_equivalent_isolated_close?(current_position)
    margin_mode(current_position) == "isolated"
  end

  def isolated_position_subaccount(position)
    raw = position_value(position, :subaccount) || position_value(position, :sender)
    raw = position.dig(:metadata, :raw, "subaccount") if raw.blank? && position.is_a?(Hash)
    raw = position.dig(:metadata, :raw, "sender") if raw.blank? && position.is_a?(Hash)
    raw.presence
  end

  def position_value(position, key)
    return nil unless position && position != :unavailable

    position[key] || position[key.to_s]
  end

  def isolated_increase?(action, size_eth)
    return false unless desired_margin_mode == "isolated"
    return true if action.to_s == "open"

    action.to_s == "rebalance" && BigDecimal(size_eth.to_s).positive?
  end

  def margin_mode(position)
    return nil unless position && position != :unavailable

    (position[:margin_mode] || position["margin_mode"] || "unknown").to_s
  end

  def order_id(order)
    Digest::SHA256.hexdigest(JSON.generate(order.fetch(:order_fields)))[0, 8].to_i(16) & ((1 << 31) - 1)
  end

  def nado_receive_time_nonce(seed:, now:)
    receive_time_ms = local_time_ms(now) + (RECEIVE_TIME_BUFFER_SECONDS * 1000)
    entropy = Digest::SHA256.hexdigest(seed)[0, 8].to_i(16) & ((1 << 20) - 1)
    (receive_time_ms << 20) | entropy
  end

  def order_timing_summary(order_fields, local_time:)
    diagnostics = recv_time_diagnostics(order_fields, local_time: local_time)
    blockers = []
    seconds_until_recv_time = diagnostics[:seconds_until_recv_time]
    blockers << "Nado recv_time is not computable from order nonce" unless seconds_until_recv_time
    if seconds_until_recv_time && seconds_until_recv_time > MAX_RECEIVE_TIME_FUTURE_SECONDS
      blockers << "Nado recv_time is more than #{MAX_RECEIVE_TIME_FUTURE_SECONDS} seconds in the future"
    end
    blockers << "Nado recv_time is stale" if seconds_until_recv_time && seconds_until_recv_time.negative?
    { diagnostics: diagnostics, blockers: blockers }
  end

  def recv_time_diagnostics(order_fields, local_time:)
    nonce = Integer(order_fields[:nonce])
    recv_time_ms = nonce >> 20
    local_submit_time_ms = local_time_ms(local_time)
    expiration = Integer(order_fields[:expiration])
    expiration_units = expiration >= 1_000_000_000_000 ? "milliseconds" : "seconds"
    expiration_time = expiration_units == "milliseconds" ? Time.at(expiration / 1000.0).utc.iso8601(3) : Time.at(expiration).utc.iso8601
    {
      recv_time_ms: recv_time_ms,
      recv_time: Time.at(recv_time_ms / 1000.0).utc.iso8601(3),
      local_submit_time_ms: local_submit_time_ms,
      local_submit_time: local_time.utc.iso8601(3),
      seconds_until_recv_time: ((recv_time_ms - local_submit_time_ms) / 1000.0).round(3),
      order_expiration: expiration,
      order_expiration_units: expiration_units,
      order_expiration_time: expiration_time
    }
  rescue ArgumentError, TypeError
    {
      recv_time_ms: nil,
      recv_time: nil,
      local_submit_time_ms: local_time_ms(local_time),
      local_submit_time: local_time.utc.iso8601(3),
      seconds_until_recv_time: nil,
      order_expiration: order_fields[:expiration],
      order_expiration_units: nil,
      order_expiration_time: nil
    }
  end

  def local_time_ms(time)
    (time.to_f * 1000).to_i
  end

  def verifying_contract(product_id)
    "0x#{product_id.to_i.to_s(16).rjust(40, '0')}"
  end

  def typed_data_hash(typed_data)
    return nil unless typed_data

    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(typed_data.deep_stringify_keys.sort.to_h))}"
  end

  def decimal_to_x18(value)
    (BigDecimal(value.to_s) * BigDecimal(10**18)).to_i
  end

  def x18_to_decimal(value)
    return nil unless value

    BigDecimal(value.to_s) / BigDecimal(10**18)
  rescue ArgumentError
    nil
  end

  def decimal_or_nil(value)
    value.present? ? BigDecimal(value.to_s) : nil
  rescue ArgumentError
    nil
  end

  def positive_integer(value)
    parsed = Integer(value)
    parsed.positive? ? parsed : nil
  rescue ArgumentError, TypeError
    nil
  end

  def short_size(position)
    size = position_size(position)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def position_size(position)
    return BigDecimal("0") unless position && position != :unavailable

    BigDecimal(position.fetch(:size).to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def serialize_position(position)
    return nil unless position && position != :unavailable

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end

  def query_base_url
    (@env["NADO_GATEWAY_QUERY_BASE_URL"].presence || @env["NADO_API_BASE_URL"]).to_s.delete_suffix("/")
  end

  def submit_base_url
    (@env["NADO_API_BASE_URL"].presence || @env["NADO_GATEWAY_QUERY_BASE_URL"]).to_s.delete_suffix("/")
  end

  def signer_url
    @env["EXECUTION_SIGNER_URL"].to_s.delete_suffix("/")
  end

  def subaccount
    @env["NADO_ACCOUNT_SUBACCOUNT"].presence || @venue.send(:derive_sender)
  end

  def nado_default_1_sender
    account = @env["NADO_ACCOUNT_ADDRESS"].to_s.downcase
    return "0x#{account.delete_prefix('0x')}64656661756c745f31000000" if account.match?(/\A0x[0-9a-f]{40}\z/)

    subaccount
  end

  def decimal_string(value)
    return nil unless value

    BigDecimal(value.to_s).to_s("F")
  end
end
