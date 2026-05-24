require "net/http"
require_relative "errors"
require_relative "account_health"
require_relative "market_metadata"
require_relative "position_snapshot"
require_relative "probe_result"

module HedgeBackends
  class EtherealReadOnlyProbe
    BACKEND = "ethereal".freeze
    DEFAULT_MARKET = "ETH-USD".freeze
    DEFAULT_ASSET = "ETH".freeze
    HTTP_TIMEOUT_SECONDS = 10
    SOURCES_CHECKED = [
      "https://docs.ethereal.trade/",
      "https://docs.ethereal.trade/protocol-reference/api-hosts",
      "https://docs.ethereal.trade/developer-guides/trading-api/quick-start",
      "https://docs.ethereal.trade/developer-guides/trading-api/products",
      "https://docs.ethereal.trade/developer-guides/trading-api/order-placement",
      "https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers",
      "https://docs.ethereal.trade/developer-guides/trading-api/message-signing",
      "https://docs.ethereal.trade/developer-guides/trading-api/system-limits",
      "https://docs.ethereal.trade/developer-guides/trading-api/websockets",
      "https://docs.ethereal.trade/developer-guides/trading-api/tradingview-api",
      "https://docs.ethereal.trade/developer-guides/sdk/python-sdk",
      "https://api.ethereal.trade/openapi.json",
      "https://api.ethereal.trade/docs",
      "https://api.etherealtest.net/openapi.json",
      "https://api.etherealtest.net/docs",
      "https://meridianxyz.github.io"
    ].freeze

    def initialize(env: ENV, http_get: nil)
      @env = env
      @http_get = http_get || method(:http_get)
      @endpoint_results = []
    end

    def backend_name
      BACKEND
    end

    def market_symbol
      @env.fetch("ETHEREAL_MARKET_SYMBOL", DEFAULT_MARKET).presence || DEFAULT_MARKET
    end

    def market_metadata(asset = DEFAULT_ASSET)
      product = product_for(asset)
      return unsupported_metadata(asset, "Ethereal product not found for #{market_symbol}") unless product

      MarketMetadata.new(
        backend: BACKEND,
        asset: asset,
        market: product["displayTicker"] || market_symbol,
        status: product["status"],
        lot_size: product["lotSize"],
        tick_size: product["tickSize"],
        min_order_size: product["minQuantity"],
        min_notional_usd: nil,
        max_leverage: product["maxLeverage"],
        collateral: product["quoteTokenName"],
        raw: product,
        result_status: "ok"
      )
    end

    def get_mark_price(asset = DEFAULT_ASSET)
      product = product_for(asset)
      return unsupported_result("mark_price", "Ethereal product not found for #{market_symbol}") unless product

      response = get_json("/v1/product/market-price", productIds: product.fetch("id"))
      price = Array(response["data"]).find { |item| item["productId"] == product.fetch("id") }
      raise ParseError, "Ethereal market price response did not include product #{product.fetch('id')}" unless price

      {
        backend: BACKEND,
        asset: asset,
        market: product["displayTicker"] || market_symbol,
        mark_price: decimal_string(price["oraclePrice"]),
        best_bid_price: decimal_string(price["bestBidPrice"]),
        best_ask_price: decimal_string(price["bestAskPrice"]),
        raw: price,
        status: "ok"
      }
    end

    def get_position(asset = DEFAULT_ASSET, account: nil)
      subaccount_id = account.presence || @env["ETHEREAL_SUBACCOUNT_ID"].presence
      return unsupported_position(asset, "ETHEREAL_SUBACCOUNT_ID is required for Ethereal position readback") unless subaccount_id

      product = product_for(asset)
      return unsupported_position(asset, "Ethereal product not found for #{market_symbol}") unless product

      response = get_json("/v1/position/active", subaccountId: subaccount_id, productId: product.fetch("id"))
      position = response["data"].is_a?(Hash) ? response["data"] : response
      return zero_position(asset, product, subaccount_id, response) if position.blank? || position["id"].blank?

      signed_size = signed_position_size(position)
      short_size = signed_size&.negative? ? signed_size.abs : BigDecimal("0")
      mark_price = decimal_or_nil(get_mark_price(asset)[:mark_price])

      PositionSnapshot.new(
        backend: BACKEND,
        asset: asset,
        market: product["displayTicker"] || market_symbol,
        signed_size: signed_size,
        short_size: short_size,
        mark_price: mark_price,
        position_value: decimal_or_nil(position["cost"])&.abs,
        margin_used: nil,
        unrealized_pnl: position["unrealizedPnl"],
        liquidation_price: position["liquidationPrice"],
        account: subaccount_id,
        raw: position,
        status: "ok"
      )
    rescue NetworkError, RateLimitError, ParseError
      raise
    rescue => e
      raise ParseError, "Ethereal position response could not be normalized: #{e.message}"
    end

    def account_health(account: nil)
      subaccount_id = account.presence || @env["ETHEREAL_SUBACCOUNT_ID"].presence
      return unsupported_account_health("ETHEREAL_SUBACCOUNT_ID is required for Ethereal account health readback") unless subaccount_id

      response = get_json("/v1/subaccount/balance", subaccountId: subaccount_id)
      balances = Array(response["data"])
      collateral = balances.find { |balance| collateral_token?(balance["tokenName"]) } || balances.first
      return unsupported_account_health("Ethereal balance response had no balances") unless collateral

      AccountHealth.new(
        backend: BACKEND,
        account: @env["ETHEREAL_ACCOUNT_ID"].presence,
        subaccount: subaccount_id,
        collateral: collateral["tokenName"],
        account_value_usd: collateral["amount"],
        withdrawable_usd: collateral["available"],
        margin_used_usd: collateral["totalUsed"],
        raw: response,
        status: "ok"
      )
    end

    def run_probe
      warnings = []
      errors = []
      unsupported = []
      unknown = [ "Ethereal min_notional_usd is not exposed in checked product docs/API schema" ]

      unless enabled?
        return ProbeResult.new(
          backend: BACKEND,
          config: config_summary,
          warnings: [ "ETHEREAL_READ_ONLY_ENABLED is not true; no network calls made" ],
          endpoint_results: [
            endpoint_result(endpoint: "GET /v1/product", status: "skipped", message: "probe disabled"),
            endpoint_result(endpoint: "GET /v1/product/market-price", status: "skipped", message: "probe disabled"),
            endpoint_result(endpoint: "GET /v1/position/active", status: "skipped", message: "probe disabled"),
            endpoint_result(endpoint: "GET /v1/subaccount/balance", status: "skipped", message: "probe disabled")
          ],
          unsupported: [ "probe disabled by configuration" ],
          unknown: unknown,
          sources_checked: SOURCES_CHECKED,
          status: "BLOCKED"
        )
      end

      if api_base_url.blank?
        return ProbeResult.new(
          backend: BACKEND,
          config: config_summary,
          errors: [ error_hash(ConfigurationError.new("ETHEREAL_API_BASE_URL is required when ETHEREAL_READ_ONLY_ENABLED=true")) ],
          endpoint_results: [
            endpoint_result(endpoint: "GET /v1/product", status: "skipped", message: "missing ETHEREAL_API_BASE_URL"),
            endpoint_result(endpoint: "GET /v1/product/market-price", status: "skipped", message: "missing ETHEREAL_API_BASE_URL"),
            endpoint_result(endpoint: "GET /v1/position/active", status: "skipped", message: "missing ETHEREAL_API_BASE_URL"),
            endpoint_result(endpoint: "GET /v1/subaccount/balance", status: "skipped", message: "missing ETHEREAL_API_BASE_URL")
          ],
          unsupported: unsupported,
          unknown: unknown,
          sources_checked: SOURCES_CHECKED,
          status: "BLOCKED"
        )
      end

      market = capture_result(:market_metadata, errors) { market_metadata(DEFAULT_ASSET) }
      mark = capture_result(:mark_price, errors) { get_mark_price(DEFAULT_ASSET) }
      position = capture_result(:position, errors) { get_position(DEFAULT_ASSET) }
      health = capture_result(:account_health, errors) { account_health }

      unsupported.concat([ position, health ].filter_map { |result| result[:message] if result.is_a?(Hash) && result[:status] == "unsupported" })

      ProbeResult.new(
        backend: BACKEND,
        config: config_summary,
        market_metadata: market,
        mark_price: mark,
        position: position,
        account_health: health,
        endpoint_results: @endpoint_results,
        unsupported: unsupported,
        unknown: unknown,
        errors: errors,
        warnings: warnings,
        sources_checked: SOURCES_CHECKED
      )
    end

    private

    def enabled?
      ActiveModel::Type::Boolean.new.cast(@env["ETHEREAL_READ_ONLY_ENABLED"]) == true
    end

    def api_base_url
      @env["ETHEREAL_API_BASE_URL"].to_s.delete_suffix("/")
    end

    def config_summary
      {
        enabled: enabled?,
        api_base_url: api_base_url.presence,
        ws_url_configured: @env["ETHEREAL_WS_URL"].present?,
        account_id_configured: @env["ETHEREAL_ACCOUNT_ID"].present?,
        subaccount_id_configured: @env["ETHEREAL_SUBACCOUNT_ID"].present?,
        market_symbol: market_symbol,
        private_key_configured: false,
        signing_configured: false
      }
    end

    def product_for(asset)
      @product_for ||= {}
      @product_for[asset] ||= begin
        response = get_json("/v1/product", ticker: market_symbol.delete("-"), limit: 100)
        products = Array(response["data"])
        products.find { |product| product["displayTicker"] == market_symbol } ||
          products.find { |product| product["ticker"] == market_symbol.delete("-") || product["baseTokenName"] == asset }
      end
    end

    def get_json(path, params = {})
      uri = URI.join("#{api_base_url}/", path.delete_prefix("/"))
      uri.query = URI.encode_www_form(params) if params.any?
      response = @http_get.call(uri)
      if response.code.to_i == 429
        record_endpoint(path, "error", http_status: response.code.to_i, error_class: RateLimitError.name, message: "rate limited")
        raise RateLimitError, "Ethereal API rate limited: HTTP 429"
      end
      unless response.is_a?(Net::HTTPSuccess)
        record_endpoint(path, "error", http_status: response.code.to_i, error_class: NetworkError.name, message: "non-2xx response")
        raise NetworkError, "Ethereal API request failed: HTTP #{response.code}"
      end

      parsed = JSON.parse(response.body)
      record_endpoint(path, "ok", http_status: response.code.to_i)
      parsed
    rescue JSON::ParserError => e
      record_endpoint(path, "error", error_class: ParseError.name, message: "invalid JSON")
      raise ParseError, "Ethereal API returned invalid JSON: #{e.message}"
    end

    def http_get(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: HTTP_TIMEOUT_SECONDS, read_timeout: HTTP_TIMEOUT_SECONDS) do |http|
        http.get(uri.request_uri, "Accept" => "application/json")
      end
    rescue => e
      raise NetworkError, "Ethereal API network error: #{e.class}: #{e.message}"
    end

    def capture_result(section, errors)
      yield
    rescue Error => e
      errors << error_hash(e, section: section)
      { backend: BACKEND, status: "error", section: section, error_class: e.class.name, message: e.message }
    end

    def unsupported_metadata(asset, message)
      record_endpoint("/v1/product", "unsupported", message: message)
      MarketMetadata.new(backend: BACKEND, asset: asset, market: market_symbol, raw: { message: message }, result_status: "unsupported")
    end

    def unsupported_position(asset, message)
      record_endpoint("/v1/position/active", "unsupported", message: message)
      PositionSnapshot.new(backend: BACKEND, asset: asset, market: market_symbol, raw: { message: message }, status: "unsupported")
    end

    def unsupported_account_health(message)
      record_endpoint("/v1/subaccount/balance", "unsupported", message: message)
      AccountHealth.new(backend: BACKEND, raw: { message: message }, status: "unsupported")
    end

    def unsupported_result(section, message)
      record_endpoint(endpoint_path_for_section(section), "unsupported", message: message)
      { backend: BACKEND, section: section, status: "unsupported", message: message }
    end

    def zero_position(asset, product, subaccount_id, raw)
      PositionSnapshot.new(
        backend: BACKEND,
        asset: asset,
        market: product["displayTicker"] || market_symbol,
        signed_size: BigDecimal("0"),
        short_size: BigDecimal("0"),
        account: subaccount_id,
        raw: raw,
        status: "ok"
      )
    end

    def collateral_token?(token_name)
      %w[USD USDE USDe].include?(token_name.to_s)
    end

    def signed_position_size(position)
      size = decimal_or_nil(position["size"])
      return size if size&.nonzero?

      position["side"].to_i == 1 && size ? -size : size
    end

    def decimal_or_nil(value)
      return nil if value.nil?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def decimal_string(value)
      decimal_or_nil(value)&.to_s("F")
    end

    def error_hash(error, section: nil)
      { section: section, class: error.class.name, message: error.message }.compact
    end

    def record_endpoint(path, status, http_status: nil, error_class: nil, message: nil)
      endpoint = path.start_with?("GET ") ? path : "GET #{path}"
      @endpoint_results << endpoint_result(
        endpoint: endpoint,
        status: status,
        http_status: http_status,
        error_class: error_class,
        message: message
      )
    end

    def endpoint_result(endpoint:, status:, http_status: nil, error_class: nil, message: nil)
      {
        endpoint: endpoint,
        status: status,
        http_status: http_status,
        error_class: error_class,
        message: message
      }.compact
    end

    def endpoint_path_for_section(section)
      case section.to_s
      when "mark_price"
        "/v1/product/market-price"
      when "position"
        "/v1/position/active"
      when "account_health"
        "/v1/subaccount/balance"
      else
        "/v1/product"
      end
    end
  end
end
