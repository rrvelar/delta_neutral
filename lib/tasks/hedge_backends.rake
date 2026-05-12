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
end

def status_for(result)
  return "not_run" if result.nil?

  result[:status] || result["status"] || "unknown"
end
