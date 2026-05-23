require "digest"
require "net/http"

class NadoHedgeExecutionService
  DEFAULT_SYMBOL = "ETH-PERP".freeze
  DEFAULT_MAX_SLIPPAGE = BigDecimal("0.01")
  DEFAULT_ORDER_TTL_SECONDS = 3600
  RECEIVE_TIME_BUFFER_SECONDS = 5
  MAX_RECEIVE_TIME_FUTURE_SECONDS = 100
  POST_SUBMIT_READBACK_ATTEMPTS = 3
  POST_SUBMIT_READBACK_DELAY_SECONDS = 0.05
  EXECUTE_BODY_SHAPE = "execute_place_orders_batch".freeze
  DEFAULT_MARGIN_MODE = "isolated".freeze
  DEFAULT_REQUESTED_LEVERAGE = BigDecimal("1")

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

  def open_short(position:, size_eth:, current_position:, confirmation:, max_slippage:)
    execute(position: position, action: "open", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage)
  end

  def close_short(position:, size_eth:, current_position:, confirmation:, max_slippage:)
    execute(position: position, action: "close", size_eth: size_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage)
  end

  def rebalance_short(position:, delta_eth:, current_position:, confirmation:, max_slippage:)
    execute(
      position: position,
      action: "rebalance",
      size_eth: BigDecimal(delta_eth.to_s),
      current_position: current_position,
      confirmation: confirmation,
      max_slippage: max_slippage
    )
  end

  def auto_rebalance_short(position:, delta_eth:, current_position:, max_slippage:)
    execute(
      position: position,
      action: "rebalance",
      size_eth: BigDecimal(delta_eth.to_s),
      current_position: current_position,
      confirmation: nil,
      max_slippage: max_slippage,
      require_confirmation: false
    )
  end

  def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position: nil)
    side = order_side(action: action, size_eth: size_eth)
    reduce_only = reduce_only_order?(action: action, size_eth: size_eth)
    order_size = order_size(size_eth)
    product = product_metadata
    price = order_price(position: position, side: side, max_slippage: max_slippage, product: product)
    rounded_price = round_price(price, side: side, product: product)
    rounded_size = round_size(order_size, product: product)
    amount_x18 = decimal_to_x18(rounded_size)
    amount_x18 = -amount_x18 if side == "sell"
    now = @now.call
    margin = margin_plan(action: action, reduce_only: reduce_only, rounded_size: rounded_size, rounded_price: rounded_price, current_position: current_position)
    order_fields = nado_order_fields(
      side: side,
      reduce_only: reduce_only,
      price: rounded_price,
      amount_x18: amount_x18,
      product: product,
      now: now,
      isolated_margin_x6: margin[:isolated_margin_x6],
      sender: subaccount
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
        product_id: product[:product_id],
        rounded_size_eth: decimal_string(rounded_size),
        rounded_price: decimal_string(rounded_price),
        estimated_notional_usd: decimal_string(rounded_size * rounded_price),
        amount_x18: amount_x18.to_s,
        sender: order_fields[:sender],
        current_position_subaccount: isolated_position_subaccount(current_position),
        appendix: order_fields[:appendix],
        order_type: "ioc",
        isolated: appendix_isolated?(order_fields[:appendix].to_i),
        margin_mode: margin[:margin_mode],
        requested_leverage: margin[:requested_leverage]&.to_s("F"),
        isolated_margin_usd: margin[:isolated_margin_usd]&.to_s("F"),
        isolated_margin_x6: margin[:isolated_margin_x6],
        appendix_decoded: decode_appendix(order_fields[:appendix]),
        recv_time_ms: timing.dig(:diagnostics, :recv_time_ms),
        seconds_until_recv_time: timing.dig(:diagnostics, :seconds_until_recv_time),
        order_expiration: timing.dig(:diagnostics, :order_expiration)
      },
      timing: timing.fetch(:diagnostics),
      typed_data: typed_data,
      order_fields: order_fields,
      product: product,
      blockers: product.fetch(:blockers) + timing.fetch(:blockers) + margin.fetch(:blockers),
      warnings: product.fetch(:warnings)
    }
  end

  def read_position
    safe_read_position
  end

  private

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
    readback_poll = parsed[:status] == "submitted" ? poll_post_submit_readback(action: action) : { attempts: [], position: nil }
    post_position = readback_poll.fetch(:position)
    status = final_status(parsed, post_position: post_position, action: action)
    result(status, [], order, position, action, current_position, parsed, post_position, readback_poll)
  rescue => e
    result("failed_before_submit", [ "#{e.class}: #{e.message}" ], order || {}, position, action, current_position, nil, nil, nil)
  end

  def live_blockers(position:, action:, size_eth:, current_position:, confirmation:, order:, require_confirmation: true)
    order_size = order_size(size_eth)
    blockers = []
    blockers << "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true" unless @venue.live_flag_enabled?
    blockers << "submitted confirmation must equal #{@venue.live_confirmation_phrase}" if require_confirmation && !(confirmation.to_s == @venue.live_confirmation_phrase && @venue.live_confirmation_phrase.present?)
    blockers << "position must be active" unless position.active?
    blockers << "active hedge-ready Mellow Autopilot position is required" unless position.mellow_autopilot? && position.hedge_ready?
    blockers << "target hedge size must be positive" if action.to_s == "open" && !order_size.positive?
    blockers << "rebalance delta must be non-zero" if action.to_s == "rebalance" && order_size.zero?
    blockers << "close size must be positive" if action.to_s == "close" && !order_size.positive?
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

  def nado_order_fields(side:, reduce_only:, price:, amount_x18:, product:, now:, isolated_margin_x6:, sender:)
    {
      sender: sender,
      priceX18: decimal_to_x18(price).to_s,
      amount: amount_x18.to_s,
      expiration: (now.to_i + DEFAULT_ORDER_TTL_SECONDS).to_s,
      nonce: nado_receive_time_nonce(seed: "#{side}:#{amount_x18}:#{now.to_f}", now: now).to_s,
      appendix: build_appendix(reduce_only: reduce_only, isolated_margin_x6: isolated_margin_x6).to_s
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

  def final_status(parsed, post_position:, action:)
    return "failed_before_submit" unless parsed[:status] == "submitted"

    current_short = short_size(post_position)
    if action.to_s.in?(%w[open rebalance])
      current_short.positive? ? "submitted_and_confirmed" : "submitted_but_readback_pending"
    else
      current_short.zero? ? "submitted_and_confirmed" : "submitted_but_not_confirmed"
    end
  end

  def poll_post_submit_readback(action:)
    attempts = []
    POST_SUBMIT_READBACK_ATTEMPTS.times do |index|
      @sleeper.call(POST_SUBMIT_READBACK_DELAY_SECONDS) if index.positive?
      position = safe_read_position
      serialized = serialize_position(position)
      attempts << {
        attempt: index + 1,
        position_present: serialized.present?,
        confirmed: readback_confirms_action?(position, action),
        readback: serialized
      }
      return { attempts: attempts, position: position } if attempts.last.fetch(:confirmed)
    end
    { attempts: attempts, position: nil }
  end

  def readback_confirms_action?(position, action)
    return false if position == :unavailable

    current_short = short_size(position)
    action.to_s == "close" ? current_short.zero? : current_short.positive?
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

  def order_size(size_eth)
    BigDecimal(size_eth.to_s).abs
  end

  def appendix_isolated?(appendix)
    (appendix & (1 << 8)).positive?
  end

  def margin_plan(action:, reduce_only:, rounded_size:, rounded_price:, current_position:)
    if reduce_only
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

  def desired_margin_mode
    (@env["AERODROME_NADO_MARGIN_MODE"].presence || DEFAULT_MARGIN_MODE).to_s.downcase
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
    {
      recv_time_ms: recv_time_ms,
      recv_time: Time.at(recv_time_ms / 1000.0).utc.iso8601(3),
      local_submit_time_ms: local_submit_time_ms,
      local_submit_time: local_time.utc.iso8601(3),
      seconds_until_recv_time: ((recv_time_ms - local_submit_time_ms) / 1000.0).round(3),
      order_expiration: expiration,
      order_expiration_time: Time.at(expiration).utc.iso8601
    }
  rescue ArgumentError, TypeError
    {
      recv_time_ms: nil,
      recv_time: nil,
      local_submit_time_ms: local_time_ms(local_time),
      local_submit_time: local_time.utc.iso8601(3),
      seconds_until_recv_time: nil,
      order_expiration: order_fields[:expiration],
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

  def decimal_string(value)
    return nil unless value

    BigDecimal(value.to_s).to_s("F")
  end
end
