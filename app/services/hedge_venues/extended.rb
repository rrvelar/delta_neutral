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
      "EXTENDED_MARKET_SYMBOL" => "EXTENDED_MARKET_SYMBOL missing"
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
      account_values = account_value_fields_from(balance: balance, account_info: account_info)

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
        account_value_usd: account_values[:account_value_usd],
        collateral_usd: account_values[:collateral_usd],
        read_only_diagnostics: read_only_account_diagnostics(
          account_info: account_info,
          balance: balance,
          current_position: current_position
        ),
        market_metadata_available: market_metadata_available?,
        market_metadata: market_metadata_diagnostics(raw_market: market),
        open_orders_count: open_orders_count,
        blockers: blockers,
        warnings: warnings
      }
    end

    def market_metadata_diagnostics(raw_market: nil)
      metadata = raw_market ? normalize_market_metadata(raw_market) : discovered_market_metadata
      {
        source: metadata[:source],
        requested_market_symbol: market_symbol,
        matched_market_symbol: metadata[:market_symbol],
        size_increment: size_increment(metadata)&.to_s("F"),
        size_increment_source: size_increment_source(metadata),
        price_increment: price_increment(metadata)&.to_s("F"),
        price_increment_source: price_increment_source(metadata),
        min_size: metadata[:min_size],
        min_notional: metadata[:min_notional],
        mark_price: metadata[:mark_price],
        collateral_asset_id_present: metadata[:collateral_asset_id].present?,
        synthetic_asset_id_present: metadata[:synthetic_asset_id].present?,
        collateral_resolution: metadata[:collateral_resolution],
        synthetic_resolution: metadata[:synthetic_resolution],
        response_keys: metadata[:response_keys],
        market_keys: metadata[:market_keys],
        trading_config_keys: metadata[:trading_config_keys],
        l2_config_keys: metadata[:l2_config_keys]
      }.compact
    end

    def read_only_account_diagnostics(account_info: nil, balance: nil, current_position: nil, open_orders: nil)
      account_info = read_only_call(:account_info) if account_info.nil? && configured?
      balance = read_only_call(:balance) if balance.nil? && configured?
      current_position = read_position(symbol: "ETH") if current_position.nil? && configured?
      open_orders = read_only_call(:open_orders, market: market_symbol) if open_orders.nil? && configured?
      account_values = account_value_fields_from(balance: balance, account_info: account_info)

      {
        account_read_attempted: configured?,
        balance_read_attempted: configured?,
        positions_read_attempted: configured?,
        open_orders_read_attempted: configured?,
        account_read_status: read_status(account_info),
        balance_read_status: read_status(balance),
        balance_http_status: balance_http_status(balance),
        balance_stop_reason: balance_stop_reason(balance),
        balance_response_keys: safe_keys(balance),
        balance_data_keys: safe_keys(data_payload(balance)),
        positions_read_status: configured? ? "attempted" : "not_configured",
        open_orders_read_status: read_status(open_orders),
        account_value_usd: account_values[:account_value_usd],
        collateral_usd: account_values[:collateral_usd],
        current_position_status: current_position ? "position_present" : "no_position",
        current_position_side: current_position&.fetch(:side, nil),
        current_short_eth: current_position&.fetch(:short_size, nil),
        open_orders_count: open_orders.nil? ? nil : array_payload(open_orders).size
      }.compact
    end

    def extended_live_order(preview:, now: Time.current)
      payload = preview.fetch(:payload)
      side = payload.fetch(:extended_side)
      qty = payload.fetch(:rounded_size_eth)
      price = worst_accepted_price(side: side, max_slippage: payload[:max_slippage])
      metadata = discovered_market_metadata
      {
        "market" => market_symbol,
        "type" => "MARKET",
        "side" => side,
        "qty" => qty,
        "price" => price&.to_s("F"),
        "reduceOnly" => payload.fetch(:reduce_only),
        "postOnly" => false,
        "timeInForce" => "IOC",
        "expiryEpochMillis" => ((now.to_f + 14.days.to_f) * 1000).ceil,
        "fee" => taker_fee_rate.to_s("F"),
        "nonce" => nonce_millis(now),
        "selfTradeProtectionLevel" => "ACCOUNT",
        "vault" => env["EXTENDED_VAULT_NUMBER"].to_s,
        "starkPublicKey" => env["EXTENDED_STARK_PUBLIC_KEY"].to_s,
        "syntheticAssetId" => metadata[:synthetic_asset_id],
        "syntheticResolution" => metadata[:synthetic_resolution].to_s,
        "collateralAssetId" => metadata[:collateral_asset_id],
        "collateralResolution" => metadata[:collateral_resolution].to_s,
        "starknetDomain" => starknet_domain
      }.compact
    end

    def live_order_blockers(preview:)
      payload = preview.fetch(:payload)
      metadata = discovered_market_metadata
      blockers = []
      blockers.concat(payload.fetch(:validation_blockers, []))
      blockers << "Extended rounded order size unavailable." if payload[:rounded_size_eth] == "unknown"
      blockers << "Extended mark price unavailable for crossing price." unless decimal_or_nil(metadata[:mark_price])
      blockers << "Extended taker fee unavailable." unless taker_fee_rate
      blockers << "Extended l2Config.syntheticId missing from market metadata." if metadata[:synthetic_asset_id].blank?
      blockers << "Extended l2Config.collateralId missing from market metadata." if metadata[:collateral_asset_id].blank?
      blockers << "Extended l2Config.syntheticResolution missing from market metadata." if metadata[:synthetic_resolution].blank?
      blockers << "Extended l2Config.collateralResolution missing from market metadata." if metadata[:collateral_resolution].blank?
      blockers
    end

    def live_readiness_blockers
      (config_blockers + market_metadata_blockers).uniq
    end

    def submit_order(payload)
      api_client.submit_order(payload)
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
      validation = order_size_validation(requested_size: requested_size, rounded_size: rounded_size)
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
          validation: validation,
          max_slippage: max_slippage,
          reduce_only: reduce_only
        ),
        blockers: (blockers + validation[:blockers]).uniq,
        warnings: (warnings + validation[:warnings]).uniq
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
      blockers = REQUIRED_MARKET_METADATA.filter_map do |key, message|
        message if env[key].blank?
      end
      blockers << "EXTENDED_SIZE_INCREMENT missing and not discovered from Extended market metadata" unless size_increment
      blockers << "EXTENDED_PRICE_INCREMENT missing and not discovered from Extended market metadata" unless price_increment
      blockers
    end

    def market_symbol
      env["EXTENDED_MARKET_SYMBOL"].presence || "ETH-USD"
    end

    def order_intent_payload(action:, symbol:, requested_size:, rounded_size:, validation:, max_slippage:, reduce_only:)
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
        min_size: validation[:min_size],
        min_notional: validation[:min_notional],
        estimated_notional_usd: validation[:estimated_notional_usd],
        size_valid: validation[:size_valid],
        notional_valid: validation[:notional_valid],
        validation_blockers: validation[:blockers],
        size_increment: size_increment&.to_s("F") || "required_later",
        size_increment_source: size_increment_source,
        price_increment: price_increment&.to_s("F") || "required_later",
        price_increment_source: price_increment_source,
        market_metadata: market_metadata_diagnostics,
        price: "required_later",
        crossing_price: worst_accepted_price(side: side.upcase, max_slippage: max_slippage)&.to_s("F") || "required_later",
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

    def worst_accepted_price(side:, max_slippage:)
      mark = decimal_or_nil(discovered_market_metadata[:mark_price])
      increment = price_increment
      slippage = decimal_or_nil(max_slippage) || BigDecimal("0.01")
      return nil unless mark&.positive? && increment&.positive?

      raw = side.to_s.upcase == "BUY" ? mark * (1 + slippage) : mark * (1 - slippage)
      quotient = raw / increment
      rounded = if side.to_s.upcase == "BUY"
        quotient.ceil * increment
      else
        quotient.floor * increment
      end
      rounded.positive? ? rounded : increment
    end

    def order_size_validation(requested_size:, rounded_size:)
      metadata = discovered_market_metadata
      min_size = decimal_or_nil(metadata[:min_size])
      min_notional = decimal_or_nil(metadata[:min_notional])
      mark_price = decimal_or_nil(metadata[:mark_price])
      validation_size = rounded_size || requested_size
      estimated_notional = validation_size && mark_price ? validation_size.abs * mark_price : nil
      blockers = []

      if min_size&.positive? && validation_size && validation_size.abs < min_size
        blockers << "requested size #{validation_size.to_s('F')} is below Extended min order size #{min_size.to_s('F')}"
      end

      if min_notional&.positive? && estimated_notional && estimated_notional < min_notional
        blockers << "estimated notional #{estimated_notional.to_s('F')} is below Extended min notional #{min_notional.to_s('F')}"
      end

      {
        min_size: min_size&.to_s("F"),
        min_notional: min_notional&.to_s("F"),
        estimated_notional_usd: estimated_notional&.to_s("F"),
        size_valid: blockers.none? { |blocker| blocker.include?("min order size") },
        notional_valid: blockers.none? { |blocker| blocker.include?("min notional") },
        blockers: blockers,
        warnings: blockers
      }
    end

    def rounded_order_size_or_nil(size)
      increment = size_increment
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
      return "read_only_error" if account_info.is_a?(Hash) && account_info["error"].present?
      return "read_only_error" if market.is_a?(Hash) && market["error"].present?
      return "read_only_error" if balance.is_a?(Hash) && balance["error"].present? && read_status(balance) != "unsupported"

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
      account_value_fields_from(balance: balance, account_info: nil)
    end

    def account_value_fields_from(balance:, account_info:)
      source = data_payload(balance)
      source = data_payload(account_info) unless source.is_a?(Hash) && balance_fields_present?(source)
      return {} unless source.is_a?(Hash)

      account_value = decimal_or_nil(value_from(source, :equity, :accountValue, :account_value))
      collateral = decimal_or_nil(value_from(source, :balance, :collateral, :collateralBalance, :walletBalance))
      {
        account_value_usd: account_value&.to_s("F"),
        collateral_usd: collateral&.to_s("F")
      }.compact
    end

    def read_status(payload)
      return "not_configured" unless configured?
      return "not_attempted" if payload.nil?
      return "unsupported" if balance_not_found?(payload)
      return "error" if payload.is_a?(Hash) && payload["error"].present?

      "ok"
    end

    def balance_stop_reason(payload)
      return "Extended balance endpoint returned HTTP 404; docs state this means the user's balance is 0." if balance_not_found?(payload)
      return payload["message"].presence || payload["error"] if payload.is_a?(Hash) && payload["error"].present?

      nil
    end

    def balance_http_status(payload)
      payload["http_status"] if payload.is_a?(Hash)
    end

    def balance_not_found?(payload)
      payload.is_a?(Hash) && payload["http_status"].to_i == 404
    end

    def data_payload(payload)
      return nil unless payload.is_a?(Hash)
      return payload.with_indifferent_access unless payload.key?("data") || payload.key?(:data)

      data = value_from(payload, :data)
      data.is_a?(Hash) ? data.with_indifferent_access : data
    end

    def balance_fields_present?(source)
      [ :equity, :accountValue, :account_value, :balance, :collateral, :collateralBalance, :walletBalance ].any? do |key|
        source.respond_to?(:key?) && (source.key?(key) || source.key?(key.to_s))
      end
    end

    def size_increment(metadata = discovered_market_metadata)
      decimal_or_nil(env["EXTENDED_SIZE_INCREMENT"]) || decimal_or_nil(metadata[:size_increment])
    end

    def price_increment(metadata = discovered_market_metadata)
      decimal_or_nil(env["EXTENDED_PRICE_INCREMENT"]) || decimal_or_nil(metadata[:price_increment])
    end

    def size_increment_source(metadata = discovered_market_metadata)
      return "env" if decimal_or_nil(env["EXTENDED_SIZE_INCREMENT"])
      return metadata[:source] if metadata[:size_increment].present?

      "missing"
    end

    def price_increment_source(metadata = discovered_market_metadata)
      return "env" if decimal_or_nil(env["EXTENDED_PRICE_INCREMENT"])
      return metadata[:source] if metadata[:price_increment].present?

      "missing"
    end

    def discovered_market_metadata
      @discovered_market_metadata ||= normalize_market_metadata(read_only_call(:market, market: market_symbol))
    end

    def normalize_market_metadata(raw)
      return empty_market_metadata(raw) unless raw.is_a?(Hash) || raw.is_a?(Array)

      response = raw.is_a?(Hash) ? raw.with_indifferent_access : raw
      candidates = market_candidates(response)
      selected = candidates.find { |item| market_name(item).to_s.casecmp?(market_symbol) } || candidates.first
      return empty_market_metadata(raw) unless selected

      market = selected.to_h.with_indifferent_access
      trading = nested_hash(market, :tradingConfig, :trading_config)
      stats = nested_hash(market, :marketStats, :market_stats)
      l2_config = nested_hash(market, :l2Config, :l2_config)

      {
        source: "extended_api_market_metadata",
        market_symbol: market_name(market),
        active: value_from(market, :active, :status),
        mark_price: value_from(market, :markPrice, :mark_price) || value_from(stats, :markPrice, :mark_price),
        collateral_asset_id: value_from(l2_config, :collateralId, :collateral_id),
        synthetic_asset_id: value_from(l2_config, :syntheticId, :synthetic_id),
        collateral_resolution: value_from(l2_config, :collateralResolution, :collateral_resolution),
        synthetic_resolution: value_from(l2_config, :syntheticResolution, :synthetic_resolution),
        size_increment: value_from(market, :sizeIncrement, :size_increment, :quantityStep, :quantity_step, :qtyStep, :qty_step, :stepSize, :step_size) ||
          value_from(trading, :minOrderSizeChange, :min_order_size_change, :sizeIncrement, :size_increment, :quantityStep, :quantity_step, :qtyStep, :qty_step, :stepSize, :step_size),
        price_increment: value_from(market, :priceIncrement, :price_increment, :tickSize, :tick_size, :priceTick, :price_tick) ||
          value_from(trading, :minPriceChange, :min_price_change, :priceIncrement, :price_increment, :tickSize, :tick_size, :priceTick, :price_tick),
        min_size: value_from(market, :minOrderSize, :min_order_size, :minSize, :min_size, :minQty, :min_qty, :minQuantity, :min_quantity) ||
          value_from(trading, :minOrderSize, :min_order_size, :minSize, :min_size, :minQty, :min_qty, :minQuantity, :min_quantity),
        min_notional: value_from(market, :minOrderValue, :min_order_value, :minNotional, :min_notional, :minTradeValue, :min_trade_value, :minMarketOrderValue, :min_market_order_value) ||
          value_from(trading, :minOrderValue, :min_order_value, :minNotional, :min_notional, :minTradeValue, :min_trade_value, :minMarketOrderValue, :min_market_order_value),
        response_keys: safe_keys(response),
        market_keys: safe_keys(market),
        trading_config_keys: safe_keys(trading),
        l2_config_keys: safe_keys(l2_config)
      }.compact
    end

    def empty_market_metadata(raw)
      {
        source: raw.is_a?(Hash) && raw["error"].present? ? "extended_api_error" : "missing",
        response_keys: safe_keys(raw)
      }.compact
    end

    def market_candidates(response)
      return response if response.is_a?(Array)
      return nested_market_candidates(response[:data]) if response[:data].present?
      return nested_market_candidates(response[:result]) if response[:result].present?
      return response[:markets] if response[:markets].is_a?(Array)
      return [ response[:market] ] if response[:market].is_a?(Hash)
      return response.values if response.values.all? { |value| value.is_a?(Hash) }

      [ response ]
    end

    def nested_market_candidates(value)
      return value if value.is_a?(Array)
      return value[:markets] if value.is_a?(Hash) && value[:markets].is_a?(Array)
      return value.values if value.is_a?(Hash) && value.values.all? { |item| item.is_a?(Hash) }
      return [ value ] if value.is_a?(Hash)

      []
    end

    def market_name(market)
      value_from(market, :name, :market, :symbol, :marketName, :market_name)
    end

    def nested_hash(source, *keys)
      value = value_from(source, *keys)
      value.is_a?(Hash) ? value.with_indifferent_access : {}
    end

    def safe_keys(value)
      return [] unless value.respond_to?(:keys)

      value.keys.map(&:to_s).reject { |key| key.match?(/api|key|secret|signature|private/i) }.sort
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

    def taker_fee_rate
      decimal_or_nil(env["EXTENDED_TAKER_FEE_RATE"]) || fee_rate_from_api || BigDecimal("0.0005")
    end

    def fee_rate_from_api
      fees = read_only_call(:fees, market: market_symbol)
      rows = array_payload(fees)
      row = rows.find { |item| value_from(item, :market).to_s.casecmp?(market_symbol) } || rows.first
      decimal_or_nil(value_from(row.to_h.with_indifferent_access, :takerFeeRate, :taker_fee_rate)) if row
    rescue
      nil
    end

    def starknet_domain
      chain_id = env["EXTENDED_NETWORK"].to_s.downcase == "testnet" ? "SN_SEPOLIA" : "SN_MAIN"
      {
        "name" => "Perpetuals",
        "version" => "v0",
        "chainId" => chain_id,
        "revision" => "1"
      }
    end

    def nonce_millis(now)
      (now.to_f * 1000).to_i
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
