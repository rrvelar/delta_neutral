require "net/http"

class ExtendedApiClient
  def initialize(env: ENV, http_get: nil, http_post: nil, http_patch: nil)
    @env = env
    @http_get = http_get || method(:http_get)
    @http_post = http_post || method(:http_post)
    @http_patch = http_patch || method(:http_patch)
  end

  def configured?
    config_blockers.empty?
  end

  def config_blockers
    HedgeVenues::Extended::REQUIRED_CONFIG.filter_map do |key, message|
      message if @env[key].blank?
    end
  end

  def account_info
    get("/user/account/info")
  end

  def balance
    get("/user/balance")
  end

  def positions(market:)
    get("/user/positions", market: market)
  end

  def open_orders(market:)
    get("/user/orders", market: market)
  end

  def leverage(market:)
    get("/user/leverage", market: market)
  end

  def update_leverage(market:, leverage:)
    patch("/user/leverage", { market: market, leverage: leverage.to_s })
  end

  def fees(market:)
    get("/user/fees", "market[]" => market)
  end

  def market(market:)
    get("/info/markets", market: market)
  end

  def market_stats(market:)
    get("/info/markets/#{URI.encode_www_form_component(market)}/stats")
  end

  def submit_order(payload)
    response = post("/user/order", payload)
    record_submit_health(response)
    response
  rescue StandardError => e
    ExtendedSubmitHealth.record_failure!(error: "#{e.class}: #{e.message}")
    raise
  end

  # Read-only order/fill lookups (GET, API-key auth, no writes). Used for
  # authoritative fast fill confirmation. `order_by_id` returns a completed order
  # (validated: filled orders are retrievable by id, unlike the open-orders-only
  # /user/orders). history/trades are corroborating fallbacks.
  def order_by_id(order_id)
    get("/user/orders/#{URI.encode_www_form_component(order_id.to_s)}")
  end

  def order_history(market:)
    get("/user/orders/history", market: market)
  end

  def trades(market:)
    get("/user/trades", market: market)
  end

  private

  def get(path, params = {})
    raise ArgumentError, config_blockers.join(", ") unless configured?

    uri = URI.join(api_base_url, path.delete_prefix("/"))
    uri.query = URI.encode_www_form(params) if params.present?
    response = @http_get.call(uri, headers)
    payload = parse_body(response.body)
    return payload unless response.respond_to?(:code) && !response.is_a?(Net::HTTPSuccess)

    http_status = response.code.to_i
    {
      "error" => "HTTP #{http_status}",
      "http_status" => http_status,
      "body_status" => payload.is_a?(Hash) ? payload["status"] : nil,
      "message" => payload.is_a?(Hash) ? payload["message"] || payload["error"] : nil,
      "response_keys" => safe_keys(payload)
    }.compact
  end

  def parse_body(body)
    JSON.parse(body)
  rescue JSON::ParserError => e
    { "error" => "#{e.class}: #{e.message}" }
  end

  # Order submits are the only writes; record their health so status/dashboard
  # warnings can distinguish "reads work" from "submits work" (2026-07-17: 503s
  # on submit while reads stayed healthy).
  def record_submit_health(response)
    if response.is_a?(Hash) && response["http_status"].to_i >= 400
      ExtendedSubmitHealth.record_failure!(error: response["error"], http_status: response["http_status"])
    else
      ExtendedSubmitHealth.record_success!
    end
  end

  def http_get(uri, headers)
    request = Net::HTTP::Get.new(uri)
    headers.each { |key, value| request[key] = value }
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: http_timeout_seconds, read_timeout: http_timeout_seconds) do |http|
      http.request(request)
    end
  end

  def post(path, payload)
    raise ArgumentError, config_blockers.join(", ") unless configured?

    uri = URI.join(api_base_url, path.delete_prefix("/"))
    response = @http_post.call(uri, headers, payload)
    parsed = parse_body(response.body)
    return parsed unless response.respond_to?(:code) && !response.is_a?(Net::HTTPSuccess)

    http_status = response.code.to_i
    {
      "error" => "HTTP #{http_status}",
      "http_status" => http_status,
      "body_status" => parsed.is_a?(Hash) ? parsed["status"] : nil,
      "message" => parsed.is_a?(Hash) ? parsed["message"] || parsed["error"] : nil,
      "response_keys" => safe_keys(parsed)
    }.compact
  end

  def patch(path, payload)
    raise ArgumentError, config_blockers.join(", ") unless configured?

    uri = URI.join(api_base_url, path.delete_prefix("/"))
    response = @http_patch.call(uri, headers, payload)
    parsed = parse_body(response.body)
    return parsed unless response.respond_to?(:code) && !response.is_a?(Net::HTTPSuccess)

    http_status = response.code.to_i
    {
      "error" => "HTTP #{http_status}",
      "http_status" => http_status,
      "body_status" => parsed.is_a?(Hash) ? parsed["status"] : nil,
      "message" => parsed.is_a?(Hash) ? parsed["message"] || parsed["error"] : nil,
      "response_keys" => safe_keys(parsed)
    }.compact
  end

  def http_post(uri, headers, payload)
    request = Net::HTTP::Post.new(uri)
    headers.each { |key, value| request[key] = value }
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: http_timeout_seconds, read_timeout: http_timeout_seconds) do |http|
      http.request(request)
    end
  end

  def http_patch(uri, headers, payload)
    request = Net::HTTP::Patch.new(uri)
    headers.each { |key, value| request[key] = value }
    request.body = JSON.generate(payload)
    Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: http_timeout_seconds, read_timeout: http_timeout_seconds) do |http|
      http.request(request)
    end
  end

  def headers
    {
      "Accept" => "application/json",
      "Content-Type" => "application/json",
      "X-Api-Key" => @env.fetch("EXTENDED_API_KEY", "")
    }
  end

  def http_timeout_seconds
    Float(@env.fetch("EXTENDED_API_TIMEOUT_SECONDS", "2"))
  rescue ArgumentError
    2.0
  end

  def api_base_url
    @env.fetch("EXTENDED_API_BASE_URL").end_with?("/") ? @env.fetch("EXTENDED_API_BASE_URL") : "#{@env.fetch('EXTENDED_API_BASE_URL')}/"
  end

  def safe_keys(value)
    return [] unless value.respond_to?(:keys)

    value.keys.map(&:to_s).reject { |key| key.match?(/api|key|secret|signature|private|authorization|cookie/i) }.sort
  end
end
