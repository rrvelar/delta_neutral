require "securerandom"

module HedgeBackends
  class EtherealObservationRecorder
    SENSITIVE_KEY_PATTERN = /private_key|secret|signature|password|token|api_key|authorization|bearer|cookie/i
    DEFAULT_ROOT = Rails.root.join("storage", "hedge_backends", "ethereal_observations")

    def initialize(root: DEFAULT_ROOT, clock: -> { Time.current }, id_generator: -> { SecureRandom.hex(4) })
      @root = Pathname(root)
      @clock = clock
      @id_generator = id_generator
    end

    def record(probe_result, env: ENV)
      observation = observation_for(probe_result, env: env)
      FileUtils.mkdir_p(@root)
      path = @root.join("#{timestamp}-#{@id_generator.call}.json")
      File.write(path, JSON.pretty_generate(observation))
      path
    end

    def sanitize(value)
      case value
      when BigDecimal
        value.to_s("F")
      when Array
        value.map { |item| sanitize(item) }
      when Hash
        value.each_with_object({}) do |(key, item), sanitized|
          next if sensitive_key?(key)

          sanitized[key] = sanitize(item)
        end
      else
        value
      end
    end

    private

    def observation_for(probe_result, env:)
      result_hash = probe_result.respond_to?(:to_h) ? probe_result.to_h : probe_result
      sanitized = sanitize(result_hash)

      {
        metadata: metadata_for(sanitized, env: env),
        probe_result: sanitized
      }
    end

    def metadata_for(result, env:)
      config = result.fetch(:config, {})
      api_base = config[:api_base_url] || config["api_base_url"] || env["ETHEREAL_API_BASE_URL"]
      {
        backend: "ethereal",
        generated_at: @clock.call.iso8601,
        market_symbol: config[:market_symbol] || config["market_symbol"] || env.fetch("ETHEREAL_MARKET_SYMBOL", EtherealReadOnlyProbe::DEFAULT_MARKET),
        api_base_host: api_base_host(api_base),
        account_id_present: present?(env["ETHEREAL_ACCOUNT_ID"]) || config[:account_id_configured] == true || config["account_id_configured"] == true,
        subaccount_id_present: present?(env["ETHEREAL_SUBACCOUNT_ID"]) || config[:subaccount_id_configured] == true || config["subaccount_id_configured"] == true,
        read_only: true,
        orders_enabled: false,
        close_enabled: false,
        signing_enabled: false,
        hyperliquid_execution: false,
        production_wiring: false
      }
    end

    def timestamp
      @clock.call.strftime("%Y%m%d%H%M%S")
    end

    def api_base_host(api_base)
      return nil unless present?(api_base)

      URI.parse(api_base.to_s).host
    rescue URI::InvalidURIError
      nil
    end

    def present?(value)
      value.respond_to?(:present?) ? value.present? : !value.nil? && value != ""
    end

    def sensitive_key?(key)
      key.to_s.match?(SENSITIVE_KEY_PATTERN)
    end
  end
end
