class ExtendedMainnetLifecycleCheck
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS".freeze
  MODES = %w[open_only rebalance_delta close_only delta_round_trip close_reopen].freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @venue = venue
    @signer_client = signer_client
    @now = now
    @sleeper = sleeper
  end

  def run(position:, mode:, size_eth:, confirmation:, dry_run: true, max_slippage: "0.01", delta_eth: nil)
    mode = mode.to_s
    requested_size = mode == "rebalance_delta" && delta_eth.present? ? BigDecimal(delta_eth.to_s).abs : BigDecimal(size_eth.to_s)
    size = capped_size(requested_size)
    current_position = @venue.read_position(symbol: "ETH")
    orders = build_orders(position: position, mode: mode, size_eth: size, current_position: current_position, max_slippage: max_slippage, delta_eth: delta_eth)
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
        signer_health: dry_run_signer_health
      )
    end

    blockers.concat(live_blockers(mode: mode, confirmation: confirmation, orders: orders, current_position: current_position))
    if blockers.any?
      return result(
        status: "blocked_before_submit",
        blockers: blockers.uniq,
        position: position,
        mode: mode,
        dry_run: false,
        current_position: current_position,
        orders: orders
      )
    end

    signer_health = @signer_client.health
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
        signer_health: signer_health
      )
    end

    signed_result = mode == "delta_round_trip" ? sign_and_submit_sequence(orders: orders) : sign_and_submit(order_preview: orders.first, mode: mode)
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
      execution: signed_result
    )
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
    blockers << "#{mode} live probe requires open_orders_count=0" unless @venue.account_state[:open_orders_count].to_i.zero?
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

  def sign_and_submit_sequence(orders:)
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
      leg_result = sign_and_submit(order_preview: order_preview, mode: leg_mode).merge(leg: order_preview[:probe_leg])
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
      blockers: legs.flat_map { |leg| Array(leg[:blockers]) }.uniq
    }
  end

  def sign_and_submit(order_preview:, mode:)
    unsigned_order = @venue.extended_live_order(preview: order_preview, now: @now.call)
    signer_response = @signer_client.sign_order(unsigned_order)
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
        submitted: false
      }
    end

    submit_payload = signed_submit_payload(unsigned_order, signer_response)
    expected_short = expected_short_after(order_preview: order_preview, current_position: @venue.read_position(symbol: "ETH"))
    submit_response = @venue.submit_order(submit_payload)
    readback_attempts = mode == "close_only" ? poll_flat_readback : poll_short_readback(expected_size: expected_short)
    confirmed = readback_attempts.any? { |attempt| attempt[:confirmed] }
    {
      final_status: confirmed ? "success" : "submitted_but_readback_pending",
      unsigned_order: unsigned_order,
      signer_response: sanitize_signer_response(signer_response),
      submit_payload: sanitize_submit_payload(submit_payload),
      submit_response: sanitize_submit_response(submit_response),
      exchange_order_id: exchange_order_id(submit_response, signer_response),
      readback_attempts: readback_attempts,
      orders_placed: 1,
      signatures_created: 1,
      submitted: true
    }
  end

  def result(status:, blockers:, position:, mode:, dry_run:, current_position:, orders:, signer_health: nil, execution: nil)
    receipt = {
      venue: "extended",
      action: "mainnet_lifecycle_check",
      mode: mode,
      dry_run: dry_run,
      position_id: position.id,
      timestamp: @now.call.utc.iso8601,
      current_position: current_position,
      read_only_account_diagnostics: @venue.read_only_account_diagnostics(current_position: current_position),
      market_metadata: @venue.market_metadata_diagnostics,
      order_payload_summaries: orders.map { |order| order[:payload] },
      signer_health: sanitize_signer_health(signer_health),
      signer_request: execution ? sanitize_submit_payload(execution[:unsigned_order]) : orders.first&.dig(:payload, :signer_request),
      signer_response: execution && execution[:signer_response],
      submit_payload: execution && execution[:submit_payload],
      submit_response: execution && execution[:submit_response],
      exchange_order_id: execution && execution[:exchange_order_id],
      leg_summaries: execution && execution[:legs]&.map { |leg| leg_summary(leg) },
      readback_attempts: execution ? execution[:readback_attempts] : [],
      orders_placed: execution ? execution[:orders_placed] : 0,
      signatures_created: execution ? execution[:signatures_created] : 0,
      submitted: execution ? execution[:submitted] : false,
      final_status: status,
      blockers: (blockers + Array(execution && execution[:blockers])).uniq,
      warnings: [ "Extended mainnet path is manual-only and controlled by explicit live gates." ]
    }
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
      readback_attempts: leg[:readback_attempts],
      blockers: leg[:blockers]
    }.compact
  end

  def capped_size(size_eth)
    requested = BigDecimal(size_eth.to_s)
    cap = BigDecimal((@env["EXTENDED_PROBE_MAX_SIZE_ETH"].presence || default_probe_max_size).to_s)
    [ requested, cap ].min
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
    3.times.map do |index|
      @sleeper.call(1) if index.positive?
      position = @venue.read_position(symbol: "ETH")
      size = BigDecimal(position&.fetch(:short_size, 0).to_s)
      {
        attempt: index + 1,
        short_size: size.to_s("F"),
        side: position&.fetch(:side, nil),
        confirmed: position&.fetch(:side, nil) == "short" && (size - expected_size).abs <= BigDecimal("0.001")
      }
    rescue ArgumentError
      { attempt: index + 1, confirmed: false }
    end
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

  def rebalance_increase?(order)
    payload = order&.fetch(:payload, {})
    payload[:action].to_s == "increase_short" || (payload[:extended_side].to_s == "SELL" && payload[:reduce_only] == false)
  end

  def poll_flat_readback
    3.times.map do |index|
      @sleeper.call(1) if index.positive?
      position = @venue.read_position(symbol: "ETH")
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
