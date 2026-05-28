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

    def live_supported?
      true
    end

    def live_enabled?
      live_flag_enabled?
    end

    def live_flag_enabled?
      bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    end

    def live_confirmation_phrase
      env["AERODROME_NADO_HEDGE_CONFIRMATION"].to_s
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

      open_orders = open_orders_count
      {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        status: "account_readonly",
        subaccount_preview: short_hex(subaccount),
        query_base_url: query_base_url,
        positions_count: positions.size,
        raw_positions_count: raw_position_like_rows.size,
        raw_slots_count: raw_slot_rows.size,
        raw_products_count: raw_product_rows.size,
        raw_position_like_count: raw_position_like_rows.size,
        unresolved_position_like_count: unresolved_position_like_rows.size,
        normalized_positions_count: positions.size,
        hedge_positions_count: eth_perp_positions.size,
        open_orders_read_available: !open_orders.nil?,
        open_orders_unavailable_reason: open_orders_unavailable_reason,
        open_orders_count: open_orders,
        current_short_eth: current_eth_perp_short&.dig(:short_size)&.to_s("F"),
        current_side: current_eth_perp_short&.dig(:side),
        product_id: current_eth_perp_short&.dig(:product_id),
        margin_mode: current_eth_perp_short&.dig(:margin_mode),
        margin_warning: current_margin_warning,
        warnings: warnings,
        blockers: blockers
      }
    end

    def open_orders_count
      return nil if config_blockers.any?

      rows = open_orders_rows
      return nil if rows.nil?

      rows.count { |row| nado_eth_order_row?(row) }
    rescue => e
      @open_orders_read_error = "Nado open orders readback unavailable: #{e.class}: #{e.message}"
      nil
    end

    def open_orders_unavailable_reason
      return "Nado read-only config is incomplete." if config_blockers.any?
      return @open_orders_read_error if @open_orders_read_error.present?
      return nil unless defined?(@open_orders_rows) && @open_orders_rows.nil?

      "Nado open orders query returned no parseable order list."
    end

    def blockers
      live_blockers = live_flag_enabled? ? [] : [ "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit." ]
      live_blockers + config_blockers + parser_blockers
    end

    def warnings
      [
        "Nado preview applies configured size increment rounding when available.",
        "Nado account readback uses GET-only gateway queries when read-only config is supplied."
      ] + parser_warnings + @read_warnings + Array(@open_orders_read_error)
    end

    def raw_positions_present_but_unnormalized?
      return false if config_blockers.any?

      unresolved_position_like_rows.any?
    rescue
      false
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
        data = subaccount_info
        products = product_map(data)
        cross_margin = raw_cross_margin_position_rows.filter_map { |row| normalize_cross_margin_position(row, products) }
        if cross_margin.any?
          cross_margin
        else
          isolated_position_rows.filter_map { |row| normalize_isolated_position(row, products) }
        end
      end
    end

    def subaccount_info
      @subaccount_info ||= response_payload(get_json("/query", type: "subaccount_info", subaccount: subaccount))
    end

    def isolated_info
      @isolated_info ||= response_payload(get_json("/query", type: "isolated_positions", subaccount: subaccount))
    rescue => e
      @read_warnings << "Nado isolated position readback unavailable: #{e.class}: #{e.message}"
      {}
    end

    def open_orders_rows
      return @open_orders_rows if defined?(@open_orders_rows)

      raw_response = get_json("/query", type: "open_orders", subaccount: subaccount)
      response = raw_response.is_a?(Array) ? raw_response : response_payload(raw_response)
      rows = response["open_orders"] || response["orders"] || response["data"] || response
      @open_orders_rows = rows.is_a?(Array) ? rows.select { |row| row.is_a?(Hash) } : nil
    rescue => e
      @open_orders_read_error = "Nado open orders readback unavailable: #{e.class}: #{e.message}"
      @open_orders_rows = nil
    end

    def nado_eth_order_row?(row)
      product_id = product_id_from(row)
      symbol = canonical_symbol(row["symbol"] || row["market"] || row["ticker"] || row["product"] || "perp_product:#{product_id}")
      eth_perp_position?(symbol, product_id)
    end

    def raw_position_rows
      raw_cross_margin_position_rows + isolated_position_rows
    end

    def raw_slot_rows
      raw_position_rows
    end

    def raw_product_rows
      data = subaccount_info
      Array(data["perp_products"] || data["products"]).select { |row| row.is_a?(Hash) }
    end

    def raw_position_like_rows
      raw_position_rows.select { |row| position_like_row?(row) }
    end

    def unresolved_position_like_rows
      raw_position_like_rows.reject { |row| positions.any? { |position| position.dig(:metadata, :raw) == row } }
    end

    def raw_cross_margin_position_rows
      data = subaccount_info
      Array(data["perp_balances"] || data["perp_positions"] || data["positions"]).select { |row| row.is_a?(Hash) }
    end

    def isolated_position_rows
      Array(isolated_info["isolated_positions"]).select { |row| row.is_a?(Hash) }
    end

    def eth_perp_positions
      positions.select { |position| position[:symbol] == "ETH-PERP" || position[:product_id].to_i == 4 }
    end

    def current_eth_perp_short
      eth_perp_positions.find { |position| position[:side] == "short" }
    end

    def parser_warnings
      return [] if config_blockers.any?

      warnings = []
      if unresolved_position_like_rows.any?
        warnings << "Nado raw positions are present but no ETH-PERP position was normalized."
      end
      warnings << current_margin_warning if current_margin_warning
      warnings
    end

    def parser_blockers
      raw_positions_present_but_unnormalized? ? [ "Nado raw positions are present but parser could not normalize ETH-PERP; refusing to submit another order." ] : []
    end

    def normalize_symbol(symbol)
      symbol.to_s.upcase == "WETH" || symbol.to_s.upcase == "ETH" ? "ETH-PERP" : symbol
    end

    def normalize_cross_margin_position(row, product_map)
      return nil unless row.is_a?(Hash)

      product_id = product_id_from(row)
      product = product_map.fetch(product_id, {})
      amount = position_amount(row)
      return nil if amount.nil? || amount.zero?

      symbol = position_symbol(row, product, product_id)
      return nil unless eth_perp_position?(symbol, product_id)

      build_position(row: row, product: product, product_id: product_id, symbol: symbol, amount: amount, margin_mode: "cross")
    end

    def normalize_isolated_position(row, product_map)
      base_balance = row["base_balance"] || {}
      base_product = row["base_product"] || {}
      product_id = product_id_from(base_product).presence || product_id_from(base_balance).presence || product_id_from(row)
      product = product_map.fetch(product_id, {}).merge(base_product)
      amount = decimal_or_nil(base_balance.dig("balance", "amount")) || decimal_or_nil(base_balance["amount"])
      return nil if amount.nil? || amount.zero?

      symbol = position_symbol(row, product, product_id)
      return nil unless eth_perp_position?(symbol, product_id)

      build_position(row: row, product: product, product_id: product_id, symbol: symbol, amount: amount, margin_mode: "isolated")
    end

    def build_position(row:, product:, product_id:, symbol:, amount:, margin_mode:)
      symbol = "ETH-PERP" if product_id.to_i == 4
      mark_price = price_from_product(product) || decimal_or_nil(row["mark_price"] || row["markPrice"])
      raw_v_quote = raw_v_quote_balance(row)
      entry_price = decimal_or_nil(row["entry_price"] || row["entryPrice"]) || entry_price(amount: amount, raw_v_quote: raw_v_quote)
      notional = mark_price ? amount.abs * mark_price : decimal_or_nil(row["notional_usd"] || row["notional"])
      isolated_margin = isolated_margin(row, amount: amount)
      {
        venue: venue_name,
        asset: symbol == "ETH-PERP" ? "ETH" : symbol,
        symbol: symbol,
        exchange_symbol: symbol,
        product_id: product_id.present? ? product_id.to_i : nil,
        side: amount.negative? ? "short" : "long",
        size: amount,
        size_base: amount.abs,
        short_size: amount.negative? ? amount.abs : BigDecimal("0"),
        margin_mode: margin_mode,
        entry_price: entry_price,
        mark_price: mark_price,
        notional_usd: notional,
        isolated_margin_usd: isolated_margin,
        metadata: {
          raw_product_id: product_id.presence,
          raw: row,
          source: margin_mode == "cross" ? "subaccount_info" : "isolated_positions"
        },
        status: "ok"
      }
    end

    def product_map(data)
      Array(data["perp_products"] || data["products"]).each_with_object({}) do |row, map|
        next unless row.is_a?(Hash)

        key = product_id_from(row)
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
      return text.split("_", 2).first if text.include?("-PERP_")

      text
    end

    def product_id_from(row)
      (row["product_id"] || row["productId"] || row["asset_id"] || row["assetId"] || row["id"]).to_s
    end

    def position_symbol(row, product, product_id)
      canonical_symbol(
        row["symbol"] || row["exchange_symbol"] || row["exchangeSymbol"] || row["market"] || row["ticker"] ||
          product["symbol"] || product["base"] || product["ticker_id"] || product["ticker"] || product["name"] ||
          "perp_product:#{product_id}"
      )
    end

    def eth_perp_position?(symbol, product_id)
      symbol == "ETH-PERP" || product_id.to_i == 4
    end

    def position_amount(row)
      balance = row["balance"].is_a?(Hash) ? row["balance"] : {}
      signed = decimal_or_nil(balance["amount"]) ||
        decimal_or_nil(row["size_base"]) ||
        decimal_or_nil(row["size"]) ||
        decimal_or_nil(row["amount"]) ||
        decimal_or_nil(row["base_balance"])
      return signed if signed

      unsigned = decimal_or_nil(row["abs_size"] || row["size_base_abs"] || row["quantity"])
      return nil unless unsigned

      side = (row["side"] || row["direction"]).to_s.downcase
      side == "short" || side == "sell" ? -unsigned : unsigned
    end

    def position_like_row?(row)
      amount = position_amount(row)
      return false if amount.nil? || amount.zero?

      product_id = product_id_from(row)
      product = product_map(subaccount_info).fetch(product_id, {})
      return true if eth_perp_position?(position_symbol(row, product, product_id), product_id)

      product_id.blank? && ambiguous_position_row?(row)
    end

    def ambiguous_position_row?(row)
      row.key?("balance") || row.key?("size") || row.key?("size_base") || row.key?("amount") || row.key?("base_balance")
    end

    def price_from_product(product)
      risk = product["risk"].is_a?(Hash) ? product["risk"] : {}
      decimal_or_nil(risk["price_x18"] || risk["oracle_price_x18"] || product["price_x18"] || product["oracle_price_x18"]) ||
        decimal_or_nil(product["mark_price"] || product["markPrice"])
    end

    def raw_v_quote_balance(row)
      row.dig("base_balance", "balance", "v_quote_balance") ||
        row.dig("base_balance", "v_quote_balance") ||
        row.dig("balance", "v_quote_balance") ||
        row["v_quote_balance"] ||
        row["vQuoteBalance"]
    end

    def entry_price(amount:, raw_v_quote:)
      quote = decimal_or_nil(raw_v_quote)
      return nil if quote.nil? || amount.zero?

      (quote / amount).abs
    end

    def isolated_margin(row, amount:)
      return nil unless amount

      raw_quote = row.dig("quote_balance", "balance", "amount") || row.dig("quote_balance", "amount")
      decimal_or_nil(raw_quote)&.abs
    end

    def current_margin_warning
      return nil unless current_eth_perp_short&.dig(:margin_mode) == "cross"

      "Current Nado hedge is cross-margin; target mode is isolated 1x. Close and reopen isolated after confirmation."
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
