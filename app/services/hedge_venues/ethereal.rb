module HedgeVenues
  class Ethereal < Base
    def initialize(probe: nil, **kwargs)
      super(**kwargs)
      @probe = probe
    end

    def venue_name
      "Ethereal"
    end

    def live_flag_enabled?
      bool_env("AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED") == true
    end

    def live_supported?
      true
    end

    def live_enabled?
      live_flag_enabled?
    end

    def mode
      live_enabled? ? "live_gated" : "read_only_dry_run"
    end

    def live_confirmation_phrase
      env["AERODROME_ETHEREAL_HEDGE_CONFIRMATION"].to_s
    end

    def read_position(symbol:)
      return nil if config_blockers.any?

      snapshot = probe.get_position(normalize_symbol(symbol))
      return nil if snapshot.is_a?(Hash) && snapshot[:status] == "unsupported"

      normalize_position(snapshot)
    rescue => e
      @warnings = warnings + [ "Ethereal position readback unavailable: #{e.class}: #{e.message}" ]
      nil
    end

    def account_state
      return super if config_blockers.any?

      health = normalize_account_state(probe.account_health)
      position = read_position(symbol: "ETH")
      open_orders = ethereal_open_orders_state
      health.merge(
        raw_positions_count: position ? 1 : 0,
        normalized_positions_count: position ? 1 : 0,
        hedge_positions_count: position ? 1 : 0,
        current_short_eth: position&.dig(:short_size),
        current_side: position&.dig(:side),
        open_orders_read_attempted: open_orders[:open_orders_read_attempted],
        open_orders_read_status: open_orders[:open_orders_read_status],
        open_orders_count: open_orders[:open_orders_count],
        open_orders_diagnostics: open_orders[:open_orders_diagnostics],
        margin_mode: "cross",
        effective_leverage: position&.dig(:effective_leverage),
        warnings: (Array(health[:warnings]) + Array(position&.dig(:warnings))).uniq
      ).reject { |_key, value| value.nil? }
    rescue => e
      { venue: venue_name, mode: mode, status: "unavailable", blockers: blockers, warnings: warnings + [ e.message ] }
    end

    def blockers
      live = []
      live << "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED must be true for Ethereal live submit." unless live_enabled?
      live + config_blockers
    end

    def warnings
      @warnings ||= [
        "Ethereal uses cross margin only. Effective leverage is estimated from position notional / account collateral.",
        "Ethereal live submit remains gated by explicit env and typed confirmation."
      ]
    end

    def round_order_size(value)
      lot = ethereal_lot_size
      return super unless lot&.positive?

      (BigDecimal(value.to_s) / lot).floor * lot
    end

    private

    def payload(action:, symbol:, size_eth:, max_slippage:, reduce_only:)
      side = reduce_only ? "buy" : "sell"
      rounded = round_order_size(size_eth)
      super.merge(
        schema: "ethereal_eip712_trade_order",
        endpoint: "POST /v1/order",
        body_shape: "ethereal_submit_order",
        market_symbol: exchange_symbol(symbol),
        margin_mode: "cross",
        side: side,
        reduce_only: reduce_only,
        order_type: "LIMIT_IOC",
        quantity: decimal_string(rounded),
        signature: nil,
        typed_data_available: ethereal_submit_configured?,
        isolated: false
      )
    end

    def config_blockers
      blockers = []
      blockers << "ETHEREAL_READ_ONLY_ENABLED is not true" unless bool_env("ETHEREAL_READ_ONLY_ENABLED")
      blockers << "ETHEREAL_API_BASE_URL is required for Ethereal read-only account/position checks" if env["ETHEREAL_API_BASE_URL"].blank?
      blockers << "ETHEREAL_SUBACCOUNT_ID is required for Ethereal position readback" if env["ETHEREAL_SUBACCOUNT_ID"].blank?
      blockers
    end

    def ethereal_submit_configured?
      env["ETHEREAL_LINKED_SIGNER_ADDRESS"].present? && env["ETHEREAL_SUBACCOUNT_ID"].present?
    end

    def probe
      @probe ||= HedgeBackends::EtherealReadOnlyProbe.new(env: env)
    end

    def normalize_position(snapshot)
      source = snapshot.respond_to?(:to_h) ? snapshot.to_h : snapshot.as_json
      source = source.to_h.with_indifferent_access
      raw_size = raw_position_size(source)
      signed_size = raw_size || decimal_or_nil(source[:signed_size])
      short_size = decimal_or_nil(source[:short_size])
      signed_size ||= short_size&.positive? ? -short_size : BigDecimal("0")
      return nil if signed_size.zero?

      notional = decimal_or_nil(source[:position_value])
      account = normalize_account_state(probe.account_health)
      account_value = decimal_or_nil(account[:account_value_usd]) || decimal_or_nil(account[:collateral_usd])
      effective = notional && account_value&.positive? ? notional.abs / account_value : nil
      side = signed_size.negative? ? "short" : "long"
      position_warnings = raw_side_size_warnings(source, signed_size)
      {
        venue: venue_name,
        symbol: "ETH-PERP",
        market_symbol: exchange_symbol(source[:market] || "ETH"),
        side: side,
        size: signed_size.to_s("F"),
        short_size: side == "short" ? signed_size.abs.to_s("F") : "0",
        margin_mode: "cross",
        entry_price: decimal_string_or_value(source[:entry_price]),
        mark_price: decimal_string_or_value(source[:mark_price]),
        notional_usd: decimal_string_or_value(notional),
        unrealized_pnl_usd: decimal_string_or_value(source[:unrealized_pnl]),
        account_value_usd: account[:account_value_usd],
        collateral_usd: account[:account_value_usd],
        withdrawable_usd: account[:withdrawable_usd],
        effective_leverage: effective&.to_s("F"),
        raw: source[:raw],
        status: source[:status],
        warnings: position_warnings.presence
      }.compact
    end

    def normalize_account_state(value)
      source = if value.respond_to?(:to_h)
        value.to_h
      elsif value.respond_to?(:as_json)
        value.as_json
      else
        {}
      end
      source = source.to_h.with_indifferent_access

      state = {
        venue: venue_name,
        mode: mode,
        live_mode_state: live_mode_state,
        live_supported: live_supported?,
        live_enabled: live_enabled?,
        status: source[:status],
        backend: source[:backend],
        collateral: source[:collateral],
        account_value_usd: decimal_string_or_value(source[:account_value_usd]),
        collateral_usd: decimal_string_or_value(source[:account_value_usd]),
        withdrawable_usd: decimal_string_or_value(source[:withdrawable_usd]),
        margin_used_usd: decimal_string_or_value(source[:margin_used_usd]),
        blockers: blockers,
        warnings: warnings
      }
      state = state.reject { |_key, value| value.nil? }
      state[:live_enabled] = live_enabled?
      state
    end

    def ethereal_open_orders_state
      result = probe.open_orders("ETH")
      if result.is_a?(Hash) && result[:status].to_s == "ok"
        return {
          open_orders_read_attempted: true,
          open_orders_read_status: "ok",
          open_orders_count: result[:open_orders_count].to_i,
          open_orders_diagnostics: {
            endpoint: "GET /v1/order",
            query: "subaccountId, productIds, isWorking=true, limit=100",
            product_id: result[:product_id],
            subaccount_configured: result[:subaccount].present?
          }
        }
      end

      {
        open_orders_read_attempted: true,
        open_orders_read_status: "unavailable",
        open_orders_count: nil,
        open_orders_diagnostics: {
          endpoint: "GET /v1/order",
          status: result.respond_to?(:[]) ? result[:status] : "unavailable",
          message: result.respond_to?(:[]) ? result[:message] : "Ethereal open orders readback unavailable"
        }.compact
      }
    rescue => e
      {
        open_orders_read_attempted: true,
        open_orders_read_status: "unavailable",
        open_orders_count: nil,
        open_orders_diagnostics: {
          endpoint: "GET /v1/order",
          error_class: e.class.name,
          message: e.message
        }
      }
    end

    def decimal_string_or_value(value)
      value.is_a?(BigDecimal) ? value.to_s("F") : value
    end

    def raw_position_size(source)
      raw = source[:raw]
      return nil unless raw.respond_to?(:[])

      decimal_or_nil(raw[:size] || raw["size"])
    end

    def raw_side_size_warnings(source, signed_size)
      raw = source[:raw]
      return [] unless raw.respond_to?(:[])

      raw_side = raw[:side] || raw["side"]
      side_direction = raw_side_direction(raw_side)
      size_direction = signed_size.negative? ? "short" : "long"
      return [] unless side_direction && side_direction != size_direction

      [ "Ethereal raw side=#{raw_side.inspect} disagrees with signed size #{signed_size.to_s('F')}; using signed size as source of truth." ]
    end

    def raw_side_direction(value)
      return nil if value.nil?

      text = value.to_s.downcase
      return "short" if text.in?(%w[1 short sell])
      return "long" if text.in?(%w[0 long buy])

      nil
    end

    def decimal_or_nil(value)
      return value if value.is_a?(BigDecimal)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError
      nil
    end

    def normalize_symbol(symbol)
      symbol.to_s.upcase == "WETH" ? "ETH" : symbol
    end

    def exchange_symbol(symbol)
      text = symbol.to_s.upcase
      return "ETHUSD" if text.in?(%w[ETH WETH ETH-PERP ETH-USD])

      env.fetch("ETHEREAL_MARKET_SYMBOL", "ETH-USD").delete("-").upcase
    end

    def ethereal_lot_size
      @ethereal_lot_size ||= begin
        value = env["ETHEREAL_LOT_SIZE"].presence || probe.market_metadata.lot_size
        value.present? ? BigDecimal(value.to_s) : BigDecimal("0.0001")
      rescue
        BigDecimal("0.0001")
      end
    end
  end
end
