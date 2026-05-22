require "net/http"

module HedgeVenues
  class Nado < Base
    DEFAULT_SIZE_INCREMENT = BigDecimal("0.001")
    HTTP_TIMEOUT_SECONDS = 10

    def initialize(http_get: nil, **kwargs)
      super(**kwargs)
      @http_get = http_get || method(:http_get)
      @read_warnings = []
    end

    def venue_name
      "Nado"
    end

    def read_position(symbol:)
      return nil if config_blockers.any?

      positions.find { |position| position[:symbol] == normalize_symbol(symbol) || position[:exchange_symbol] == normalize_symbol(symbol) }
    rescue => e
      @read_warnings << "Nado position readback unavailable: #{e.class}: #{e.message}"
      nil
    end

    def account_state
      return super if config_blockers.any?

      {
        venue: venue_name,
        mode: mode,
        status: "account_readonly",
        subaccount_preview: short_hex(subaccount),
        query_base_url: query_base_url,
        positions_count: positions.size,
        warnings: warnings,
        blockers: blockers
      }
    end

    def blockers
      [ "Dry-run/read-only only; live submit not enabled for Nado." ] + config_blockers
    end

    def warnings
      [
        "Nado preview applies configured size increment rounding when available.",
        "Nado account readback uses GET-only gateway queries when read-only config is supplied."
      ] + @read_warnings
    end

    private

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      super.merge(
        schema: "nado_eip712_order_preview",
        endpoint: "POST /execute",
        market_symbol: normalize_symbol(symbol),
        side: reduce_only ? "buy" : "sell",
        reduce_only: reduce_only,
        order_type: "IOC",
        amount: decimal_string(size_eth),
        size_increment: decimal_string(size_increment),
        size_rounding: "floor_to_size_increment",
        signature: nil,
        typed_data_available: false,
        blocker: "Nado live submit is intentionally disabled in delta_neutral"
      )
    end

    def round_size(value)
      decimal = BigDecimal(value.to_s)
      return decimal unless size_increment.positive?

      (decimal / size_increment).floor * size_increment
    end

    def size_increment
      raw = env["NADO_SIZE_INCREMENT"].presence
      raw ? BigDecimal(raw) : DEFAULT_SIZE_INCREMENT
    rescue ArgumentError
      DEFAULT_SIZE_INCREMENT
    end

    def config_blockers
      blockers = []
      blockers << "NADO_READ_ONLY_ENABLED is not true" unless bool_env("NADO_READ_ONLY_ENABLED")
      blockers << "NADO_GATEWAY_QUERY_BASE_URL or NADO_API_BASE_URL is required for Nado read-only checks" if env["NADO_GATEWAY_QUERY_BASE_URL"].blank? && env["NADO_API_BASE_URL"].blank?
      blockers << "NADO_ACCOUNT_ADDRESS or NADO_ACCOUNT_SUBACCOUNT is required for Nado position readback" if env["NADO_ACCOUNT_ADDRESS"].blank? && env["NADO_ACCOUNT_SUBACCOUNT"].blank?
      blockers
    end

    def positions
      @positions ||= begin
        data = response_payload(get_json("/query", type: "subaccount_info", subaccount: subaccount))
        product_map = product_map(data)
        Array(data["perp_balances"] || data["perp_positions"] || data["positions"]).filter_map do |row|
          normalize_position(row, product_map)
        end
      end
    end

    def normalize_symbol(symbol)
      symbol.to_s.upcase == "WETH" || symbol.to_s.upcase == "ETH" ? "ETH-PERP" : symbol
    end

    def normalize_position(row, product_map)
      return nil unless row.is_a?(Hash)

      product_id = (row["product_id"] || row["productId"]).to_s
      product = product_map.fetch(product_id, {})
      amount = decimal_or_nil(row.dig("balance", "amount")) || decimal_or_nil(row["size_base"]) || decimal_or_nil(row["size"]) || decimal_or_nil(row["amount"])
      return nil if amount.nil? || amount.zero?

      symbol = canonical_symbol(product["symbol"] || product["base"] || product["ticker_id"] || product_id)
      {
        venue: venue_name,
        asset: symbol == "ETH-PERP" ? "ETH" : symbol,
        symbol: symbol,
        exchange_symbol: symbol,
        size: amount.negative? ? amount : -amount,
        short_size: amount.negative? ? amount.abs : BigDecimal("0"),
        mark_price: decimal_or_nil(row["mark_price"] || row["markPrice"]),
        raw: row,
        status: "ok"
      }
    end

    def product_map(data)
      Array(data["perp_products"] || data["products"]).each_with_object({}) do |row, map|
        next unless row.is_a?(Hash)

        key = (row["product_id"] || row["productId"] || row["id"]).to_s
        map[key] = row if key.present?
      end
    end

    def response_payload(response)
      return response["data"] if response.is_a?(Hash) && response["data"].is_a?(Hash)
      return response if response.is_a?(Hash)

      {}
    end

    def get_json(path, params)
      uri = URI.join(query_base_url.end_with?("/") ? query_base_url : "#{query_base_url}/", path.delete_prefix("/"))
      uri.query = URI.encode_www_form(params)
      response = @http_get.call(uri)
      JSON.parse(response)
    end

    def http_get(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: HTTP_TIMEOUT_SECONDS, read_timeout: HTTP_TIMEOUT_SECONDS) do |http|
        request = Net::HTTP::Get.new(uri)
        response = http.request(request)
        raise "Nado read-only GET failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response.body
      end
    end

    def query_base_url
      (env["NADO_GATEWAY_QUERY_BASE_URL"].presence || env["NADO_API_BASE_URL"]).to_s.delete_suffix("/")
    end

    def subaccount
      env["NADO_ACCOUNT_SUBACCOUNT"].presence || derive_sender
    end

    def derive_sender
      address = env["NADO_ACCOUNT_ADDRESS"].to_s.downcase.delete_prefix("0x")
      return nil unless address.match?(/\A[0-9a-f]{40}\z/)

      name = env.fetch("NADO_ACCOUNT_SUBACCOUNT_NAME", "default")
      return nil unless name.bytesize <= 12

      "0x#{address}#{name.unpack1('H*').ljust(24, '0')}"
    end

    def canonical_symbol(value)
      text = value.to_s.upcase
      return "ETH-PERP" if text == "ETH" || text == "WETH"

      text
    end

    def decimal_or_nil(value)
      return nil if value.nil?

      decimal = BigDecimal(value.to_s)
      decimal.abs > 10**12 ? decimal / (10**18) : decimal
    rescue ArgumentError
      nil
    end

    def short_hex(value)
      return nil if value.blank?

      value.length > 20 ? "#{value[0, 10]}...#{value[-6, 6]}" : value
    end
  end
end
