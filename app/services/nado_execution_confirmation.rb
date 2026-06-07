require "net/http"

class NadoExecutionConfirmation
  ETH_PERP_PRODUCT_ID = 4

  def self.confirm_digest(**kwargs)
    new(**kwargs).confirm_digest
  end

  def initialize(digest:, product_id: ETH_PERP_PRODUCT_ID, env: ENV, venue: nil, http_post: nil, now: -> { Time.current })
    @digest = digest.to_s
    @product_id = product_id
    @env = env
    @venue = venue || HedgeVenues::Nado.new(env: env)
    @http_post_proc = http_post || method(:http_post)
    @now = now
    @attempts = []
  end

  def confirm_digest
    gateway = gateway_order_lookup
    return confirmed("gateway_order", gateway) if execution_confirmed_row?(gateway)

    archive = archive_order_lookup
    return confirmed("archive_order", archive) if execution_confirmed_row?(archive)

    {
      status: "unconfirmed",
      confirmed: false,
      confirmed_at: nil,
      source: nil,
      digest: digest,
      gateway_order_request: gateway_order_request,
      archive_order_request: archive_order_request,
      attempts: attempts.compact,
      blockers: attempts.filter_map { |attempt| attempt[:blocker] }
    }
  end

  private

  attr_reader :digest, :product_id, :env, :venue, :http_post_proc, :now, :attempts

  def gateway_order_lookup
    return record_attempt(source: "gateway_order", status: "skipped", blocker: "Nado gateway query is unavailable") unless gateway_query_available?

    response = venue.query(type: "order", product_id: product_id, digest: digest)
    row = extract_order_row(response)
    record_attempt(
      source: "gateway_order",
      status: row ? "ok" : "not_found",
      row: row,
      request: gateway_order_request,
      response_summary: response_summary(response),
      response_keys: response_keys(response)
    )
    row
  rescue => e
    record_attempt(source: "gateway_order", status: "error", request: gateway_order_request, blocker: "Nado gateway order query failed: #{e.class}: #{e.message}")
    nil
  end

  def archive_order_lookup
    endpoint = archive_endpoint
    return record_attempt(source: "archive_order", status: "skipped", request: archive_order_request, blocker: "NADO_ARCHIVE_ENDPOINT is not configured") if endpoint.blank?

    response = http_post_proc.call(URI(endpoint), archive_order_payload)
    row = extract_order_row(response)
    record_attempt(
      source: "archive_order",
      status: row ? "ok" : "not_found",
      row: row,
      request: archive_order_request,
      response_summary: response_summary(response),
      response_keys: response_keys(response)
    )
    row
  rescue => e
    record_attempt(source: "archive_order", status: "error", request: archive_order_request, blocker: "Nado archive order query failed: #{e.class}: #{e.message}")
    nil
  end

  def confirmed(source, row)
    {
      status: "confirmed",
      confirmed: true,
      confirmed_at: now.call.utc.iso8601(6),
      source: source,
      digest: digest,
      gateway_order_request: gateway_order_request,
      archive_order_request: archive_order_request,
      order: compact_order_row(row),
      attempts: attempts.compact,
      blockers: []
    }
  end

  def execution_confirmed_row?(row)
    return false unless row.is_a?(Hash)
    return false unless row_digest(row).blank? || row_digest(row).casecmp?(digest)

    decimal_field(row, "base_filled", "baseFilled", "filled_amount", "filledAmount", "closed_amount", "closedAmount").abs.positive? ||
      decimal_field(row, "amount").abs.positive? && decimal_field(row, "unfilled_amount", "unfilledAmount").abs < decimal_field(row, "amount").abs
  end

  def extract_order_row(response)
    data = response.is_a?(Hash) ? response["data"] || response[:data] || response : response
    rows = if data.is_a?(Hash) && data["order"].is_a?(Hash)
      [ data["order"] ]
    elsif data.is_a?(Hash) && data[:order].is_a?(Hash)
      [ data[:order] ]
    elsif data.is_a?(Hash) && data["orders"].is_a?(Array)
      data["orders"]
    elsif data.is_a?(Hash) && data[:orders].is_a?(Array)
      data[:orders]
    elsif data.is_a?(Hash) && data.dig("orders", "items").is_a?(Array)
      data.dig("orders", "items")
    elsif data.is_a?(Hash) && data.dig(:orders, :items).is_a?(Array)
      data.dig(:orders, :items)
    elsif data.is_a?(Array)
      data
    else
      [ data ]
    end
    rows.find { |row| row.is_a?(Hash) && (row_digest(row).blank? || row_digest(row).casecmp?(digest)) }
  end

  def row_digest(row)
    return nil unless row

    (row["digest"] || row[:digest]).to_s
  end

  def decimal_field(row, *keys)
    raw = keys.lazy.map { |key| row[key] || row[key.to_sym] }.find(&:present?)
    return BigDecimal("0") if raw.blank?

    BigDecimal(raw.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def compact_order_row(row)
    row.slice("digest", :digest, "product_id", :product_id, "submission_idx", :submission_idx, "last_fill_submission_idx", :last_fill_submission_idx, "amount", :amount, "unfilled_amount", :unfilled_amount, "base_filled", :base_filled, "quote_filled", :quote_filled)
  end

  def record_attempt(source:, status:, row: nil, request: nil, response_summary: nil, response_keys: nil, blocker: nil)
    attempts << {
      source: source,
      status: status,
      timestamp: now.call.utc.iso8601(6),
      digest: digest,
      product_id: product_id.to_s,
      request: request,
      response_summary: response_summary,
      response_keys: response_keys,
      order_digest: row_digest(row),
      base_filled: row && decimal_field(row, "base_filled", "baseFilled", "filled_amount", "filledAmount").to_s("F"),
      amount: row && decimal_field(row, "amount").to_s("F"),
      unfilled_amount: row && decimal_field(row, "unfilled_amount", "unfilledAmount").to_s("F"),
      blocker: blocker
    }.compact
    row
  end

  def response_keys(response)
    response.is_a?(Hash) ? response.keys.map(&:to_s).sort : []
  end

  def gateway_query_available?
    venue.respond_to?(:query) && (!venue.respond_to?(:query_available?) || venue.query_available?)
  end

  def archive_endpoint
    env["NADO_ARCHIVE_ENDPOINT"].presence || env["NADO_ARCHIVE_BASE_URL"].presence
  end

  def gateway_order_request
    base = env["NADO_GATEWAY_QUERY_BASE_URL"].presence || env["NADO_API_BASE_URL"].presence
    query = { type: "order", product_id: product_id, digest: digest }
    {
      method: "GET",
      url: base.present? ? gateway_query_url(base, query) : nil,
      params: query
    }
  end

  def archive_order_request
    {
      method: "POST",
      url: archive_endpoint,
      payload: archive_order_payload
    }
  end

  def archive_order_payload
    { orders: { digests: [ digest ], limit: 1 } }
  end

  def gateway_query_url(base, query)
    uri = URI.join(base.end_with?("/") ? base : "#{base}/", "query")
    uri.query = URI.encode_www_form(query)
    uri.to_s
  end

  def response_summary(response)
    data = response.is_a?(Hash) ? response["data"] || response[:data] || response : response
    row = extract_order_row(response)
    {
      top_level_keys: response_keys(response),
      data_class: data.class.name,
      data_keys: response_keys(data),
      row_present: row.is_a?(Hash),
      row_keys: response_keys(row),
      order_digest: row_digest(row),
      amount: row && decimal_field(row, "amount").to_s("F"),
      unfilled_amount: row && decimal_field(row, "unfilled_amount", "unfilledAmount").to_s("F"),
      base_filled: row && decimal_field(row, "base_filled", "baseFilled", "filled_amount", "filledAmount").to_s("F"),
      closed_amount: row && decimal_field(row, "closed_amount", "closedAmount").to_s("F")
    }.compact
  end

  def http_post(uri, payload)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 2, read_timeout: 2) { |http| http.request(request) }
    raise "POST #{uri.path} failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end
end
