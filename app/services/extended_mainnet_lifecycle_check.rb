class ExtendedMainnetLifecycleCheck
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS".freeze
  MODES = %w[open_only delta_round_trip close_reopen].freeze

  def initialize(env: ENV, venue: HedgeVenues::Extended.new(env: env), signer_client: ExtendedStarkSignerClient.new(env: env), now: -> { Time.current }, sleeper: ->(seconds) { sleep(seconds) })
    @env = env
    @venue = venue
    @signer_client = signer_client
    @now = now
    @sleeper = sleeper
  end

  def run(position:, mode:, size_eth:, confirmation:, dry_run: true, max_slippage: "0.01")
    mode = mode.to_s
    size = capped_size(size_eth)
    current_position = @venue.read_position(symbol: "ETH")
    orders = build_orders(position: position, mode: mode, size_eth: size, current_position: current_position, max_slippage: max_slippage)
    blockers = structural_blockers(mode: mode, orders: orders, dry_run: dry_run)

    if dry_run
      return result(
        status: "dry_run",
        blockers: blockers,
        position: position,
        mode: mode,
        dry_run: true,
        current_position: current_position,
        orders: orders
      )
    end

    blockers.concat(live_blockers(confirmation: confirmation, orders: orders))
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

    signed_result = sign_and_submit_open_only(orders.first, current_position: current_position)
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

  def build_orders(position:, mode:, size_eth:, current_position:, max_slippage:)
    case mode
    when "open_only"
      [ @venue.open_short_preview(symbol: "ETH", size_eth: size_eth, max_slippage: max_slippage) ]
    when "delta_round_trip"
      [
        @venue.rebalance_preview(symbol: "ETH", delta_eth: -size_eth, max_slippage: max_slippage),
        @venue.rebalance_preview(symbol: "ETH", delta_eth: size_eth, max_slippage: max_slippage)
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

  def structural_blockers(mode:, orders:, dry_run:)
    blockers = []
    blockers << "mode must be one of #{MODES.join(', ')}" unless mode.in?(MODES)
    blockers << "Extended live submit currently supports open_only probe only" if !dry_run && mode != "open_only"
    blockers.concat(dry_run ? @venue.blockers : @venue.live_readiness_blockers)
    blockers.concat(orders.flat_map { |order| order.fetch(:blockers, []) }) if dry_run
    blockers.concat(orders.flat_map { |order| @venue.live_order_blockers(preview: order) }) unless dry_run
    blockers << "Extended Stark signer verified_algorithm=false" if dry_run && !signer_verified_algorithm?
    blockers.uniq
  end

  def live_blockers(confirmation:, orders:)
    blockers = []
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" unless bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless bool_env("EXTENDED_LIVE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false for manual Extended mainnet probe" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "EXTENDED_SIGNER_URL is required" if @env["EXTENDED_SIGNER_URL"].blank?
    blockers << "open_only live probe requires no current Extended position" if @venue.read_position(symbol: "ETH")
    blockers << "open_only live probe requires open_orders_count=0" unless @venue.account_state[:open_orders_count].to_i.zero?
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
    blockers << "Extended signer health must advertise Extended/sign_extended_order support" unless @signer_client.supports_extended_order_signing?
    blockers << "Extended Stark signer verified_algorithm=false" unless ActiveModel::Type::Boolean.new.cast(health[:verified_algorithm] || health[:signing_algorithm_verified])
    blockers << "Extended Stark signer signing_enabled=false" unless ActiveModel::Type::Boolean.new.cast(health[:signing_enabled])
    if health[:stark_public_key].present? && expected_redacted_stark_public_key.present? && health[:stark_public_key] != expected_redacted_stark_public_key
      blockers << "Extended signer Stark public key does not match EXTENDED_STARK_PUBLIC_KEY"
    end
    blockers
  end

  def sign_and_submit_open_only(order_preview, current_position:)
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
    submit_response = @venue.submit_order(submit_payload)
    readback_attempts = poll_open_readback(expected_size: BigDecimal(unsigned_order.fetch("qty").to_s))
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
      signer_request: execution && sanitize_submit_payload(execution[:unsigned_order]),
      signer_response: execution && execution[:signer_response],
      submit_payload: execution && execution[:submit_payload],
      submit_response: execution && execution[:submit_response],
      exchange_order_id: execution && execution[:exchange_order_id],
      readback_attempts: execution ? execution[:readback_attempts] : [],
      orders_placed: execution ? execution[:orders_placed] : 0,
      signatures_created: execution ? execution[:signatures_created] : 0,
      submitted: execution ? execution[:submitted] : false,
      final_status: status,
      blockers: blockers.uniq,
      warnings: [ "Extended mainnet path is manual-only and fail-closed until Stark signing is verified." ]
    }
    Result.new(status, blockers.uniq, receipt[:warnings], receipt)
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

    payload.to_h.except(:api_key, :private_key, :signature, "api_key", "private_key", "signature")
  end

  def sanitize_signer_response(payload)
    return nil unless payload

    sanitized = payload.to_h.deep_dup
    if sanitized.dig(:settlement, :signature)
      sanitized[:settlement][:signature] = "<redacted>"
    elsif sanitized.dig("settlement", "signature")
      sanitized["settlement"]["signature"] = "<redacted>"
    end
    sanitized.except(:private_key, "private_key")
  end

  def sanitize_submit_payload(payload)
    return nil unless payload

    sanitized = payload.to_h.deep_dup
    if sanitized.dig("settlement", "signature")
      sanitized["settlement"]["signature"] = "<redacted>"
    elsif sanitized.dig(:settlement, :signature)
      sanitized[:settlement][:signature] = "<redacted>"
    end
    sanitized
  end

  def sanitize_submit_response(payload)
    payload
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

  def poll_open_readback(expected_size:)
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

  def signer_verified_algorithm?
    return @signer_client.verified_algorithm? if @signer_client.respond_to?(:verified_algorithm?)

    ActiveModel::Type::Boolean.new.cast(@signer_client.health[:verified_algorithm])
  rescue
    false
  end
end
