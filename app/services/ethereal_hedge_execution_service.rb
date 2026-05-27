require "digest"
require "net/http"
require "securerandom"

class EtherealHedgeExecutionService
  DEFAULT_SYMBOL = "ETH-PERP".freeze
  EXCHANGE_SYMBOL = "ETHUSD".freeze
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_ETHEREAL_ORDERS".freeze
  DELTA_PROBE_CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_ETHEREAL_DELTA_PROBE_ORDERS".freeze
  CLOSE_PROBE_CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_ETHEREAL_CLOSE_PROBE_ORDERS".freeze
  ETHUSD_ONCHAIN_ID = 2
  ETHUSD_TICK_SIZE = BigDecimal("0.1")
  ETHUSD_LOT_SIZE = BigDecimal("0.0001")
  DEFAULT_MAX_SLIPPAGE = BigDecimal("0.01")
  POST_SUBMIT_READBACK_ATTEMPTS = 12
  POST_SUBMIT_READBACK_DELAY_SECONDS = 0.25
  DOMAIN = {
    name: "Ethereal",
    version: "1",
    chainId: 5_064_014,
    verifyingContract: "0xB3cDC82035C495c484C9fF11eD5f3Ff6d342e3cc"
  }.freeze

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(env: ENV, venue: nil, http_get: nil, http_post: nil, signer_post: nil, now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @venue = venue || HedgeVenues::Ethereal.new(env: env, probe: nil)
    @http_get = http_get || method(:http_get)
    @http_post = http_post || method(:http_post)
    @signer_post = signer_post || method(:signer_post)
    @now = now
    @sleeper = sleeper
  end

  def read_position
    @venue.read_position(symbol: "ETH")
  rescue
    :unavailable
  end

  def preflight(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:)
    order = build_order_preview(position: position, action: action, size_eth: size_eth, current_position: current_position, max_slippage: max_slippage)
    blockers = live_blockers(position: position, action: action, size_eth: size_eth, current_position: current_position, confirmation: confirmation, order: order)
    {
      venue: "Ethereal",
      mode: @venue.live_mode_state,
      live_supported: true,
      live_enabled: @venue.live_enabled?,
      action: action,
      target_hedge_size_eth: decimal_string(size_eth),
      rounded_order_size_eth: order.dig(:summary, :rounded_size_eth),
      estimated_notional_usd: order.dig(:summary, :estimated_notional_usd),
      intended_side: order.dig(:summary, :side),
      margin_mode: "cross",
      effective_leverage: order.dig(:summary, :estimated_effective_leverage),
      reduce_only_close_available: true,
      current_venue_position: serialize_position(current_position),
      order_summary: sanitized_order_summary(order),
      max_slippage: max_slippage.to_s,
      submitted: false,
      manual_action_required: blockers.any?,
      next_action: blockers.any? ? "Resolve Ethereal live blockers before submitting." : "Submit through dashboard live action with exact Ethereal confirmation.",
      blockers: unique_messages(blockers),
      warnings: order.fetch(:warnings)
    }
  end

  def open_short(position:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute(position: position, action: "open", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation, migration: migration)
  end

  def close_short(position:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute(position: position, action: "close", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation, migration: migration)
  end

  def rebalance_short(position:, delta_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    execute(position: position, action: "rebalance", size_eth: delta_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage, require_confirmation: require_confirmation, migration: migration)
  end

  def auto_rebalance_short(position:, delta_eth:, current_position:, max_slippage:)
    execute(position: position, action: "rebalance", size_eth: delta_eth, current_position: current_position, confirmation: nil, max_slippage: max_slippage, require_confirmation: false)
  end

  def delta_probe(position:, direction:, size_eth:, current_position:, confirmation:, max_slippage:, dry_run: true)
    direction = direction.to_s
    signed_delta = direction == "decrease" ? -BigDecimal(size_eth.to_s) : BigDecimal(size_eth.to_s)
    order = build_order_preview(position: position, action: "rebalance", size_eth: signed_delta, current_position: current_position, max_slippage: max_slippage)
    order = annotate_delta_probe_order(order: order, direction: direction, current_position: current_position)
    blockers = delta_probe_position_blockers(direction: direction, current_position: current_position, rounded_size: BigDecimal(order.dig(:summary, :rounded_size_eth).to_s))
    blockers.concat(order.fetch(:blockers))

    if dry_run
      return delta_probe_result("dry_run", blockers.uniq, order, position, direction, current_position, nil, synthetic_position_after_probe(current_position, order.dig(:summary, :expected_after_short_eth)), nil, dry_run: true)
    end

    blockers.concat(delta_probe_live_blockers(position: position, confirmation: confirmation, order: order, current_position: current_position))
    blockers = blockers.uniq
    return delta_probe_result("blocked_before_submit", blockers, order, position, direction, current_position, nil, nil, nil, dry_run: false) if blockers.any?

    signing = sign(order.fetch(:typed_data), order: order)
    unless signing[:status] == "signed"
      return delta_probe_result("failed_before_submit", [ signing[:reason] || "Ethereal signer did not return a signature" ], order, position, direction, current_position, nil, nil, nil, dry_run: false)
    end

    payload = order.fetch(:submit_payload).deep_dup
    payload[:signature] = signing.fetch(:signature)
    response = post_order(payload)
    parsed = parse_submit_response(response)
    unless parsed[:status] == "submitted"
      return delta_probe_result("failed_before_submit", [ parsed[:message] ], order, position, direction, current_position, parsed, nil, nil, dry_run: false)
    end

    expected = BigDecimal(order.dig(:summary, :expected_after_short_eth).to_s)
    readback = poll_post_submit_readback(expected_short: expected, action: "rebalance")
    status = readback[:confirmed] ? "submitted_and_confirmed" : "submitted_but_readback_pending"
    delta_probe_result(status, [], order, position, direction, current_position, parsed, readback[:position], readback, dry_run: false)
  rescue => e
    delta_probe_result("failed_before_submit", [ "#{e.class}: #{e.message}" ], order || {}, position, direction, current_position, nil, nil, nil, dry_run: dry_run)
  end

  def round_trip_delta_probe(position:, size_eth:, current_position:, confirmation:, max_slippage:, dry_run: true)
    decrease = delta_probe(
      position: position,
      direction: "decrease",
      size_eth: size_eth,
      current_position: current_position,
      confirmation: confirmation,
      max_slippage: max_slippage,
      dry_run: dry_run
    )
    if dry_run
      next_position = decrease.blockers.empty? ? synthetic_position_after_probe(current_position, decrease.receipt[:expected_after_short_eth]) : current_position
      increase = decrease.blockers.empty? ? delta_probe(position: position, direction: "increase", size_eth: size_eth, current_position: next_position, confirmation: confirmation, max_slippage: max_slippage, dry_run: true) : nil
      return round_trip_delta_probe_result(position: position, initial_position: current_position, decrease_result: decrease, increase_result: increase, dry_run: true)
    end

    return round_trip_delta_probe_result(position: position, initial_position: current_position, decrease_result: decrease, increase_result: nil, dry_run: false) unless decrease.status == "submitted_and_confirmed"

    increase = delta_probe(
      position: position,
      direction: "increase",
      size_eth: size_eth,
      current_position: decrease.receipt[:after_readback],
      confirmation: confirmation,
      max_slippage: max_slippage,
      dry_run: false
    )
    round_trip_delta_probe_result(position: position, initial_position: current_position, decrease_result: decrease, increase_result: increase, dry_run: false)
  end

  def close_reopen_probe(position:, mode:, target_size_eth:, current_position:, confirmation:, max_slippage:, dry_run: true)
    mode = mode.to_s
    close_size = short_size(current_position)
    close_order = annotate_close_probe_order(
      build_order_preview(position: position, action: "close", size_eth: close_size, current_position: current_position, max_slippage: max_slippage),
      mode: mode,
      leg: "close",
      expected_after_short_eth: BigDecimal("0")
    )
    reopen_order = nil
    if mode == "close_reopen"
      target = @venue.round_order_size(target_size_eth)
      reopen_order = annotate_close_probe_order(
        build_order_preview(position: position, action: "open", size_eth: target, current_position: nil, max_slippage: max_slippage),
        mode: mode,
        leg: "reopen",
        expected_after_short_eth: target
      )
    end
    blockers = close_probe_position_blockers(mode: mode, current_position: current_position, close_order: close_order, reopen_order: reopen_order)

    if dry_run
      return close_reopen_probe_result(
        status: "dry_run",
        blockers: blockers,
        position: position,
        mode: mode,
        dry_run: true,
        before_position: current_position,
        close_order: close_order,
        close_submit: nil,
        close_poll: nil,
        flat_position: nil,
        reopen_order: reopen_order,
        reopen_submit: nil,
        reopen_poll: nil,
        final_position: mode == "close_reopen" ? synthetic_position_after_probe(nil, reopen_order&.dig(:summary, :expected_after_short_eth)) : nil
      )
    end

    blockers.concat(close_probe_live_blockers(position: position, confirmation: confirmation, current_position: current_position, close_order: close_order, reopen_order: reopen_order))
    blockers = blockers.uniq
    return close_reopen_probe_result(status: "blocked_before_submit", blockers: blockers, position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, reopen_order: reopen_order) if blockers.any?

    close_leg = submit_probe_leg(order: close_order)
    return close_reopen_probe_result(status: close_leg[:status], blockers: close_leg[:blockers], position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, close_submit: close_leg[:submit], reopen_order: reopen_order) unless close_leg[:status] == "submitted"

    close_poll = poll_post_submit_readback(expected_short: BigDecimal("0"), action: "close")
    unless close_poll[:confirmed]
      return close_reopen_probe_result(status: "submitted_but_readback_pending", blockers: [], position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, close_submit: close_leg[:submit], close_poll: close_poll, reopen_order: reopen_order)
    end
    return close_reopen_probe_result(status: "submitted_and_confirmed", blockers: [], position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, close_submit: close_leg[:submit], close_poll: close_poll, flat_position: close_poll[:position], reopen_order: nil, final_position: close_poll[:position]) if mode == "close_only"

    reopen_leg = submit_probe_leg(order: reopen_order)
    return close_reopen_probe_result(status: "failed_after_close_manual_action_required", blockers: reopen_leg[:blockers], position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, close_submit: close_leg[:submit], close_poll: close_poll, flat_position: close_poll[:position], reopen_order: reopen_order, reopen_submit: reopen_leg[:submit]) unless reopen_leg[:status] == "submitted"

    expected_reopen = BigDecimal(reopen_order.dig(:summary, :expected_after_short_eth).to_s)
    reopen_poll = poll_post_submit_readback(expected_short: expected_reopen, action: "open")
    status = reopen_poll[:confirmed] ? "submitted_and_confirmed" : "submitted_but_readback_pending"
    close_reopen_probe_result(status: status, blockers: [], position: position, mode: mode, dry_run: false, before_position: current_position, close_order: close_order, close_submit: close_leg[:submit], close_poll: close_poll, flat_position: close_poll[:position], reopen_order: reopen_order, reopen_submit: reopen_leg[:submit], reopen_poll: reopen_poll, final_position: reopen_poll[:position])
  rescue => e
    close_reopen_probe_result(status: "failed_before_submit", blockers: [ "#{e.class}: #{e.message}" ], position: position, mode: mode, dry_run: dry_run, before_position: current_position, close_order: close_order, reopen_order: reopen_order)
  end

  def build_order_preview(position:, action:, size_eth:, current_position:, max_slippage:)
    action = action.to_s
    signed_size = BigDecimal(size_eth.to_s)
    current_short = short_size(current_position)
    reduce_only = action == "close" || signed_size.negative?
    order_size = action == "close" ? current_short : signed_size.abs
    rounded_size = @venue.round_order_size(order_size)
    mark_price = eth_price(position: position, current_position: current_position)
    side = reduce_only ? "buy" : "sell"
    price = limit_price(mark_price, side: side, max_slippage: max_slippage)
    notional = rounded_size * price if price
    account_state = @venue.account_state
    account_value = decimal_or_nil(account_state[:account_value_usd]) || decimal_or_nil(account_state[:collateral_usd])
    effective = account_value&.positive? && notional ? notional.abs / account_value : nil
    client_order_id = ethereal_client_order_id("#{position.id}#{action}#{@now.call.to_i}#{rounded_size.to_s('F').delete('.')}")
    mapping_error = nil
    typed_data = begin
      build_typed_data(quantity: rounded_size, price: price, side: side, reduce_only: reduce_only)
    rescue => e
      mapping_error = e.message
      build_typed_data(
        quantity: rounded_size,
        price: price,
        side: side,
        reduce_only: reduce_only,
        subaccount: zero_bytes32
      )
    end
    submit_payload = build_submit_payload(typed_data: typed_data, quantity: rounded_size, price: price, client_order_id: client_order_id, signature: "PENDING_EXTERNAL_SIGNER")

    {
      schema: "ethereal_eip712_trade_order",
      endpoint: "POST /v1/order",
      body_shape: "ethereal_submit_order",
      symbol: DEFAULT_SYMBOL,
      market_symbol: EXCHANGE_SYMBOL,
      margin_mode: "cross",
      action: action,
      typed_data: typed_data,
      submit_payload: submit_payload,
      summary: {
        side: side,
        reduce_only: reduce_only,
        rounded_size_eth: decimal_string(rounded_size),
        estimated_notional_usd: decimal_string(notional),
        price: decimal_string(price),
        margin_mode: "cross",
        account_value_usd: decimal_string(account_value),
        estimated_effective_leverage: decimal_string(effective),
        expected_after_short_eth: decimal_string(expected_short_after(action: action, size_eth: signed_size, current_position: current_position)),
        client_order_id: client_order_id,
        onchain_id: ethereal_onchain_id
      },
      blockers: preview_blockers(rounded_size: rounded_size, price: price, mapping_error: mapping_error),
      warnings: [ "Ethereal uses cross margin only; effective leverage is estimated from notional / account value." ]
    }
  end

  def reconcile_pending_result(result)
    return result unless result.status.to_s.start_with?("submitted_but")

    expected = decimal_or_nil(result.receipt[:expected_short_eth])
    return result unless expected

    readback = poll_post_submit_readback(expected_short: expected, action: result.receipt[:action])
    return result unless readback[:confirmed]

    receipt = result.receipt.merge(
      delayed_reconciliation: true,
      post_submit_readback: serialize_position(readback[:position]),
      readback_poll_attempts: readback[:attempts],
      final_status: "submitted_and_confirmed",
      final_message: "Ethereal order confirmed by delayed readback."
    )
    Result.new("submitted_and_confirmed", [], result.warnings, receipt)
  end

  private

  def annotate_delta_probe_order(order:, direction:, current_position:)
    before_short = short_size(current_position)
    rounded_size = BigDecimal(order.dig(:summary, :rounded_size_eth).to_s)
    expected_after = direction == "decrease" ? before_short - rounded_size : before_short + rounded_size
    summary = order.fetch(:summary).merge(
      action: "cross_delta_probe",
      probe_direction: direction,
      delta_probe: true,
      close_reopen: false,
      full_close: false,
      before_short_eth: decimal_string(before_short),
      expected_after_short_eth: decimal_string(expected_after),
      expected_after_delta_eth: decimal_string(direction == "decrease" ? -rounded_size : rounded_size)
    )
    warnings = order.fetch(:warnings) + [
      "Ethereal delta probe uses true cross-margin delta orders; no close/reopen and no hedge target change."
    ]
    order.merge(summary: summary, warnings: warnings.uniq)
  end

  def delta_probe_position_blockers(direction:, current_position:, rounded_size:)
    blockers = []
    blockers << "direction must be decrease or increase" unless direction.in?(%w[decrease increase])
    blockers << "current Ethereal readback is unavailable" if current_position == :unavailable || current_position.nil?
    blockers << "current Ethereal position must be a cross-margin short" unless cross_short_position?(current_position)
    blockers << "delta probe size must be positive after rounding" unless rounded_size.positive?
    blockers << "decrease delta must be smaller than current Ethereal short" if direction == "decrease" && short_size(current_position) <= rounded_size
    blockers
  end

  def cross_short_position?(position)
    position.is_a?(Hash) && position[:margin_mode] == "cross" && short_size(position).positive?
  end

  def delta_probe_live_blockers(position:, confirmation:, order:, current_position:)
    blockers = []
    blockers << "AERODROME_ETHEREAL_DELTA_PROBE_ENABLED must be true" unless delta_probe_enabled?
    blockers << "submitted confirmation must equal #{DELTA_PROBE_CONFIRMATION}" unless confirmation.to_s == DELTA_PROBE_CONFIRMATION
    blockers << "position must be active" unless position.active?
    blockers << "active hedge-ready Mellow Autopilot position is required" unless position.mellow_autopilot? && position.hedge_ready?
    blockers << "ETHEREAL_LINKED_SIGNER_ADDRESS is required" if @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].blank?
    blockers << "ETHEREAL_SUBACCOUNT_ID or ETHEREAL_SUBACCOUNT_NAME is required" unless ethereal_subaccount_configured?
    blockers << "ETHEREAL_API_BASE_URL is required" if @env["ETHEREAL_API_BASE_URL"].blank?
    blockers << "Ethereal signer service URL is required" if signer_url.blank?
    blockers << "Ethereal signer service does not advertise Ethereal support" if signer_url.present? && !signer_supports_ethereal?
    blockers.concat(delta_probe_position_blockers(direction: order.dig(:summary, :probe_direction), current_position: current_position, rounded_size: BigDecimal(order.dig(:summary, :rounded_size_eth).to_s)))
    blockers.concat(order.fetch(:blockers, []))
    blockers.uniq
  end

  def delta_probe_enabled?
    ActiveModel::Type::Boolean.new.cast(@env["AERODROME_ETHEREAL_DELTA_PROBE_ENABLED"])
  end

  def delta_probe_result(status, blockers, order, position, direction, pre_position, submit_response, post_position, readback_poll, dry_run:)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "cross_delta_probe",
      venue: "ethereal",
      direction: direction,
      dry_run: dry_run,
      position_id: position.id,
      source: position.respond_to?(:position_source) ? position.position_source : nil,
      source_external_id: position.respond_to?(:external_id) ? position.external_id : nil,
      before_readback: serialize_position(pre_position),
      delta_size_eth: order.dig(:summary, :rounded_size_eth),
      expected_after_short_eth: order.dig(:summary, :expected_after_short_eth),
      payload_summary: sanitized_order_summary(order),
      submit_response_classification: submit_response,
      exchange_order_id: submit_response&.dig(:exchange_order_id),
      poll_attempts: readback_poll&.fetch(:attempts, []),
      after_readback: serialize_position(post_position),
      final_status: status,
      final_message: delta_probe_final_message(status, submit_response, dry_run: dry_run),
      manual_action_required: manual_action_required?(status),
      blockers: unique_messages(blockers),
      warnings: order.fetch(:warnings, [])
    }.compact
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def round_trip_delta_probe_result(position:, initial_position:, decrease_result:, increase_result:, dry_run:)
    status = if dry_run
      "dry_run"
    elsif decrease_result.status != "submitted_and_confirmed"
      decrease_result.status
    else
      increase_result&.status || "failed_before_submit"
    end
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "cross_delta_probe_round_trip",
      venue: "ethereal",
      dry_run: dry_run,
      position_id: position.id,
      before_readback: serialize_position(initial_position),
      decrease_leg: decrease_result.receipt,
      increase_leg: increase_result&.receipt,
      after_readback: increase_result&.receipt&.dig(:after_readback) || decrease_result.receipt[:after_readback],
      final_status: status,
      final_message: round_trip_delta_probe_message(decrease_result: decrease_result, increase_result: increase_result, dry_run: dry_run),
      manual_action_required: manual_action_required?(status),
      blockers: unique_messages(decrease_result.blockers + (increase_result&.blockers || [])),
      warnings: unique_messages(decrease_result.warnings + (increase_result&.warnings || []))
    }
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def synthetic_position_after_probe(position, expected_short_eth)
    return position unless position.is_a?(Hash) && expected_short_eth.present?

    expected = BigDecimal(expected_short_eth.to_s)
    position.deep_dup.merge(size: "-#{expected.to_s('F')}", short_size: expected.to_s("F"), side: expected.positive? ? "short" : "flat", margin_mode: "cross")
  end

  def delta_probe_final_message(status, submit_response, dry_run:)
    return "Ethereal cross-margin delta probe dry-run only; no signature or order submission." if dry_run
    return "Ethereal cross-margin delta probe submitted and confirmed by readback." if status == "submitted_and_confirmed"
    return "Ethereal cross-margin delta probe submit accepted but readback did not confirm expected delta." if status.to_s.start_with?("submitted_but")

    submit_response&.dig(:message) || status
  end

  def round_trip_delta_probe_message(decrease_result:, increase_result:, dry_run:)
    return "Ethereal cross-margin delta round-trip dry-run only; no signature or order submission." if dry_run
    return "Ethereal delta decrease did not confirm; increase leg was not submitted." unless decrease_result.status == "submitted_and_confirmed"
    return "Ethereal cross-margin delta round-trip completed and confirmed." if increase_result&.status == "submitted_and_confirmed"

    increase_result&.receipt&.dig(:final_message) || "Ethereal delta increase leg did not confirm."
  end

  def manual_action_required?(status)
    !status.in?(%w[dry_run submitted_and_confirmed])
  end

  def annotate_close_probe_order(order, mode:, leg:, expected_after_short_eth:)
    summary = order.fetch(:summary).merge(
      action: "cross_close_reopen_probe",
      probe_mode: mode,
      probe_leg: leg,
      close_reopen_probe: true,
      expected_after_short_eth: decimal_string(expected_after_short_eth)
    )
    warnings = order.fetch(:warnings) + [
      "Ethereal close probe uses cross-margin reduce-only close and optional target reopen; no hedge target change."
    ]
    order.merge(summary: summary, warnings: warnings.uniq)
  end

  def close_probe_position_blockers(mode:, current_position:, close_order:, reopen_order:)
    blockers = []
    blockers << "mode must be close_only or close_reopen" unless mode.in?(%w[close_only close_reopen])
    blockers << "current Ethereal readback is unavailable" if current_position == :unavailable || current_position.nil?
    blockers << "current Ethereal position must be a cross-margin short" unless cross_short_position?(current_position)
    blockers << "close order size must be positive" unless BigDecimal(close_order.dig(:summary, :rounded_size_eth).to_s).positive?
    blockers << "close order must be buy reduce-only" unless close_order.dig(:summary, :side) == "buy" && close_order.dig(:summary, :reduce_only) == true
    if mode == "close_reopen"
      blockers << "reopen target size must be positive" unless BigDecimal(reopen_order&.dig(:summary, :rounded_size_eth).to_s).positive?
      blockers << "reopen order must be sell non-reduce-only" unless reopen_order&.dig(:summary, :side) == "sell" && reopen_order&.dig(:summary, :reduce_only) == false
    end
    blockers.concat(close_order.fetch(:blockers, []))
    blockers.concat(reopen_order.fetch(:blockers, [])) if reopen_order
    blockers.uniq
  end

  def close_probe_live_blockers(position:, confirmation:, current_position:, close_order:, reopen_order:)
    blockers = []
    blockers << "AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED must be true" unless close_probe_enabled?
    blockers << "submitted confirmation must equal #{CLOSE_PROBE_CONFIRMATION}" unless confirmation.to_s == CLOSE_PROBE_CONFIRMATION
    blockers << "position must be active" unless position.active?
    blockers << "active hedge-ready Mellow Autopilot position is required" unless position.mellow_autopilot? && position.hedge_ready?
    blockers << "ETHEREAL_LINKED_SIGNER_ADDRESS is required" if @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].blank?
    blockers << "ETHEREAL_SUBACCOUNT_ID or ETHEREAL_SUBACCOUNT_NAME is required" unless ethereal_subaccount_configured?
    blockers << "ETHEREAL_API_BASE_URL is required" if @env["ETHEREAL_API_BASE_URL"].blank?
    blockers << "Ethereal signer service URL is required" if signer_url.blank?
    blockers << "Ethereal signer service does not advertise Ethereal support" if signer_url.present? && !signer_supports_ethereal?
    blockers.concat(close_probe_position_blockers(mode: close_order.dig(:summary, :probe_mode), current_position: current_position, close_order: close_order, reopen_order: reopen_order))
    blockers.uniq
  end

  def close_probe_enabled?
    ActiveModel::Type::Boolean.new.cast(@env["AERODROME_ETHEREAL_CLOSE_PROBE_ENABLED"])
  end

  def submit_probe_leg(order:)
    signing = sign(order.fetch(:typed_data), order: order)
    unless signing[:status] == "signed"
      return { status: "failed_before_submit", blockers: [ signing[:reason] || "Ethereal signer did not return a signature" ], submit: nil }
    end

    payload = order.fetch(:submit_payload).deep_dup
    payload[:signature] = signing.fetch(:signature)
    parsed = parse_submit_response(post_order(payload))
    return { status: "failed_before_submit", blockers: [ parsed[:message] ], submit: parsed } unless parsed[:status] == "submitted"

    { status: "submitted", blockers: [], submit: parsed }
  end

  def close_reopen_probe_result(status:, blockers:, position:, mode:, dry_run:, before_position:, close_order:, close_submit: nil, close_poll: nil, flat_position: nil, reopen_order: nil, reopen_submit: nil, reopen_poll: nil, final_position: nil)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: "cross_close_reopen_probe",
      venue: "ethereal",
      mode: mode,
      dry_run: dry_run,
      position_id: position.id,
      source: position.respond_to?(:position_source) ? position.position_source : nil,
      source_external_id: position.respond_to?(:external_id) ? position.external_id : nil,
      before_readback: serialize_position(before_position),
      close_payload_summary: sanitized_order_summary(close_order),
      close_submit_classification: close_submit,
      close_poll_attempts: close_poll&.fetch(:attempts, []),
      flat_readback: serialize_position(flat_position),
      reopen_payload_summary: sanitized_order_summary(reopen_order),
      reopen_submit_classification: reopen_submit,
      reopen_poll_attempts: reopen_poll&.fetch(:attempts, []),
      final_readback: serialize_position(final_position),
      final_status: status,
      final_message: close_reopen_probe_message(status: status, mode: mode, dry_run: dry_run),
      orders_placed: probe_orders_placed(close_submit, reopen_submit),
      signatures_created: probe_orders_placed(close_submit, reopen_submit),
      exchange_order_ids: [ close_submit&.dig(:exchange_order_id), reopen_submit&.dig(:exchange_order_id) ].compact,
      manual_action_required: manual_action_required?(status),
      blockers: unique_messages(blockers),
      warnings: unique_messages(close_order.fetch(:warnings, []) + (reopen_order&.fetch(:warnings, []) || []))
    }.compact
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def probe_orders_placed(close_submit, reopen_submit)
    [ close_submit, reopen_submit ].compact.count { |submit| submit[:status] == "submitted" }
  end

  def close_reopen_probe_message(status:, mode:, dry_run:)
    return "Ethereal close/reopen probe dry-run only; no signature or order submission." if dry_run
    return "Ethereal close-only probe submitted and confirmed flat by readback." if status == "submitted_and_confirmed" && mode == "close_only"
    return "Ethereal close/reopen probe submitted and confirmed by readback." if status == "submitted_and_confirmed"
    return "Ethereal close probe submit accepted but flat readback was not confirmed; reopen was not submitted." if status == "submitted_but_readback_pending" && mode == "close_reopen"
    return "Ethereal close confirmed flat but reopen failed; manual action required." if status == "failed_after_close_manual_action_required"

    status
  end

  def execute(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true, migration: false)
    order = build_order_preview(position: position, action: action, size_eth: size_eth, current_position: current_position, max_slippage: max_slippage)
    blockers = live_blockers(position: position, action: action, size_eth: size_eth, current_position: current_position, confirmation: confirmation, order: order, require_confirmation: require_confirmation, migration: migration)
    return result("blocked_before_submit", blockers, order, position, action, current_position, nil, nil, nil) if blockers.any?

    signing = sign(order.fetch(:typed_data), order: order)
    unless signing[:status] == "signed"
      return result("failed_before_submit", [ signing[:reason] || "Ethereal signer did not return a signature" ], order, position, action, current_position, nil, nil, nil)
    end

    payload = order.fetch(:submit_payload).deep_dup
    payload[:signature] = signing.fetch(:signature)
    response = post_order(payload)
    parsed = parse_submit_response(response)
    unless parsed[:status] == "submitted"
      return result("failed_before_submit", [ parsed[:message] ], order, position, action, current_position, parsed, nil, nil)
    end

    expected = expected_short_after(action: action, size_eth: size_eth, current_position: current_position)
    readback = poll_post_submit_readback(expected_short: expected, action: action)
    status = readback[:confirmed] ? "submitted_and_confirmed" : "submitted_but_readback_pending"
    result(status, [], order, position, action, current_position, parsed, readback[:position], readback)
  rescue => e
    result("failed_before_submit", [ "#{e.class}: #{e.message}" ], order || {}, position, action, current_position, nil, nil, nil)
  end

  def live_blockers(position:, action:, size_eth:, current_position:, confirmation:, order:, require_confirmation: true, migration: false)
    blockers = order.fetch(:blockers).dup
    blockers << "selected hedge execution venue must be ethereal" if !migration && !position.hedge&.ethereal_execution?
    blockers << "Current active hedge venue is #{HedgeVenues.label(position.hedge.execution_venue)}; opening Ethereal would create a second hedge unless migration is intended." if !migration && position.hedge && !position.hedge.ethereal_execution?
    blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" unless @venue.live_enabled?
    blockers << "submitted confirmation must equal #{CONFIRMATION}" if require_confirmation && confirmation.to_s != CONFIRMATION
    blockers << "active hedge-ready Mellow position is required" unless position.active? && (!position.mellow_autopilot? || position.hedge_ready?)
    blockers << "ETHEREAL_LINKED_SIGNER_ADDRESS is required" if @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].blank?
    blockers << "ETHEREAL_SUBACCOUNT_ID or ETHEREAL_SUBACCOUNT_NAME is required" unless ethereal_subaccount_configured?
    blockers << "ETHEREAL_API_BASE_URL is required" if @env["ETHEREAL_API_BASE_URL"].blank?
    blockers << "Ethereal signer service URL is required" if signer_url.blank?
    blockers << "Ethereal signer service does not advertise Ethereal support" if signer_url.present? && !signer_supports_ethereal?
    blockers << "current Ethereal readback is unavailable" if current_position == :unavailable
    blockers << "current Ethereal position is long; manual action required" if position_size(current_position).positive?
    blockers << "target size is zero" if action.to_s == "open" && !BigDecimal(size_eth.to_s).positive?
    unique_messages(blockers)
  end

  def result(status, blockers, order, position, action, pre_position, submit_response, post_position, readback_poll)
    blockers = unique_messages(blockers)
    receipt = {
      timestamp: @now.call.utc.iso8601,
      action: action,
      venue: "ethereal",
      position_id: position.id,
      hedge_id: position.hedge&.id,
      margin_mode: "cross",
      pre_submit_readback: serialize_position(pre_position),
      submitted_order_summary: sanitized_order_summary(order),
      submit_response_classification: submit_response,
      exchange_order_id: submit_response&.dig(:exchange_order_id),
      expected_short_eth: order.dig(:summary, :expected_after_short_eth) || decimal_string(expected_short_after(action: action, size_eth: order.dig(:summary, :rounded_size_eth) || 0, current_position: pre_position)),
      readback_poll_attempts: readback_poll&.fetch(:attempts, []),
      post_submit_readback: serialize_position(post_position),
      final_status: status,
      final_message: blockers.presence&.join("; ") || submit_response&.dig(:message) || status,
      manual_action_required: status.to_s.include?("pending") || blockers.any?,
      blockers: blockers,
      warnings: order.fetch(:warnings, [])
    }
    Result.new(status, blockers, order.fetch(:warnings, []), receipt)
  end

  def poll_post_submit_readback(expected_short:, action:)
    attempts = []
    POST_SUBMIT_READBACK_ATTEMPTS.times do |index|
      position = read_position
      confirmed = readback_matches?(position, expected_short: expected_short, action: action)
      attempts << { attempt: index + 1, current_short_eth: decimal_string(short_size(position)), confirmed: confirmed, margin_mode: position.is_a?(Hash) ? position[:margin_mode] : nil }
      return { attempts: attempts, position: position, confirmed: true } if confirmed

      @sleeper.call(POST_SUBMIT_READBACK_DELAY_SECONDS)
    end
    { attempts: attempts, position: read_position, confirmed: false }
  end

  def readback_matches?(position, expected_short:, action:)
    return position.nil? || short_size(position).zero? if action.to_s == "close" && BigDecimal(expected_short.to_s).zero?
    return false unless position.is_a?(Hash)

    (short_size(position) - BigDecimal(expected_short.to_s)).abs <= BigDecimal("0.000001") && position[:margin_mode] == "cross"
  end

  def expected_short_after(action:, size_eth:, current_position:)
    current = short_size(current_position)
    size = BigDecimal(size_eth.to_s)
    case action.to_s
    when "open"
      size
    when "close"
      BigDecimal("0")
    when "rebalance"
      current + size
    else
      current
    end
  end

  def build_typed_data(quantity:, price:, side:, reduce_only:, subaccount: nil)
    now = @now.call
    message = {
      sender: @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].presence || "0x0000000000000000000000000000000000000000",
      subaccount: subaccount || trade_subaccount,
      quantity: scaled_decimal(quantity, 9).to_s,
      price: scaled_decimal(price, 9).to_s,
      reduceOnly: reduce_only,
      side: side == "buy" ? 0 : 1,
      engineType: 0,
      productId: ethereal_onchain_id,
      nonce: (now.to_r * 1_000_000_000).to_i.to_s,
      signedAt: now.to_i.to_s
    }
    {
      types: {
        EIP712Domain: [
          { name: "name", type: "string" },
          { name: "version", type: "string" },
          { name: "chainId", type: "uint256" },
          { name: "verifyingContract", type: "address" }
        ],
        TradeOrder: [
          { name: "sender", type: "address" },
          { name: "subaccount", type: "bytes32" },
          { name: "quantity", type: "uint128" },
          { name: "price", type: "uint128" },
          { name: "reduceOnly", type: "bool" },
          { name: "side", type: "uint8" },
          { name: "engineType", type: "uint8" },
          { name: "productId", type: "uint32" },
          { name: "nonce", type: "uint64" },
          { name: "signedAt", type: "uint64" }
        ]
      },
      primaryType: "TradeOrder",
      domain: domain,
      message: message
    }
  end

  def build_submit_payload(typed_data:, quantity:, price:, client_order_id:, signature:)
    msg = typed_data.fetch(:message)
    {
      data: {
        subaccount: msg.fetch(:subaccount),
        sender: msg.fetch(:sender),
        nonce: msg.fetch(:nonce),
        type: "LIMIT",
        quantity: decimal_string(quantity),
        side: msg.fetch(:side),
        onchainId: msg.fetch(:productId),
        engineType: msg.fetch(:engineType),
        clientOrderId: client_order_id,
        reduceOnly: msg.fetch(:reduceOnly),
        signedAt: msg.fetch(:signedAt).to_i,
        price: decimal_string(price),
        timeInForce: "IOC",
        postOnly: false
      },
      signature: signature
    }
  end

  def domain
    @domain ||= begin
      response = @http_get.call(uri_for("/v1/rpc/config"))
      config = JSON.parse(response.body)
      source = config["domain"].is_a?(Hash) ? config["domain"] : {}
      DOMAIN.merge(source.symbolize_keys)
    rescue
      DOMAIN
    end
  end

  def sign(typed_data, order:)
    response = @signer_post.call(signer_uri, {
      exchange: "Ethereal",
      action: "place_order",
      signing_standard: "eip712",
      canonical_symbol: DEFAULT_SYMBOL,
      exchange_symbol: EXCHANGE_SYMBOL,
      side: order.dig(:summary, :side),
      size_base: order.dig(:summary, :rounded_size_eth),
      price: order.dig(:summary, :price),
      reduce_only: order.dig(:summary, :reduce_only),
      subaccount_id: @env["ETHEREAL_SUBACCOUNT_ID"].presence || @env["ETHEREAL_SUBACCOUNT_NAME"],
      typed_data: typed_data,
      typed_data_hash: typed_data_hash(typed_data),
      expected_signer_address: @env["ETHEREAL_LINKED_SIGNER_ADDRESS"],
      forbidden_signer_address: @env["ETHEREAL_MAIN_WALLET_ADDRESS"],
      client_request_id: "delta-neutral-ethereal-#{SecureRandom.hex(8)}",
      payload_preview: sanitized_order_summary(order)&.except(:submit_payload)
    })
    body = response.respond_to?(:body) ? JSON.parse(response.body) : response
    status = body["status"] || body[:status]
    signature = body["signature"] || body[:signature]
    return { status: "signed", signature: signature } if status == "signed" && signature.present?

    { status: "blocked", reason: body["reason"] || body[:reason] || "Ethereal signer blocked" }
  rescue => e
    { status: "blocked", reason: "#{e.class}: #{e.message}" }
  end

  def post_order(payload)
    sanitized = payload.deep_dup
    sanitized[:signature] = "[REDACTED]"
    response = @http_post.call(uri_for("/v1/order"), payload)
    body = response.respond_to?(:body) ? JSON.parse(response.body) : response
    { http_status: response.respond_to?(:code) ? response.code.to_i : 200, body: body, request: sanitized }
  rescue => e
    { http_status: nil, body: { error: "#{e.class}: #{e.message}" }, request: sanitized }
  end

  def parse_submit_response(response)
    body = response[:body].is_a?(Hash) ? response[:body].with_indifferent_access : {}
    status = body[:status]
    order_id = body[:id] || body[:orderId] || body[:clientOrderId]
    if response[:http_status].to_i >= 400
      return { status: "rejected", message: "Ethereal order HTTP #{response[:http_status]}: #{body[:message] || body[:error]}", raw_response: body }
    end
    if status.in?([ "SUBMITTED", "PENDING", "NEW", "success", nil ])
      return { status: "submitted", message: status || "submitted", exchange_order_id: order_id, raw_response: body }
    end

    { status: "rejected", message: "Ethereal rejected order: #{status} #{body[:message] || body[:error]}", raw_response: body }
  end

  def preview_blockers(rounded_size:, price:, mapping_error:)
    blockers = []
    blockers << "rounded Ethereal order size is zero" unless rounded_size.positive?
    blockers << "Ethereal mark/limit price is unavailable" unless price&.positive?
    blockers << "ETHEREAL_ONCHAIN_ID is required for Ethereal order payloads" unless ethereal_onchain_id.positive?
    blockers << "ETHEREAL_SUBACCOUNT_ID or ETHEREAL_SUBACCOUNT_NAME is required for Ethereal order payloads" unless ethereal_subaccount_configured?
    blockers << mapping_error if mapping_error.present?
    unique_messages(blockers)
  end

  def sanitized_order_summary(order)
    return nil unless order

    {
      schema: order[:schema],
      endpoint: order[:endpoint],
      body_shape: order[:body_shape],
      market_symbol: order[:market_symbol],
      margin_mode: "cross",
      side: order.dig(:summary, :side),
      reduce_only: order.dig(:summary, :reduce_only),
      probe_direction: order.dig(:summary, :probe_direction),
      delta_probe: order.dig(:summary, :delta_probe),
      close_reopen: order.dig(:summary, :close_reopen),
      full_close: order.dig(:summary, :full_close),
      before_short_eth: order.dig(:summary, :before_short_eth),
      expected_after_short_eth: order.dig(:summary, :expected_after_short_eth),
      rounded_size_eth: order.dig(:summary, :rounded_size_eth),
      estimated_notional_usd: order.dig(:summary, :estimated_notional_usd),
      estimated_effective_leverage: order.dig(:summary, :estimated_effective_leverage),
      price: order.dig(:summary, :price),
      onchain_id: order.dig(:summary, :onchain_id),
      client_order_id: order.dig(:summary, :client_order_id),
      typed_data_hash: typed_data_hash(order[:typed_data]),
      submit_payload: redact_payload(order[:submit_payload])
    }.compact
  end

  def position_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)

    BigDecimal(position.fetch(:size).to_s)
  rescue
    BigDecimal("0")
  end

  def short_size(position)
    size = position_size(position)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def serialize_position(position)
    return nil unless position.is_a?(Hash)

    position.except(:raw)
  end

  def eth_price(position:, current_position:)
    decimal_or_nil(current_position&.dig(:mark_price)) || position_price(position)
  end

  def position_price(position)
    if position.mellow_autopilot? && position.mellow_weth_exposure&.positive? && position.mellow_current_value_usd
      usdc = position.mellow_usdc_exposure || BigDecimal("0")
      return (position.mellow_current_value_usd - usdc) / position.mellow_weth_exposure
    end

    position.asset0_price_usd || position.asset1_price_usd
  end

  def limit_price(mark_price, side:, max_slippage:)
    price = decimal_or_nil(mark_price)
    return nil unless price&.positive?

    slippage = decimal_or_nil(max_slippage) || DEFAULT_MAX_SLIPPAGE
    raw = side == "buy" ? price * (1 + slippage) : price * (1 - slippage)
    tick = ethereal_tick_size
    return raw unless tick&.positive?

    units = raw / tick
    rounded_units = side == "buy" ? units.ceil : units.floor
    rounded_units * tick
  end

  def ethereal_tick_size
    decimal_or_nil(@env["ETHEREAL_TICK_SIZE"]) || decimal_or_nil(market_metadata_value(:tick_size)) || ETHUSD_TICK_SIZE
  end

  def ethereal_onchain_id
    value = @env["ETHEREAL_ONCHAIN_ID"].presence || market_metadata_value(:raw)&.dig("onchainId") || market_metadata_value(:raw)&.dig("id")
    value.present? ? value.to_i : ETHUSD_ONCHAIN_ID
  end

  def market_metadata_value(key)
    @market_metadata ||= @venue.send(:probe).market_metadata
    @market_metadata.public_send(key)
  rescue
    nil
  end

  def trade_subaccount
    override = @env["ETHEREAL_SUBACCOUNT_NAME"].presence
    return validated_bytes32_subaccount(override, source: "ETHEREAL_SUBACCOUNT_NAME") if override

    value = @env["ETHEREAL_SUBACCOUNT_ID"].to_s
    return validated_bytes32_subaccount(value, source: "ETHEREAL_SUBACCOUNT_ID") if bytes32?(value)
    return mapped_uuid_subaccount(value) if uuid?(value)

    encoded = value.bytes.map { |byte| byte.to_s(16).rjust(2, "0") }.join
    "0x#{encoded.ljust(64, '0')}"
  end

  def ethereal_subaccount_configured?
    @env["ETHEREAL_SUBACCOUNT_ID"].present? || @env["ETHEREAL_SUBACCOUNT_NAME"].present?
  end

  def unique_messages(messages)
    messages.compact.map(&:to_s).reject(&:blank?).uniq
  end

  def mapped_uuid_subaccount(value)
    response = @http_get.call(uri_for("/v1/subaccount/#{value}"))
    body = response.respond_to?(:body) ? JSON.parse(response.body) : response
    data = body["data"].is_a?(Hash) ? body["data"] : body
    validated_bytes32_subaccount(data["name"].to_s, source: "GET /v1/subaccount/{id} response.name")
  end

  def validated_bytes32_subaccount(value, source:)
    normalized = "0x#{value.to_s.delete_prefix('0x').downcase}" if bytes32?(value)
    return normalized if normalized.present? && normalized != zero_bytes32

    raise "Ethereal signed subaccount mapping unavailable/zero; source=#{source}"
  end

  def bytes32?(value)
    text = value.to_s
    cleaned = text.delete_prefix("0x")
    text.start_with?("0x") && cleaned.length == 64 && cleaned.match?(/\A[0-9a-f]+\z/i)
  end

  def zero_bytes32
    "0x#{"00" * 32}"
  end

  def uuid?(value)
    value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
  end

  def scaled_decimal(value, decimals)
    (BigDecimal(value.to_s) * (BigDecimal("10")**decimals)).floor
  end

  def ethereal_client_order_id(value)
    text = value.to_s.gsub(/[^A-Za-z0-9]/, "")
    return text[0, 32] if text.present? && text.length <= 32

    Digest::SHA256.hexdigest(value.to_s)[0, 32]
  end

  def typed_data_hash(typed_data)
    "sha256:#{Digest::SHA256.hexdigest(JSON.generate(typed_data.deep_stringify_keys.sort.to_h))}"
  rescue
    nil
  end

  def redact_payload(payload)
    return nil unless payload

    payload.deep_dup.tap { |copy| copy[:signature] = "[REDACTED]" }
  end

  def decimal_string(value)
    return nil unless value

    BigDecimal(value.to_s).to_s("F")
  rescue
    nil
  end

  def decimal_or_nil(value)
    return value if value.is_a?(BigDecimal)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue
    nil
  end

  def uri_for(path)
    URI.join(@env.fetch("ETHEREAL_API_BASE_URL"), path)
  end

  def signer_url
    @env["EXECUTION_SIGNER_URL"].presence || @env["NADO_SIGNER_URL"].presence
  end

  def signer_uri
    return URI(signer_url) if signer_url.to_s.end_with?("/sign/eip712")

    URI.join(signer_url.end_with?("/") ? signer_url : "#{signer_url}/", "sign/eip712")
  end

  def signer_supports_ethereal?
    return true unless @signer_post.is_a?(Method)

    response = @http_get.call(signer_health_uri)
    return false unless response.respond_to?(:body)

    body = JSON.parse(response.body)
    body["ok"] == true &&
      Array(body["supported_exchanges"]).map(&:to_s).include?("Ethereal") &&
      Array(body["supported_actions"]).map(&:to_s).include?("place_order")
  rescue
    false
  end

  def signer_health_uri
    raw = signer_url.to_s
    return URI(raw.sub(%r{/sign/eip712/?\z}, "/health")) if raw.end_with?("/sign/eip712")

    URI.join(raw.end_with?("/") ? raw : "#{raw}/", "health")
  end

  def http_get(uri)
    Net::HTTP.get_response(uri)
  end

  def http_post(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
  end

  def signer_post(uri, payload)
    http_post(uri, payload)
  end
end
