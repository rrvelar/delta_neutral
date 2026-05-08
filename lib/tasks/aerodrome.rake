namespace :aerodrome do
  desc "Run a read-only Aerodrome Slipstream position dry-run"
  task dry_run: :environment do
    token_ids = (ENV["TOKEN_IDS"].presence || ENV["AERODROME_SLIPSTREAM_TOKEN_IDS"].presence).to_s
      .split(",")
      .map(&:strip)
      .compact_blank

    if token_ids.empty?
      warn "Aerodrome dry-run requires explicit token ids. Set TOKEN_IDS=5016 or AERODROME_SLIPSTREAM_TOKEN_IDS=5016."
      exit(false)
    end

    report = AerodromeSlipstreamDryRun.new(token_ids: token_ids).report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "Token count: #{report.fetch(:token_count)}"
      puts "Database write: #{report.fetch(:database_write)}"
      puts "Hedge enabled: #{report.fetch(:hedge_enabled)}"
      puts

      report.fetch(:results).each do |result|
        puts "Token #{result.fetch(:token_id)}: #{result.fetch(:status)}"
        if result.fetch(:status) == "error"
          puts "  error: #{result.fetch(:error_class)} - #{result.fetch(:error_message)}"
        else
          puts "  owner: #{result.fetch(:owner_address)}"
          puts "  manager: #{result.fetch(:position_manager_address)}"
          puts "  factory: #{result.fetch(:factory_address)}"
          puts "  pool: #{result.fetch(:pool_address)}"
          puts "  pair: #{result.fetch(:token0_symbol)} / #{result.fetch(:token1_symbol)}"
          puts "  tokens: #{result.fetch(:token0_address)} / #{result.fetch(:token1_address)}"
          puts "  decimals: #{result.fetch(:token0_decimals)} / #{result.fetch(:token1_decimals)}"
          puts "  ticks: spacing=#{result.fetch(:tick_spacing)}, lower=#{result.fetch(:tick_lower)}, upper=#{result.fetch(:tick_upper)}, current=#{result.fetch(:current_tick)}"
          puts "  liquidity: #{result.fetch(:liquidity)}"
          puts "  sqrt_price_x96: #{result.fetch(:sqrt_price_x96)}"
          puts "  tokens_owed_raw: #{result.fetch(:tokens_owed0_raw)} / #{result.fetch(:tokens_owed1_raw)}"
          puts "  amount0_raw: #{result.fetch(:amount0_raw).inspect}"
          puts "  amount1_raw: #{result.fetch(:amount1_raw).inspect}"
          puts "  partial_data_reason: #{result.fetch(:partial_data_reason)}"
          puts "  database_write: #{result.fetch(:database_write)}"
          puts "  hedge_enabled: #{result.fetch(:hedge_enabled)}"
        end
        puts
      end
    end

    exit(false) if report.fetch(:results).any? { |result| result.fetch(:status) == "error" }
  end
end
