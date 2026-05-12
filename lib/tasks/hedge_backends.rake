namespace :hedge_backends do
  desc "Run the Ethereal read-only hedge backend probe"
  task ethereal_probe: :environment do
    report = HedgeBackends::EtherealReadOnlyProbe.new.run_probe.to_h

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO CLOSE"
      puts "NO HYPERLIQUID EXECUTION"
      puts "NO PRODUCTION WIRING"
      puts
      puts "backend: #{report.fetch(:backend)}"
      puts "configured api base URL: #{report.dig(:config, :api_base_url).inspect}"
      puts "market symbol: #{report.dig(:config, :market_symbol)}"
      puts "enabled flag: #{report.dig(:config, :enabled)}"
      puts "market metadata status: #{status_for(report[:market_metadata])}"
      puts "mark price status: #{status_for(report[:mark_price])}"
      puts "position readback status: #{status_for(report[:position])}"
      puts "account health status: #{status_for(report[:account_health])}"

      puts "warnings:"
      Array(report[:warnings]).each { |warning| puts "  #{warning}" }
      puts "  none" if Array(report[:warnings]).empty?

      puts "errors:"
      Array(report[:errors]).each { |error| puts "  #{error.inspect}" }
      puts "  none" if Array(report[:errors]).empty?

      puts "final status: #{report.fetch(:status)}"
    end
  end

  desc "Run and record a sanitized Ethereal read-only probe observation"
  task ethereal_probe_record: :environment do
    report = HedgeBackends::EtherealReadOnlyProbe.new.run_probe.to_h
    path = nil
    warnings = Array(report[:warnings])
    errors = Array(report[:errors])

    if report.fetch(:status) == "BLOCKED"
      warnings << "observation not written because probe status is BLOCKED"
    else
      path = HedgeBackends::EtherealObservationRecorder.new.record(report)
    end

    task_report = {
      safety_banner: report.fetch(:safety_banner),
      status: report.fetch(:status),
      observation_path: path&.to_s,
      probe_result_summary: probe_result_summary(report),
      warnings: warnings,
      errors: errors,
      read_only: true,
      orders_enabled: false,
      close_enabled: false,
      signing_enabled: false,
      hyperliquid_execution: false,
      production_wiring: false
    }

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(task_report)
    else
      puts task_report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO CLOSE"
      puts "NO SIGNING"
      puts "NO HYPERLIQUID EXECUTION"
      puts "NO PRODUCTION WIRING"
      puts "status: #{task_report.fetch(:status)}"
      puts "observation path: #{task_report.fetch(:observation_path).inspect}"
      puts "warnings:"
      task_report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      puts "  none" if task_report.fetch(:warnings).empty?
      puts "errors:"
      task_report.fetch(:errors).each { |error| puts "  #{error.inspect}" }
      puts "  none" if task_report.fetch(:errors).empty?
    end
  end

  desc "Summarize a saved Ethereal read-only probe observation"
  task ethereal_observation_summary: :environment do
    report = HedgeBackends::EtherealObservationSummary.new(path: ENV["PATH"]).report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO CLOSE"
      puts "NO SIGNING"
      puts "NO HYPERLIQUID EXECUTION"
      puts "NO PRODUCTION WIRING"
      puts "status: #{report.fetch(:status)}"
      puts "path: #{report.fetch(:path)}"
      puts "endpoints ok: #{report.fetch(:endpoints_ok).join(', ').presence || 'none'}"
      puts "endpoints unsupported/unknown/error: #{report.fetch(:endpoints_unsupported_unknown_error).join(', ').presence || 'none'}"
      puts "market metadata complete: #{report.fetch(:market_metadata_complete)}"
      puts "mark price present: #{report.fetch(:mark_price_present)}"
      puts "position readback proven: #{report.fetch(:position_readback_proven)}"
      puts "account health proven: #{report.fetch(:account_health_proven)}"
      puts "missing before sandbox order proof:"
      report.fetch(:missing_before_sandbox_order_proof).each { |item| puts "  #{item}" }
      puts "  none" if report.fetch(:missing_before_sandbox_order_proof).empty?
      puts "errors:"
      report.fetch(:errors).each { |error| puts "  #{error}" }
      puts "  none" if report.fetch(:errors).empty?
    end
  end
end

def status_for(result)
  return "not_run" if result.nil?

  result[:status] || result["status"] || "unknown"
end

def probe_result_summary(report)
  {
    backend: report[:backend],
    status: report[:status],
    market_symbol: report.dig(:config, :market_symbol),
    market_metadata_status: status_for(report[:market_metadata]),
    mark_price_status: status_for(report[:mark_price]),
    position_status: status_for(report[:position]),
    account_health_status: status_for(report[:account_health]),
    endpoints_attempted: Array(report[:endpoint_results]).map { |endpoint| endpoint[:endpoint] }.compact
  }
end
