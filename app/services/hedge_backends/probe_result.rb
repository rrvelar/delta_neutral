module HedgeBackends
  class ProbeResult
    SAFETY_BANNER = "ETHEREAL READ-ONLY PROBE - NO ORDERS".freeze

    attr_reader :backend, :config, :market_metadata, :mark_price, :position,
      :account_health, :endpoint_results, :unsupported, :unknown, :errors,
      :warnings, :sources_checked

    def initialize(
      backend:, config:, market_metadata: nil, mark_price: nil, position: nil,
      account_health: nil, endpoint_results: [], unsupported: [], unknown: [],
      errors: [], warnings: [], sources_checked: [], status: nil
    )
      @backend = backend
      @config = config
      @market_metadata = market_metadata
      @mark_price = mark_price
      @position = position
      @account_health = account_health
      @endpoint_results = endpoint_results
      @unsupported = unsupported
      @unknown = unknown
      @errors = errors
      @warnings = warnings
      @sources_checked = sources_checked
      @status = status
    end

    def status
      return @status if @status
      return "BLOCKED" if errors.any?
      return "WARN" if warnings.any? || unsupported.any? || unknown.any?

      "PASS"
    end

    def to_h
      {
        safety_banner: SAFETY_BANNER,
        backend: backend,
        read_only: true,
        orders_enabled: false,
        close_enabled: false,
        hyperliquid_execution: false,
        production_wiring: false,
        config: config,
        market_metadata: serializable(market_metadata),
        mark_price: serializable(mark_price),
        position: serializable(position),
        account_health: serializable(account_health),
        endpoint_results: serializable(endpoint_results),
        unsupported: unsupported,
        unknown: unknown,
        errors: errors,
        warnings: warnings,
        sources_checked: sources_checked,
        status: status
      }
    end

    def as_json(*)
      to_h
    end

    private

    def serializable(value)
      case value
      when BigDecimal
        value.to_s("F")
      when Array
        value.map { |item| serializable(item) }
      when Hash
        value.transform_values { |item| serializable(item) }
      else
        return value.as_json if value.respond_to?(:as_json)

        value
      end
    end
  end
end
