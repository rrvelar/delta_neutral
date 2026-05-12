module HedgeBackends
  class EtherealObservationSummary
    def initialize(path:)
      @path = Pathname(path.to_s)
    end

    def report
      return error_report("PATH is required") if @path.to_s.blank?
      return error_report("observation file does not exist: #{@path}") unless @path.file?

      observation = JSON.parse(@path.read)
      probe = observation.fetch("probe_result", observation)
      endpoint_results = Array(probe["endpoint_results"])
      statuses = endpoint_results.group_by { |endpoint| endpoint.fetch("status", "unknown") }

      {
        safety_banner: "ETHEREAL OBSERVATION SUMMARY - READ ONLY",
        status: summary_status(probe),
        read_only: true,
        orders_enabled: false,
        close_enabled: false,
        signing_enabled: false,
        hyperliquid_execution: false,
        production_wiring: false,
        path: @path.to_s,
        endpoints_ok: endpoint_names(statuses["ok"]),
        endpoints_unsupported_unknown_error: endpoint_names(statuses.values_at("unsupported", "unknown", "error").flatten.compact),
        endpoint_results: endpoint_results,
        market_metadata_complete: market_metadata_complete?(probe),
        mark_price_present: mark_price_present?(probe),
        position_readback_proven: result_ok?(probe["position"]),
        account_health_proven: result_ok?(probe["account_health"]),
        market_metadata_ready: market_metadata_complete?(probe),
        mark_price_ready: mark_price_present?(probe),
        position_readback_ready: result_ok?(probe["position"]),
        account_health_ready: result_ok?(probe["account_health"]),
        fills_ready: false,
        order_status_ready: false,
        reduce_only_close_ready: false,
        final_zero_readback_ready: false,
        ready_for_read_only_observation: ready_for_read_only_observation?(probe),
        ready_for_sandbox_order_proof: false,
        ready_for_live_adapter: false,
        live_adapter_allowed: false,
        missing_before_sandbox_order_proof: missing_before_sandbox_order_proof(probe),
        warnings: Array(probe["warnings"]),
        errors: Array(probe["errors"])
      }
    rescue JSON::ParserError => e
      error_report("invalid JSON: #{e.message}")
    rescue KeyError => e
      error_report("invalid observation shape: missing #{e.key}")
    end

    private

    def error_report(message)
      {
        safety_banner: "ETHEREAL OBSERVATION SUMMARY - READ ONLY",
        status: "BLOCKED",
        read_only: true,
        orders_enabled: false,
        close_enabled: false,
        signing_enabled: false,
        hyperliquid_execution: false,
        production_wiring: false,
        path: @path.to_s,
        endpoints_ok: [],
        endpoints_unsupported_unknown_error: [],
        market_metadata_complete: false,
        mark_price_present: false,
        position_readback_proven: false,
        account_health_proven: false,
        market_metadata_ready: false,
        mark_price_ready: false,
        position_readback_ready: false,
        account_health_ready: false,
        fills_ready: false,
        order_status_ready: false,
        reduce_only_close_ready: false,
        final_zero_readback_ready: false,
        ready_for_read_only_observation: false,
        ready_for_sandbox_order_proof: false,
        ready_for_live_adapter: false,
        live_adapter_allowed: false,
        missing_before_sandbox_order_proof: [],
        warnings: [],
        errors: [ message ]
      }
    end

    def summary_status(probe)
      return "BLOCKED" if Array(probe["errors"]).any?
      return "WARN" if missing_before_sandbox_order_proof(probe).any?

      "PASS"
    end

    def endpoint_names(results)
      Array(results).map { |result| result["endpoint"] }.compact.uniq
    end

    def market_metadata_complete?(probe)
      metadata = probe["market_metadata"] || {}
      %w[market lot_size tick_size min_order_size max_leverage collateral].all? { |key| metadata[key].present? } &&
        result_ok?(metadata)
    end

    def mark_price_present?(probe)
      mark_price = probe["mark_price"] || {}
      result_ok?(mark_price) && mark_price["mark_price"].present?
    end

    def result_ok?(result)
      result.is_a?(Hash) && result["status"] == "ok"
    end

    def missing_before_sandbox_order_proof(probe)
      missing = []
      missing << "market metadata complete" unless market_metadata_complete?(probe)
      missing << "mark price proven" unless mark_price_present?(probe)
      missing << "position readback proven" unless result_ok?(probe["position"])
      missing << "account health proven" unless result_ok?(probe["account_health"])
      missing << "rate limits understood"
      missing << "auth/read-only key model understood"
      missing << "reduce-only close still not implemented"
      missing << "final zero readback still not proven"
      missing
    end

    def ready_for_read_only_observation?(probe)
      market_metadata_complete?(probe) && mark_price_present?(probe)
    end
  end
end
