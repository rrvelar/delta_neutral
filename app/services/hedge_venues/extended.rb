module HedgeVenues
  class Extended < Base
    REQUIRED_CONFIG = {
      "EXTENDED_API_BASE_URL" => "EXTENDED_API_BASE_URL missing",
      "EXTENDED_API_KEY" => "EXTENDED_API_KEY missing",
      "EXTENDED_ACCOUNT_ID" => "EXTENDED_ACCOUNT_ID missing",
      "EXTENDED_VAULT_NUMBER" => "EXTENDED_VAULT_NUMBER missing",
      "EXTENDED_CLIENT_ID" => "EXTENDED_CLIENT_ID missing",
      "EXTENDED_STARK_PUBLIC_KEY" => "EXTENDED_STARK_PUBLIC_KEY missing"
    }.freeze
    REQUIRED_MARKET_METADATA = {
      "EXTENDED_MARKET_SYMBOL" => "EXTENDED_MARKET_SYMBOL missing",
      "EXTENDED_SIZE_INCREMENT" => "EXTENDED_SIZE_INCREMENT missing",
      "EXTENDED_PRICE_INCREMENT" => "EXTENDED_PRICE_INCREMENT missing"
    }.freeze

    def initialize(env: ENV, api_client: nil, **kwargs)
      super(env: env, **kwargs)
      @api_client = api_client || ExtendedApiClient.new(env: env)
    end

    def venue_name
      "Extended"
    end

    def mode
      "read_only_scaffold"
    end

    def live_supported?
      false
    end

    def live_enabled?
      false
    end

    def live_flag_enabled?
      false
    end

    def live_confirmation_phrase
      nil
    end

    def read_position(symbol:)
      return nil if config_blockers.any?

      positions = array_payload(read_only_call(:positions, market: market_symbol))
      row = positions.filter_map { |item| normalize_position_row(item) }.find do |position|
        position[:market_symbol].to_s.casecmp?(market_symbol) && position[:side].in?(%w[short long])
      end
      return nil unless row

      row.merge(account_value_fields)
    end

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      dry_run_preview(action: "open_short", symbol: symbol, size_eth: size_eth, max_slippage: max_slippage, reduce_only: false)
    end

    def rebalance_preview(symbol:, delta_eth:, max_slippage:)
      delta = BigDecimal(delta_eth.to_s)
      if delta.negative?
        dry_run_preview(action: "decrease_short", symbol: symbol, size_eth: delta.abs, max_slippage: max_slippage, reduce_only: true)
      else
        dry_run_preview(action: "increase_short", symbol: symbol, size_eth: delta, max_slippage: max_slippage, reduce_only: false)
      end
    end

    def close_preview(symbol:, size_eth:)
      dry_run_preview(action: "close_short", symbol: symbol, size_eth: size_eth, max_slippage: nil, reduce_only: true)
    end

    def normalize_position(snapshot)
      source = snapshot.to_h.with_indifferent_access
      size = decimal_or_nil(source[:size])
      side = normalized_side(source[:side], size)
      short_size = side == "short" ? (size&.abs || decimal_or_nil(source[:short_size]) || BigDecimal("0")) : BigDecimal("0")
      notional = decimal_or_nil(source[:notional_usd] || source[:value])
      account_value = decimal_or_nil(source[:account_value_usd] || source[:collateral_usd] || source[:equity])
      effective = notional && account_value&.positive? ? notional.abs / account_value : decimal_or_nil(source[:effective_leverage])

      {
        venue: venue_name,
        symbol: "ETH-PERP",
        market_symbol: source[:market] || market_symbol,
        side: side,
        size: size&.to_s("F"),
        short_size: short_size.to_s("F"),
        notional_usd: decimal_string_or_value(notional),
        entry_price: decimal_string_or_value(decimal_or_nil(source[:entry_price] || source[:open_price])),
        mark_price: decimal_string_or_value(decimal_or_nil(source[:mark_price])),
        unrealized_pnl_usd: decimal_string_or_value(decimal_or_nil(source[:unrealized_pnl_usd] || source[:unrealised_pnl])),
        account_value_usd: decimal_string_or_value(account_value),
        collateral_usd: decimal_string_or_value(decimal_or_nil(source[:collateral_usd] || source[:balance])),
        effective_leverage: effective&.to_s("F"),
        margin_mode: source[:margin_mode] || "unverified",
        status: source[:status],
        raw: source[:raw]
      }.compact
    end

    def account_state
      account_info = read_only_call(:account_info)
      balance = read_only_call(:balance)
      market = read_only_call(:market, market: market_symbol)
      current_position = read_position(symbol: "ETH")
      account_value = decimal_or_nil(value_from(balance, :equity, :accountValue, :account_value, :balance))
      collateral = decimal_or_nil(value_from(balance, :balance, :collateral, :equity))

      {
        venue: venue_name,
        mode: mode,
        status: account_state_status(account_info: account_info, balance: balance, market: market),
        live_supported: false,
        live_enabled: false,
        market_symbol: market_symbol,
        margin_mode: current_position&.fetch(:margin_mode, nil) || "unverified",
        current_short_eth: current_position&.fetch(:short_size, nil),
        current_side: current_position&.fetch(:side, nil),
        account_value_usd: account_value&.to_s("F"),
        collateral_usd: collateral&.to_s("F"),
        market_metadata_available: market_metadata_available?,
        market_metadata: safe_market_metadata(market),
        open_orders_count: open_orders_count,
        blockers: blockers,
        warnings: warnings
      }
    end

    def blockers
      (config_blockers + market_metadata_blockers + [
        "Extended live disabled.",
        "Extended submit endpoint integration not implemented.",
        "Extended auto-rebalance disabled."
      ]).uniq
    end

    def warnings
      [
        "Extended read-only scaffold.",
        "Live disabled.",
        "Submit/cancel endpoint integration not implemented.",
        "Extended requires a separate Stark signer sidecar before any Phase 3+ live test."
      ]
    end

    private

    attr_reader :api_client

    def dry_run_preview(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      requested_size = decimal_or_nil(size_eth)
      rounded_size = rounded_order_size_or_nil(requested_size)
      {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        action: action,
        symbol: symbol,
        requested_size_eth: decimal_string_or_unknown(requested_size),
        rounded_size_eth: rounded_size ? rounded_size.to_s("F") : "unknown",
        max_slippage: max_slippage&.to_s,
        reduce_only: reduce_only,
        submit_enabled: false,
        signature_required: false,
        order_submission: false,
        payload: order_intent_payload(
          action: action,
          symbol: symbol,
          requested_size: requested_size,
          rounded_size: rounded_size,
          max_slippage: max_slippage,
          reduce_only: reduce_only
        ),
        blockers: blockers,
        warnings: warnings
      }
    end

    def configured?
      config_blockers.empty?
    end

    def config_blockers
      REQUIRED_CONFIG.filter_map do |key, message|
        message if env[key].blank?
      end
    end

    def market_metadata_available?
      market_metadata_blockers.empty?
    end

    def market_metadata_blockers
      REQUIRED_MARKET_METADATA.filter_map do |key, message|
        message if env[key].blank?
      end
    end

    def market_symbol
      env["EXTENDED_MARKET_SYMBOL"].presence || "ETH-USD"
    end

    def order_intent_payload(action:, symbol:, requested_size:, rounded_size:, max_slippage:, reduce_only:)
      side = reduce_only ? "buy" : "sell"
      {
        schema: "extended_dry_run_order_intent",
        body_shape: "extended_order_intent_summary",
        venue: venue_name,
        market_symbol: market_symbol,
        symbol: symbol,
        action: action,
        side: side,
        extended_side: side.upcase,
        reduce_only: reduce_only,
        requested_size_eth: decimal_string_or_unknown(requested_size),
        rounded_size_eth: rounded_size ? rounded_size.to_s("F") : "unknown",
        size_increment: env["EXTENDED_SIZE_INCREMENT"].presence || "required_later",
        price_increment: env["EXTENDED_PRICE_INCREMENT"].presence || "required_later",
        price: "required_later",
        crossing_price: "required_later",
        order_type_assumption: "market-like crossing IOC limit; Extended requires an explicit worst accepted price",
        time_in_force: "IOC_required_later",
        expiration: "required_later",
        fee: "required_later",
        client_id: env["EXTENDED_CLIENT_ID"].presence || "required_later",
        vault_number: env["EXTENDED_VAULT_NUMBER"].presence || "required_later",
        account_id: env["EXTENDED_ACCOUNT_ID"].presence || "required_later",
        stark_public_key: redacted(env["EXTENDED_STARK_PUBLIC_KEY"]),
        nonce: "required_later",
        max_slippage: max_slippage&.to_s,
        margin_mode: "unverified",
        submit_endpoint: nil,
        future_submit_endpoint: "POST /user/order",
        signer_request: {
          schema: "extended_stark_order_sign_request",
          status: "blocked_hash_algorithm_not_verified",
          signer_boundary: "external_extended_stark_signer",
          private_key_in_rails: false
        },
        order_submission: false,
        signature_required: false,
        stark_signature_created: false,
        signing_implemented: false,
        submit_implemented: false,
        cancel_implemented: false
      }
    end

    def rounded_order_size_or_nil(size)
      increment = decimal_or_nil(env["EXTENDED_SIZE_INCREMENT"])
      return nil unless size && increment&.positive?

      (size / increment).floor * increment
    end

    def normalized_side(raw_side, size)
      return "short" if size&.negative?

      text = raw_side.to_s.downcase
      return "short" if text.in?(%w[short sell])
      return "long" if text.in?(%w[long buy])
      return "long" if size&.positive?

      "flat"
    end

    def decimal_or_nil(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def decimal_string_or_value(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value
    end

    def decimal_string_or_unknown(value)
      value ? value.to_s("F") : "unknown"
    end

    def read_only_call(method_name, **kwargs)
      return nil if config_blockers.any?

      api_client.public_send(method_name, **kwargs)
    rescue => e
      { "error" => "#{e.class}: #{e.message}" }
    end

    def account_state_status(account_info:, balance:, market:)
      return "not_configured" if config_blockers.any?
      return "read_only_error" if [ account_info, balance, market ].any? { |value| value.is_a?(Hash) && value["error"].present? }

      "read_only"
    end

    def open_orders_count
      orders = read_only_call(:open_orders, market: market_symbol)
      orders = array_payload(orders)

      orders.size
    end

    def normalize_position_row(row)
      source = row.to_h.with_indifferent_access
      market = value_from(source, :market, :symbol, :marketName)
      return nil if market.present? && !market.to_s.casecmp?(market_symbol)

      normalize_position(
        market: market || market_symbol,
        side: value_from(source, :side, :direction),
        size: signed_size_from(source),
        notional_usd: value_from(source, :notional_usd, :value, :positionValue),
        entry_price: value_from(source, :entry_price, :openPrice, :averageOpenPrice),
        mark_price: value_from(source, :mark_price, :markPrice),
        unrealized_pnl_usd: value_from(source, :unrealized_pnl_usd, :unrealisedPnl, :unrealizedPnl),
        margin_mode: value_from(source, :margin_mode, :marginMode) || "unverified",
        status: value_from(source, :status),
        raw: safe_raw_position(source)
      )
    end

    def signed_size_from(source)
      size = decimal_or_nil(value_from(source, :size, :qty, :quantity))
      return nil unless size

      side = value_from(source, :side, :direction).to_s.downcase
      return -size.abs if side.in?(%w[short sell])
      return size.abs if side.in?(%w[long buy])

      size
    end

    def account_value_fields
      balance = read_only_call(:balance)
      return {} unless balance.is_a?(Hash)

      account_value = decimal_or_nil(value_from(balance, :equity, :accountValue, :account_value, :balance))
      collateral = decimal_or_nil(value_from(balance, :balance, :collateral, :equity))
      {
        account_value_usd: account_value&.to_s("F"),
        collateral_usd: collateral&.to_s("F")
      }.compact
    end

    def safe_market_metadata(market)
      return nil unless market.is_a?(Hash)

      {
        name: value_from(market, :name, :market),
        active: value_from(market, :active, :status),
        mark_price: value_from(market, :markPrice, :mark_price, :marketStats, :stats)
      }.compact
    end

    def safe_raw_position(source)
      source.except(:apiKey, :api_key, :signature, :starkPrivateKey, :stark_private_key)
    end

    def value_from(source, *keys)
      keys.each do |key|
        return source[key] if source.respond_to?(:key?) && source.key?(key)
        return source[key.to_s] if source.respond_to?(:key?) && source.key?(key.to_s)
      end
      nil
    end

    def redacted(value)
      value.present? ? "<redacted>" : "required_later"
    end

    def array_payload(payload)
      return payload if payload.is_a?(Array)
      return payload["data"] if payload.is_a?(Hash) && payload["data"].is_a?(Array)
      return payload[:data] if payload.is_a?(Hash) && payload[:data].is_a?(Array)
      return payload["positions"] if payload.is_a?(Hash) && payload["positions"].is_a?(Array)
      return payload[:positions] if payload.is_a?(Hash) && payload[:positions].is_a?(Array)
      return payload["orders"] if payload.is_a?(Hash) && payload["orders"].is_a?(Array)
      return payload[:orders] if payload.is_a?(Hash) && payload[:orders].is_a?(Array)

      []
    end
  end
end
