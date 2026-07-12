class ExtendedMainnetLifecycleCheck
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS".freeze
  MODES = %w[open_only rebalance_delta close_only delta_round_trip close_reopen].freeze
  DEFAULT_READBACK_ATTEMPTS = 6
  DEFAULT_READBACK_INTERVAL_SECONDS = BigDecimal("0.5")
  FILL_CONFIRM_ATTEMPTS = 6
  FILL_CONFIRM_INTERVAL_SECONDS = BigDecimal("0.25")
  FILL_LOT_TOLERANCE_ETH = BigDecimal("0.001")
  TERMINAL_FILLED_ORDER_STATUSES = %w[FILLED].freeze
  FILL_MARKET_SYMBOL = "ETH-USD".freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) }, order_probe: nil)
    @env = env
    @venue = venue
    @signer_client = signer_client
    @now = now
    @sleeper = sleeper
    @order_probe = order_probe || HedgeBackends::ExtendedReadOnlyProbe.new(env: env)
  end

  def run(position:, mode:, size_eth:, confirmation:, dry_run: true, max_slippage: "0.01", delta_eth: nil, size_source: "probe_cap")
    # Open a per-leg read snapshot for the BUILD phase so blockers/preview/diagnostics
    # reuse one read per Extended endpoint. Only own it if a caller (the migration leg
    # runner) has not already opened one. Post-submit reads stay fresh (see sign_and_submit).
    owns_snapshot = @venue.respond_to?(:begin_read_snapshot!) && !@venue.read_snapshot_active?
    @venue.begin_read_snapshot! if owns_snapshot
    mode = mode.to_s
    timing = {}
    mark_timing!(timing, :build_started_at)
    requested_size = requested_size_for(mode: mode, size_eth: size_eth, delta_eth: delta_eth)
    return missing_size_result(position: position, mode: mode, dry_run: dry_run, size_source: size_source) unless requested_size&.positive? || mode == "close_only"

    sizing = sizing_plan(mode: mode, requested_size: requested_size, size_source: size_source)
    current_position = @venue.read_position(symbol: "ETH")
    orders = build_orders(position: position, mode: mode, size_eth: sizing.fetch(:submitted_size), current_position: current_position, max_slippage: max_slippage, delta_eth: delta_eth)
    mark_timing!(timing, :build_finished_at)
    dry_run_signer_health = signer_health_for_diagnostics if dry_run
    blockers = structural_blockers(mode: mode, orders: orders, dry_run: dry_run, signer_health: dry_run_signer_health)

    if dry_run
      return result(
        status: "dry_run",
        blockers: blockers,
        position: position,
        mode: mode,
        dry_run: true,
        current_position: current_position,
        orders: orders,
        signer_health: dry_run_signer_health,
        sizing: sizing,
        timing: finalized_timing(timing)
      )
    end

    blockers.concat(live_blockers(mode: mode, confirmation: confirmation, orders: orders, current_position: current_position))
    blockers.concat(sizing_blockers(sizing))
    if blockers.any?
      return result(
        status: "blocked_before_submit",
        blockers: blockers.uniq,
        position: position,
        mode: mode,
        dry_run: false,
        current_position: current_position,
        orders: orders,
        sizing: sizing,
        timing: finalized_timing(timing)
      )
    end

    mark_timing!(timing, :sign_started_at)
    signer_health = @signer_client.health
    mark_timing!(timing, :sign_finished_at)
    blockers.concat(signer_health_blockers(signer_health))

    if blockers.any?
      return result(
        status: "blocked_before_submit",
        blockers: blockers.uniq,
        position: position,
        mode: mode,
        dry_run: false,
        current_position: current_position,
        orders: orders,
        signer_health: signer_health,
        sizing: sizing,
        timing: finalized_timing(timing)
      )
    end

    signed_result = mode == "delta_round_trip" ? sign_and_submit_sequence(orders: orders, timing: timing) : sign_and_submit(order_preview: orders.first, mode: mode, timing: timing)
    final_status = signed_result.fetch(:final_status)
    result(
      status: final_status,
      blockers: [],
      position: position,
      mode: mode,
      dry_run: false,
      current_position: current_position,
      orders: orders,
      signer_health: signer_health,
      execution: signed_result,
      sizing: sizing,
      timing: signed_result[:timing] || finalized_timing(timing)
    )
  ensure
    @venue.end_read_snapshot! if owns_snapshot
  end

  private

  def build_orders(position:, mode:, size_eth:, current_position:, max_slippage:, delta_eth: nil)
    case mode
    when "open_only"
      [ @venue.open_short_preview(symbol: "ETH", size_eth: size_eth, max_slippage: max_slippage) ]
    when "rebalance_delta"
      signed_delta = BigDecimal(delta_eth.presence || size_eth.to_s)
      [ @venue.rebalance_preview(symbol: "ETH", delta_eth: signed_delta, max_slippage: max_slippage) ]
    when "close_only"
      [ @venue.close_preview(symbol: "ETH", size_eth: short_size(current_position)) ]
    when "delta_round_trip"
      open_size = size_eth * 2
      [
        with_probe_leg(@venue.open_short_preview(symbol: "ETH", size_eth: open_size, max_slippage: max_slippage), "open"),
        with_probe_leg(@venue.rebalance_preview(symbol: "ETH", delta_eth: -size_eth, max_slippage: max_slippage), "decrease"),
        with_probe_leg(@venue.rebalance_preview(symbol: "ETH", delta_eth: size_eth, max_slippage: max_slippage), "increase"),
        with_probe_leg(@venue.close_preview(symbol: "ETH", size_eth: open_size), "close")
      ]
    when "close_reopen"
      [
        @venue.close_preview(symbol: "ETH", size_eth: short_size(current_position)),
        @venue.open_short_preview(symbol: "ETH", size_eth: target_size(position), max_slippage: max_slippage)
      ]
    else
      []
    end
  end

  def with_probe_leg(order, leg)
    order.merge(probe_leg: leg, payload: order.fetch(:payload).merge(probe_leg: leg))
  end

  def structural_blockers(mode:, orders:, dry_run:, signer_health:)
    blockers = []
    blockers << "mode must be one of #{MODES.join(', ')}" unless mode.in?(MODES)
    blockers << "Extended live submit currently supports open_only, rebalance_delta, delta_round_trip, and close_only probes only" if !dry_run && !mode.in?(%w[open_only rebalance_delta delta_round_trip close_only])
    blockers.concat(dry_run ? @venue.blockers : @venue.live_readiness_blockers)
    blockers.concat(orders.flat_map { |order| order.fetch(:blockers, []) }) if dry_run
    blockers.concat(orders.flat_map { |order| @venue.live_order_blockers(preview: order) }) unless dry_run
    blockers.concat(mode_position_blockers(mode: mode, current_position: @venue.read_position(symbol: "ETH")))
    blockers.concat(dry_run_signer_blockers(signer_health)) if dry_run
    blockers.uniq
  end

  def live_blockers(mode:, confirmation:, orders:, current_position:)
    blockers = []
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" unless bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false for manual Extended mainnet probe" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "EXTENDED_SIGNER_URL is required" if @env["EXTENDED_SIGNER_URL"].blank?
    blockers.concat(mode_position_blockers(mode: mode, current_position: current_position))
    # Same open-orders safety gate, via the dedicated single-call read: the full
    # account_state aggregate (4 reads incl. the chronically slow account-info
    # section) sat on the close leg's double-exposure critical path (~3s).
    blockers << "#{mode} live probe requires open_orders_count=0" unless @venue.open_orders_count.to_i.zero?
    return blockers unless mode == "open_only" || rebalance_increase?(orders.first)

    account_value = BigDecimal(@venue.account_state.dig(:read_only_diagnostics, :account_value_usd).to_s)
    notional = BigDecimal(orders.first&.dig(:payload, :estimated_notional_usd).to_s)
    blockers << "Extended account value unavailable or insufficient for probe notional" unless account_value.positive? && account_value >= notional
    blockers
  rescue ArgumentError
    blockers << "Extended account value unavailable or insufficient for probe notional"
    blockers
  end

  def signer_health_blockers(health)
    blockers = []
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless signer_health_supports_extended_order?(health)
    blockers << "Extended Stark signer verified_algorithm=false" unless signer_health_verified_algorithm?(health)
    blockers << "Extended Stark signer signing_enabled=false" unless signer_health_signing_enabled?(health)
    if health[:stark_public_key].present? && expected_redacted_stark_public_key.present? && health[:stark_public_key] != expected_redacted_stark_public_key
      blockers << "Extended signer Stark public key does not match EXTENDED_STARK_PUBLIC_KEY"
    end
    blockers
  end

  def dry_run_signer_blockers(health)
    return [ "EXTENDED_SIGNER_URL is required for Extended live submit" ] if @env["EXTENDED_SIGNER_URL"].blank?
    return [ "Extended signer health unavailable" ] unless health

    blockers = []
    blockers << "Extended signer unhealthy: #{health[:reason]}" if health[:reason].present? && !signer_health_ok?(health)
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless signer_health_supports_extended_order?(health)
    blockers << "Extended Stark signer verified_algorithm=false" unless signer_health_verified_algorithm?(health)
    blockers << "Extended Stark signer signing_enabled=false" unless signer_health_signing_enabled?(health)
    blockers
  end

  def mode_position_blockers(mode:, current_position:)
    case mode
    when "open_only"
      current_position ? [ "open_only live probe requires no current Extended position" ] : []
    when "close_only"
      short_size(current_position).positive? ? [] : [ "close_only probe requires current Extended short position" ]
    when "rebalance_delta"
      short_size(current_position).positive? ? [] : [ "rebalance_delta probe requires current Extended short position" ]
    when "delta_round_trip"
      short_size(current_position).zero? ? [] : [ "delta_round_trip probe requires Extended to be flat before opening the probe short" ]
    else
      []
    end
  end

  def sign_and_submit_sequence(orders:, timing:)
    legs = []

    orders.each do |order_preview|
      open_orders_count = @venue.account_state[:open_orders_count].to_i
      if open_orders_count.nonzero?
        legs << {
          leg: order_preview[:probe_leg],
          final_status: "blocked_before_submit",
          blockers: [ "delta_round_trip leg #{order_preview[:probe_leg]} requires open_orders_count=0" ],
          orders_placed: 0,
          signatures_created: 0,
          submitted: false
        }
        break
      end

      leg_mode = order_preview[:probe_leg] == "close" ? "close_only" : "rebalance_delta"
      leg_result = sign_and_submit(order_preview: order_preview, mode: leg_mode, timing: {}).merge(leg: order_preview[:probe_leg])
      legs << leg_result
      break unless leg_result[:final_status] == "success"
    end

    sequence_status = legs.size == orders.size && legs.all? { |leg| leg[:final_status] == "success" } ? "success" : legs.last&.fetch(:final_status, "blocked_before_submit")
    {
      final_status: sequence_status,
      legs: legs,
      unsigned_order: legs.last&.fetch(:unsigned_order, nil),
      signer_response: legs.last&.fetch(:signer_response, nil),
      submit_payload: legs.last&.fetch(:submit_payload, nil),
      submit_response: legs.last&.fetch(:submit_response, nil),
      exchange_order_id: legs.last&.fetch(:exchange_order_id, nil),
      readback_attempts: legs.flat_map { |leg| Array(leg[:readback_attempts]).map { |attempt| attempt.merge(leg: leg[:leg]) } },
      orders_placed: legs.sum { |leg| leg[:orders_placed].to_i },
      signatures_created: legs.sum { |leg| leg[:signatures_created].to_i },
      submitted: legs.any? { |leg| leg[:submitted] },
      blockers: legs.flat_map { |leg| Array(leg[:blockers]) }.uniq,
      timing: sequence_timing(timing, legs)
    }
  end

  def sign_and_submit(order_preview:, mode:, timing:)
    mark_timing!(timing, :sign_started_at) unless timing[:sign_started_at]
    unsigned_order = @venue.extended_live_order(preview: order_preview, now: @now.call)
    signer_response = @signer_client.sign_order(unsigned_order)
    mark_timing!(timing, :sign_finished_at)
    unless signer_response[:status] == "signed"
      return {
        final_status: "blocked_before_submit",
        unsigned_order: unsigned_order,
        signer_response: sanitize_signer_response(signer_response),
        submit_response: nil,
        exchange_order_id: nil,
        readback_attempts: [],
        orders_placed: 0,
        signatures_created: 0,
        submitted: false,
        timing: finalized_timing(timing)
      }
    end

    submit_payload = signed_submit_payload(unsigned_order, signer_response)
    expected_short = expected_short_after(order_preview: order_preview, current_position: @venue.read_position(symbol: "ETH"))
    mark_timing!(timing, :submit_started_at)
    submit_response = @venue.submit_order(submit_payload)
    mark_timing!(timing, :submit_finished_at)
    order_id = exchange_order_id(submit_response, signer_response)
    timing[:exchange_accept_at] = timing[:submit_finished_at] if order_id.present?
    # Post-submit: drop the build snapshot's volatile reads (positions/balance/open_orders)
    # so the readback and receipt diagnostics never reuse pre-submit state.
    @venue.invalidate_volatile_reads! if @venue.respond_to?(:invalidate_volatile_reads!)
    mark_timing!(timing, :readback_started_at)
    confirmation = confirm_after_submit(mode: mode, order_preview: order_preview, expected_short: expected_short, order_id: order_id)
    readback_attempts = confirmation[:attempts]
    confirmed = confirmation[:confirmed]
    mark_timing!(timing, confirmed ? :readback_confirmed_at : :readback_finished_at)
    final_status = confirmed ? "success" : unconfirmed_status(readback_attempts: readback_attempts, expected_short: expected_short, mode: mode)
    {
      final_status: final_status,
      unsigned_order: unsigned_order,
      signer_response: sanitize_signer_response(signer_response),
      submit_payload: sanitize_submit_payload(submit_payload),
      submit_response: sanitize_submit_response(submit_response),
      exchange_order_id: order_id,
      readback_attempts: readback_attempts,
      readback_confirmation_source: confirmation[:confirmation_source],
      open_fill_confirmation: build_open_fill_confirmation(mode: mode, confirmation: confirmation, timing: timing, order_preview: order_preview),
      close_fill_confirmation: build_close_fill_confirmation(mode: mode, confirmation: confirmation, timing: timing, order_preview: order_preview),
      expected_after_short_eth: expected_short.to_s("F"),
      readback_short_after_submit: last_readback_size(readback_attempts)&.to_s("F"),
      readback_delta_eth: readback_delta(readback_attempts: readback_attempts, expected_short: expected_short)&.to_s("F"),
      orders_placed: 1,
      signatures_created: 1,
      submitted: true,
      timing: finalized_timing(timing, readback_attempts: readback_attempts, poll_interval_seconds: extended_readback_interval_seconds)
    }
  end

  def result(status:, blockers:, position:, mode:, dry_run:, current_position:, orders:, signer_health: nil, execution: nil, sizing: nil, timing: nil)
    first_payload = orders.first&.fetch(:payload, {}) || {}
    expected_after = execution&.fetch(:expected_after_short_eth, nil)
    readback_after = execution&.fetch(:readback_short_after_submit, nil)
    readback_delta = execution&.fetch(:readback_delta_eth, nil)
    receipt = {
      venue: "extended",
      action: "mainnet_lifecycle_check",
      mode: mode,
      dry_run: dry_run,
      position_id: position.id,
      timestamp: @now.call.utc.iso8601,
      selected_venue: "extended",
      requested_size_eth: sizing&.fetch(:requested_size, nil)&.to_s("F"),
      submitted_size_eth: first_payload[:rounded_size_eth] || sizing&.fetch(:submitted_size, nil)&.to_s("F"),
      quantity_sent_to_extended: first_payload[:rounded_size_eth],
      side: first_payload[:extended_side],
      reduce_only: first_payload[:reduce_only],
      size_source: sizing&.fetch(:size_source, nil),
      cap_key: sizing&.fetch(:cap_key, nil),
      cap_value: sizing&.fetch(:cap_value, nil)&.to_s("F"),
      cap_source: sizing&.fetch(:cap_source, nil),
      partial: sizing&.fetch(:partial, false),
      partial_reason: sizing&.fetch(:partial_reason, nil),
      expected_after_short_eth: expected_after,
      readback_short_after_submit: readback_after,
      readback_delta_eth: readback_delta,
      inside_tolerance_after_submit: readback_delta ? BigDecimal(readback_delta.to_s).abs <= BigDecimal("0.001") : nil,
      current_position: current_position,
      read_only_account_diagnostics: read_only_account_diagnostics_for(execution: execution, current_position: current_position),
      market_metadata: @venue.market_metadata_diagnostics,
      order_payload_summaries: orders.map { |order| order[:payload] },
      signer_health: sanitize_signer_health(signer_health),
      signer_request: execution ? sanitize_submit_payload(execution[:unsigned_order]) : orders.first&.dig(:payload, :signer_request),
      signer_response: execution && execution[:signer_response],
      submit_payload: execution && execution[:submit_payload],
      submit_response: execution && execution[:submit_response],
      exchange_order_id: execution && execution[:exchange_order_id],
      readback_confirmation_source: execution && execution[:readback_confirmation_source],
      open_fill_confirmation: execution && execution[:open_fill_confirmation],
      close_fill_confirmation: execution && execution[:close_fill_confirmation],
      execution_timing: execution && execution[:timing],
      leg_summaries: execution && execution[:legs]&.map { |leg| leg_summary(leg) },
      readback_attempts: execution ? execution[:readback_attempts] : [],
      orders_placed: execution ? execution[:orders_placed] : 0,
      signatures_created: execution ? execution[:signatures_created] : 0,
      submitted: execution ? execution[:submitted] : false,
      final_status: status,
      blockers: (blockers + Array(execution && execution[:blockers])).uniq,
      warnings: [ "Extended mainnet path is manual-only and controlled by explicit live gates." ]
    }.merge(timing_payload(execution&.fetch(:timing, nil) || timing))
    Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
  end

  def leg_summary(leg)
    {
      leg: leg[:leg],
      final_status: leg[:final_status],
      exchange_order_id: leg[:exchange_order_id],
      orders_placed: leg[:orders_placed],
      signatures_created: leg[:signatures_created],
      submitted: leg[:submitted],
      unsigned_order: sanitize_submit_payload(leg[:unsigned_order]),
      signer_response: leg[:signer_response],
      submit_payload: leg[:submit_payload],
      submit_response: leg[:submit_response],
      execution_timing: leg[:timing],
      readback_attempts: leg[:readback_attempts],
      blockers: leg[:blockers]
    }.compact
  end

  def requested_size_for(mode:, size_eth:, delta_eth:)
    raw = mode == "rebalance_delta" && delta_eth.present? ? delta_eth : size_eth
    return nil if raw.blank?

    BigDecimal(raw.to_s).abs
  rescue ArgumentError
    nil
  end

  def missing_size_result(position:, mode:, dry_run:, size_source:)
    blockers = [ "Extended live open size could not be computed; refusing to default to probe/min size." ]
    result(
      status: dry_run ? "dry_run" : "blocked_before_submit",
      blockers: blockers,
      position: position,
      mode: mode,
      dry_run: dry_run,
      current_position: nil,
      orders: [],
      sizing: {
        requested_size: nil,
        submitted_size: nil,
        size_source: size_source,
        partial: false,
        blockers: blockers
      }
    )
  end

  def sizing_plan(mode:, requested_size:, size_source:)
    if probe_capped_size_source?(size_source)
      submitted = capped_size(requested_size)
      cap = probe_cap
      {
        requested_size: requested_size,
        submitted_size: submitted,
        size_source: size_source,
        cap_key: "EXTENDED_PROBE_MAX_SIZE_ETH",
        cap_value: cap,
        cap_source: @env["EXTENDED_PROBE_MAX_SIZE_ETH"].present? ? "env" : "default_probe_max_size",
        partial: submitted < requested_size,
        partial_reason: submitted < requested_size ? "probe size cap" : nil,
        blockers: []
      }
    else
      {
        requested_size: requested_size,
        submitted_size: requested_size,
        size_source: size_source,
        cap_key: nil,
        cap_value: nil,
        cap_source: nil,
        partial: false,
        partial_reason: nil,
        blockers: []
      }
    end
  end

  def probe_capped_size_source?(size_source)
    size_source.to_s.in?(%w[probe probe_cap delta_round_trip migration_canary])
  end

  def sizing_blockers(sizing)
    return [] if sizing.nil?
    return Array(sizing[:blockers]) if sizing[:partial] == false

    [ "Extended live order was capped by #{sizing[:cap_key]} from #{sizing[:requested_size].to_s('F')} ETH to #{sizing[:submitted_size].to_s('F')} ETH; normal dashboard opens require explicit uncapped server sizing." ]
  end

  def capped_size(size_eth)
    requested = BigDecimal(size_eth.to_s)
    [ requested, probe_cap ].min
  end

  def probe_cap
    BigDecimal((@env["EXTENDED_PROBE_MAX_SIZE_ETH"].presence || default_probe_max_size).to_s)
  end

  def default_probe_max_size
    min_size = BigDecimal(@venue.market_metadata_diagnostics[:min_size].to_s)
    [ BigDecimal("0.005"), min_size ].max
  rescue ArgumentError
    BigDecimal("0.005")
  end

  def target_size(position)
    hedge = position.hedge
    valuation = PositionValuation.current(position)
    exposure = valuation.weth_exposure || (position.mellow_weth_exposure if position.respond_to?(:mellow_weth_exposure))
    return BigDecimal("0") unless hedge && exposure

    BigDecimal(exposure.to_s) * BigDecimal(hedge.target.to_s)
  end

  def short_size(position)
    BigDecimal(position&.fetch(:short_size, 0).to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def sanitize_signer_health(payload)
    return nil unless payload

    sanitize_sensitive(payload)
  end

  def sanitize_signer_response(payload)
    return nil unless payload

    sanitize_sensitive(payload)
  end

  def sanitize_submit_payload(payload)
    return nil unless payload

    sanitize_sensitive(payload)
  end

  def sanitize_submit_response(payload)
    sanitize_sensitive(payload)
  end

  def signed_submit_payload(unsigned_order, signer_response)
    unsigned_order.slice(
      "market", "type", "side", "qty", "price", "reduceOnly", "postOnly",
      "timeInForce", "expiryEpochMillis", "fee", "nonce", "selfTradeProtectionLevel"
    ).merge(
      "id" => signer_response.fetch(:order_id),
      "settlement" => signer_response.fetch(:settlement),
      "debuggingAmounts" => signer_response[:debuggingAmounts]
    )
  end

  def poll_short_readback(expected_size:)
    extended_readback_attempts.times.map do |index|
      @sleeper.call(extended_readback_interval_seconds.to_f) if index.positive?
      position = @venue.read_position(symbol: "ETH", force: true)
      size = position ? short_size(position) : nil
      {
        attempt: index + 1,
        short_size: size&.to_s("F"),
        side: position&.fetch(:side, nil),
        confirmed: position&.fetch(:side, nil) == "short" && size && (size - expected_size).abs <= BigDecimal("0.001")
      }
    rescue ArgumentError
      { attempt: index + 1, confirmed: false }
    end
  end

  def unconfirmed_status(readback_attempts:, expected_short:, mode:)
    return "submitted_but_readback_pending" if readback_attempts.empty?

    actual = last_readback_size(readback_attempts)
    return "submitted_but_readback_pending" unless actual
    return "submitted_but_readback_pending" if mode == "close_only"

    actual < expected_short ? "underfilled" : "submitted_but_not_confirmed"
  end

  def last_readback_size(readback_attempts)
    last = readback_attempts.reverse.find { |attempt| attempt[:short_size].present? }
    BigDecimal(last[:short_size].to_s) if last
  rescue ArgumentError
    nil
  end

  def readback_delta(readback_attempts:, expected_short:)
    actual = last_readback_size(readback_attempts)
    actual - expected_short if actual
  end

  def expected_short_after(order_preview:, current_position:)
    payload = order_preview.fetch(:payload)
    qty = BigDecimal(payload.fetch(:rounded_size_eth).to_s)
    current = short_size(current_position)

    if payload.fetch(:extended_side).to_s == "BUY" && payload.fetch(:reduce_only)
      [ current - qty, BigDecimal("0") ].max
    else
      current + qty
    end
  end

  def poll_flat_readback
    extended_readback_attempts.times.map do |index|
      @sleeper.call(extended_readback_interval_seconds.to_f) if index.positive?
      position = @venue.read_position(symbol: "ETH", force: true)
      size = short_size(position)
      {
        attempt: index + 1,
        short_size: size.to_s("F"),
        side: position&.fetch(:side, nil),
        confirmed: position.nil? || size <= BigDecimal("0.001")
      }
    rescue ArgumentError
      { attempt: index + 1, confirmed: false }
    end
  end

  def extended_readback_attempts
    [ @env.fetch("EXTENDED_POST_SUBMIT_READBACK_ATTEMPTS", DEFAULT_READBACK_ATTEMPTS).to_i, 1 ].max
  end

  def extended_readback_interval_seconds
    BigDecimal(@env.fetch("EXTENDED_POST_SUBMIT_READBACK_INTERVAL_SECONDS", DEFAULT_READBACK_INTERVAL_SECONDS).to_s)
  rescue ArgumentError
    DEFAULT_READBACK_INTERVAL_SECONDS
  end

  # Confirms a submitted order. When the (default-OFF) fast fill flag for the action
  # is enabled and an order id is present, first try the authoritative order-fill
  # readback (order-by-id). Only a terminal FILLED order of the right reduce-only
  # sense and at least the submitted size confirms. Anything partial/ambiguous/
  # unavailable falls back fail-closed to the existing slow position readback.
  def confirm_after_submit(mode:, order_preview:, expected_short:, order_id:)
    close = mode == "close_only"
    if order_id.present?
      if close && close_fill_confirmation_enabled?
        fast = fast_close_fill_readback(order_id: order_id, close_size: order_size(order_preview))
        return fast unless fast[:fall_back]
      elsif !close && open_fill_confirmation_enabled?
        fast = fast_open_fill_readback(order_id: order_id, open_size: order_size(order_preview))
        return fast unless fast[:fall_back]
      end
    end

    attempts = close ? poll_flat_readback : poll_short_readback(expected_size: expected_short)
    { attempts: attempts, confirmed: attempts.any? { |attempt| attempt[:confirmed] }, confirmation_source: "extended_position_readback" }
  end

  def open_fill_confirmation_enabled?
    ActiveModel::Type::Boolean.new.cast(@env["EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED"])
  end

  def close_fill_confirmation_enabled?
    ActiveModel::Type::Boolean.new.cast(@env["EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED"])
  end

  def order_size(order_preview)
    decimal_or_nil(order_preview.fetch(:payload)[:rounded_size_eth]) || BigDecimal("0")
  end

  def fast_open_fill_readback(order_id:, open_size:)
    fast_fill_readback(order_id: order_id) { |order| classify_open_fill(order, size: open_size) }
  end

  def fast_close_fill_readback(order_id:, close_size:)
    fast_fill_readback(order_id: order_id) { |order| classify_close_fill(order, size: close_size) }
  end

  # Bounded poll of the authoritative order status. Never confirms a partial: a
  # :partial short-circuits to the fail-closed position-readback fallback, and an
  # unresolved/unavailable order after the attempts also falls back.
  def fast_fill_readback(order_id:)
    attempts = []
    FILL_CONFIRM_ATTEMPTS.times do |index|
      order = @order_probe.find_order(order_id)
      classification = yield(order)
      attempts << { attempt: index + 1, source: "extended_order_by_id_fill", classification: classification.to_s, order_status: order_status_digest(order) }
      if classification == :filled
        return {
          attempts: attempts,
          confirmed: true,
          confirmation_source: "extended_order_by_id_fill",
          fill: { filled_eth: order[:filled_eth], remaining_eth: order[:remaining_eth], status: order[:status], reduce_only: order[:reduce_only], side: order[:side], market: order[:market] },
          fall_back: false
        }
      end
      break if classification == :partial

      @sleeper.call(FILL_CONFIRM_INTERVAL_SECONDS.to_f)
    end
    { attempts: attempts, confirmed: false, confirmation_source: "extended_order_by_id_fill_unresolved", fall_back: true }
  end

  # :filled only when the order is non-reduce-only, terminally FILLED, on the hedge
  # market, on the SELL side, filled at least the open size (remaining within one
  # lot). :partial when some filled but not complete. else :unknown -> fallback.
  def classify_open_fill(order, size:)
    classify_fill(order, size: size, reduce_only_expected: false, expected_side: "SELL")
  end

  # :filled only when the order is reduce-only, terminally FILLED, on the hedge
  # market, on the BUY side, filled at least the close size (remaining within one lot).
  def classify_close_fill(order, size:)
    classify_fill(order, size: size, reduce_only_expected: true, expected_side: "BUY")
  end

  def classify_fill(order, size:, reduce_only_expected:, expected_side:)
    return :unknown unless order.is_a?(Hash)
    return :unknown unless order[:reduce_only] == reduce_only_expected
    return :unknown unless order[:market].to_s.upcase == FILL_MARKET_SYMBOL.upcase
    return :unknown unless order[:side].to_s.upcase == expected_side

    filled = decimal_or_nil(order[:filled_eth])
    remaining = decimal_or_nil(order[:remaining_eth])
    return :unknown if filled.nil?

    lot = FILL_LOT_TOLERANCE_ETH
    terminal = order[:status].to_s.upcase.in?(TERMINAL_FILLED_ORDER_STATUSES)
    fully_filled = terminal && filled >= (decimal(size) - lot) && (remaining.nil? || remaining.abs <= lot)
    return :filled if fully_filled
    return :partial if filled.positive?

    :unknown
  end

  def order_status_digest(order)
    return nil unless order.is_a?(Hash)

    order.slice(:status, :filled_eth, :remaining_eth, :reduce_only, :side, :market)
  end

  # Authoritative target-open / source-close fill confirmation metadata for the
  # migration executor. Present only when the fast order-fill path confirmed.
  # `confirmed_at` is the readback-confirmation time (when we authoritatively knew
  # the order filled).
  # Part B: when the leg confirmed via an authoritative FULL order-by-id fill, defer the
  # post-submit account diagnostics (GET /v1/subaccount... balance/leverage/open_orders,
  # ~3s) so the leg returns to the executor right at the fill — the executor then starts
  # the source close ~3s sooner. This defers only a RECEIPT DIAGNOSTIC; the leg's fill
  # confirmation already ran and the executor's final readback still runs and is recorded.
  # Fail-closed: without an authoritative full fill, the account diagnostics are read as
  # before.
  def read_only_account_diagnostics_for(execution:, current_position:)
    return { status: "deferred", reason: "deferred off double-exposure critical path after authoritative full fill" } if authoritative_full_fill_confirmed?(execution)

    @venue.read_only_account_diagnostics(current_position: current_position)
  end

  def authoritative_full_fill_confirmed?(execution)
    return false unless execution.is_a?(Hash)

    fill = execution[:open_fill_confirmation] || execution[:close_fill_confirmation]
    fill.is_a?(Hash) && fill[:confirmed] == true && fill[:source].to_s == "extended_order_by_id_fill"
  end

  def build_open_fill_confirmation(mode:, confirmation:, timing:, order_preview:)
    return nil if mode == "close_only"
    return nil unless confirmation[:confirmation_source] == "extended_order_by_id_fill"

    fill = confirmation[:fill] || {}
    {
      confirmed: true,
      source: "extended_order_by_id_fill",
      reduce_only: false,
      confirmed_at: timing[:readback_confirmed_at],
      open_size_eth: order_size(order_preview).to_s("F"),
      filled_eth: fill[:filled_eth],
      remaining_eth: fill[:remaining_eth],
      order_status: fill[:status]
    }
  end

  def build_close_fill_confirmation(mode:, confirmation:, timing:, order_preview:)
    return nil unless mode == "close_only"
    return nil unless confirmation[:confirmation_source] == "extended_order_by_id_fill"

    fill = confirmation[:fill] || {}
    {
      confirmed: true,
      source: "extended_order_by_id_fill",
      reduce_only: true,
      confirmed_at: timing[:readback_confirmed_at],
      close_size_eth: order_size(order_preview).to_s("F"),
      filled_eth: fill[:filled_eth],
      remaining_eth: fill[:remaining_eth],
      order_status: fill[:status]
    }
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_or_nil(value)
    return nil if value.nil? || value.to_s.strip.empty?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def mark_timing!(timing, key)
    timing[key] = @now.call.utc.iso8601(6)
  end

  def timing_payload(timing)
    finalized_timing(timing).slice(
      :build_started_at, :build_finished_at, :sign_started_at, :sign_finished_at,
      :submit_started_at, :submit_finished_at, :submit_latency_seconds,
      :exchange_accept_at, :readback_started_at, :readback_confirmed_at,
      :readback_latency_seconds, :total_action_latency_seconds, :poll_attempts,
      :poll_interval_seconds, :slow_step
    )
  end

  def finalized_timing(timing, readback_attempts: [], poll_interval_seconds: nil)
    payload = (timing || {}).dup
    payload[:submit_latency_seconds] ||= seconds_between(payload[:submit_started_at], payload[:submit_finished_at])
    readback_finish = payload[:readback_confirmed_at] || payload[:readback_finished_at]
    payload[:readback_latency_seconds] ||= seconds_between(payload[:readback_started_at], readback_finish)
    payload[:total_action_latency_seconds] ||= seconds_between(payload[:build_started_at] || payload[:sign_started_at] || payload[:submit_started_at], readback_finish || payload[:submit_finished_at] || payload[:sign_finished_at] || payload[:build_finished_at])
    payload[:poll_attempts] ||= Array(readback_attempts).size if readback_attempts
    payload[:poll_interval_seconds] ||= poll_interval_seconds&.to_s("F") || extended_readback_interval_seconds.to_s("F")
    payload[:slow_step] ||= slow_step(payload)
    payload.compact
  end

  def sequence_timing(timing, legs)
    first_leg_timing = legs.first&.fetch(:timing, nil) || {}
    last_leg_timing = legs.last&.fetch(:timing, nil) || {}
    finalized_timing(timing.merge(
      sign_started_at: first_leg_timing[:sign_started_at],
      sign_finished_at: last_leg_timing[:sign_finished_at],
      submit_started_at: first_leg_timing[:submit_started_at],
      submit_finished_at: last_leg_timing[:submit_finished_at],
      readback_started_at: first_leg_timing[:readback_started_at],
      readback_confirmed_at: last_leg_timing[:readback_confirmed_at],
      readback_finished_at: last_leg_timing[:readback_finished_at],
      poll_attempts: legs.sum { |leg| Array(leg[:readback_attempts]).size }
    ))
  end

  def slow_step(timing)
    durations = {
      build: seconds_between(timing[:build_started_at], timing[:build_finished_at]),
      sign: seconds_between(timing[:sign_started_at], timing[:sign_finished_at]),
      submit: timing[:submit_latency_seconds],
      readback: timing[:readback_latency_seconds]
    }.compact
    durations.max_by { |_step, seconds| BigDecimal(seconds.to_s) }&.first&.to_s || "unknown"
  rescue ArgumentError
    "unknown"
  end

  def seconds_between(start_at, finish_at)
    return nil if start_at.blank? || finish_at.blank?

    (Time.zone.parse(finish_at.to_s) - Time.zone.parse(start_at.to_s)).round(6)
  rescue ArgumentError, TypeError
    nil
  end

  def rebalance_increase?(order)
    payload = order&.fetch(:payload, {})
    payload[:action].to_s == "increase_short" || (payload[:extended_side].to_s == "SELL" && payload[:reduce_only] == false)
  end

  def exchange_order_id(submit_response, signer_response)
    data = submit_response.is_a?(Hash) ? submit_response.with_indifferent_access[:data] : nil
    return data[:id].to_s if data.is_a?(Hash) && data[:id].present?

    signer_response[:order_id].to_s
  end

  def expected_redacted_stark_public_key
    value = @env["EXTENDED_STARK_PUBLIC_KEY"].to_s
    return nil if value.blank?
    return value if value.length <= 18

    "#{value[0, 10]}...#{value[-8, 8]}"
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key, env: @env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(@env[key])
  end

  def signer_health_for_diagnostics
    return nil if @env["EXTENDED_SIGNER_URL"].blank?

    @signer_client.health.with_indifferent_access
  end

  def signer_health_ok?(health)
    ActiveModel::Type::Boolean.new.cast(health[:ok])
  end

  def signer_health_verified_algorithm?(health)
    ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
  end

  def signer_health_signing_enabled?(health)
    ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
  end

  def signer_health_supports_extended_order?(health)
    signer_health_ok?(health) &&
      Array.wrap(health[:supported_exchanges]).include?("Extended") &&
      Array.wrap(health[:supported_actions]).include?("sign_extended_order")
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
    key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature/i)
  end
end
