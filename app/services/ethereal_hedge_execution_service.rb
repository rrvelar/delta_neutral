require "digest"
require "net/http"
require "securerandom"

class EtherealHedgeExecutionService
  DEFAULT_SYMBOL = "ETH-PERP".freeze
  EXCHANGE_SYMBOL = "ETHUSD".freeze
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_ETHEREAL_ORDERS".freeze
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
    execute(position: position, action: "rebalance", size_eth: delta_eth, current_position: current_position, confirmation: confirmation, max_slippage: max_slippage)
  end

  def auto_rebalance_short(position:, delta_eth:, current_position:, max_slippage:)
    execute(position: position, action: "rebalance", size_eth: delta_eth, current_position: current_position, confirmation: nil, max_slippage: max_slippage, require_confirmation: false)
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

  def execute(position:, action:, size_eth:, current_position:, confirmation:, max_slippage:, require_confirmation: true)
    order = build_order_preview(position: position, action: action, size_eth: size_eth, current_position: current_position, max_slippage: max_slippage)
    blockers = live_blockers(position: position, action: action, size_eth: size_eth, current_position: current_position, confirmation: confirmation, order: order, require_confirmation: require_confirmation)
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

  def live_blockers(position:, action:, size_eth:, current_position:, confirmation:, order:, require_confirmation: true)
    blockers = order.fetch(:blockers).dup
    blockers << "selected hedge execution venue must be ethereal" unless position.hedge&.ethereal_execution?
    blockers << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true" unless @venue.live_enabled?
    blockers << "submitted confirmation must equal #{CONFIRMATION}" if require_confirmation && confirmation.to_s != CONFIRMATION
    blockers << "active hedge-ready Mellow position is required" unless position.active? && (!position.mellow_autopilot? || position.hedge_ready?)
    blockers << "ETHEREAL_LINKED_SIGNER_ADDRESS is required" if @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].blank?
    blockers << "ETHEREAL_SUBACCOUNT_ID is required" if @env["ETHEREAL_SUBACCOUNT_ID"].blank?
    blockers << "ETHEREAL_API_BASE_URL is required" if @env["ETHEREAL_API_BASE_URL"].blank?
    blockers << "Ethereal signer service URL is required" if signer_url.blank?
    blockers << "current Ethereal readback is unavailable" if current_position == :unavailable
    blockers << "current Ethereal position is long; manual action required" if position_size(current_position).positive?
    blockers << "target size is zero" if action.to_s == "open" && !BigDecimal(size_eth.to_s).positive?
    blockers.uniq
  end

  def result(status, blockers, order, position, action, pre_position, submit_response, post_position, readback_poll)
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
      expected_short_eth: decimal_string(expected_short_after(action: action, size_eth: order.dig(:summary, :rounded_size_eth) || 0, current_position: pre_position)),
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
      subaccount_id: @env["ETHEREAL_SUBACCOUNT_ID"],
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
    blockers << "ETHEREAL_SUBACCOUNT_ID is required for Ethereal order payloads" if @env["ETHEREAL_SUBACCOUNT_ID"].blank?
    blockers << "ETHEREAL_LINKED_SIGNER_ADDRESS is required for Ethereal order payloads" if @env["ETHEREAL_LINKED_SIGNER_ADDRESS"].blank?
    blockers << mapping_error if mapping_error.present?
    blockers
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
