namespace :aerodrome do
  desc "Run a read-only Aerodrome Slipstream position dry-run"
  task dry_run: :environment do
    normalized = AerodromeSlipstreamDryRun.normalize_token_ids(ENV["TOKEN_IDS"].presence || ENV["AERODROME_SLIPSTREAM_TOKEN_IDS"].presence)
    token_ids = normalized.fetch(:token_ids)

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
      puts "NO DB WRITES"
      puts "NO HYPERLIQUID"
      puts "NO HEDGES"
      puts "HEDGE PREVIEW ONLY"
      puts "NO ORDERS"
      puts "EXECUTION DISABLED"
      puts(report.fetch(:amount_math_deferred) ? "AMOUNT MATH DEFERRED" : "AMOUNT MATH VERIFIED")
      report.fetch(:notes).each { |note| puts "Note: #{note}" }
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
          puts "  amount0_decimal: #{result.fetch(:amount0_decimal).inspect}"
          puts "  amount1_decimal: #{result.fetch(:amount1_decimal).inspect}"
          puts "  math_source: #{result.fetch(:math_source).inspect}"
          puts "  verification_status: #{result.fetch(:verification_status)}"
          puts "  partial_data_reason: #{result.fetch(:partial_data_reason)}"
          puts "  token0_price_usd: #{result.fetch(:token0_price_usd).inspect}"
          puts "  token1_price_usd: #{result.fetch(:token1_price_usd).inspect}"
          puts "  total_value_usd: #{result.fetch(:total_value_usd).inspect}"
          puts "  valuation_status: #{result.fetch(:valuation_status)}"
          puts "  valuation_source: #{result.fetch(:valuation_source).inspect}"
          puts "  valuation_reason: #{result.fetch(:valuation_reason).inspect}"
          puts "  hedge_preview_supported: #{result.fetch(:hedge_preview_supported)}"
          puts "  hedge_preview_reason: #{result.fetch(:hedge_preview_reason).inspect}"
          puts "  hedge_asset: #{result.fetch(:hedge_asset).inspect}"
          puts "  hedge_side: #{result.fetch(:hedge_side).inspect}"
          puts "  suggested_short_amount: #{result.fetch(:suggested_short_amount).inspect}"
          puts "  suggested_short_notional_usd: #{result.fetch(:suggested_short_notional_usd).inspect}"
          puts "  lp_weth_amount: #{result.fetch(:lp_weth_amount).inspect}"
          puts "  lp_usdc_amount: #{result.fetch(:lp_usdc_amount).inspect}"
          puts "  lp_total_value_usd: #{result.fetch(:lp_total_value_usd).inspect}"
          puts "  weth_price_usd: #{result.fetch(:weth_price_usd).inspect}"
          puts "  hedge_preview_source: #{result.fetch(:hedge_preview_source).inspect}"
          puts "  hedge_preview_verification_status: #{result.fetch(:hedge_preview_verification_status)}"
          puts "  execution_enabled: #{result.fetch(:execution_enabled)}"
          puts "  hyperliquid_called: #{result.fetch(:hyperliquid_called)}"
          puts "  database_write: #{result.fetch(:database_write)}"
          puts "  hedge_enabled: #{result.fetch(:hedge_enabled)}"
        end
        puts
      end
    end

    exit(false) if report.fetch(:results).any? { |result| result.fetch(:status) == "error" }
  end

  desc "Verify read-only Aerodrome Slipstream configuration"
  task verify_config: :environment do
    report = AerodromeSlipstreamDryRun::ConfigVerification.new(
      check_rpc: ENV["CHECK_RPC"].to_s.downcase == "true"
    ).report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "Config status: #{report.fetch(:status)}"
      puts "Database write: #{report.fetch(:database_write)}"
      puts "Hedge enabled: #{report.fetch(:hedge_enabled)}"
      puts "CHECK_RPC: #{report.fetch(:check_rpc)}"
      puts "BASE_RPC_URL present: #{report.dig(:config, :base_rpc_url_present)}"
      puts "Position manager: #{report.dig(:config, :position_manager_address)}"
      puts "Factory: #{report.dig(:config, :factory_address)}"
      puts "NO DB WRITES"
      puts "NO HYPERLIQUID"
      puts "NO HEDGES"

      if report.fetch(:rpc_checks).any?
        puts
        puts "RPC checks:"
        report.fetch(:rpc_checks).each do |check|
          if check.fetch(:status) == "ok"
            puts "  #{check.fetch(:method)} #{check[:target]}: #{check.fetch(:result)}"
          else
            puts "  #{check.fetch(:method)} #{check[:target]}: #{check.fetch(:error_class)} - #{check.fetch(:error_message)}"
          end
        end
      end

      if report.fetch(:errors).any?
        puts
        puts "Errors:"
        report.fetch(:errors).each { |error| puts "  #{error}" }
      end
    end

    exit(false) if report.fetch(:status) == "error"
  end

  desc "Run a read-only Aerodrome pre-live readiness check"
  task pre_live_check: :environment do
    report = AerodromePreLiveCheck.new(
      check_hyperliquid: ENV["CHECK_HYPERLIQUID"].to_s.downcase == "true"
    ).report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts

      report.fetch(:checks).each do |section, checks|
        puts section.to_s.tr("_", " ")
        checks.each do |check|
          value = check[:value] ? " (#{check[:value]})" : ""
          puts "  #{check.fetch(:status).upcase}: #{check.fetch(:name)}#{value}"
        end
        puts
      end

      puts "Blockers:"
      if report.fetch(:blockers).any?
        report.fetch(:blockers).each { |blocker| puts "  #{blocker}" }
      else
        puts "  none"
      end

      puts "Warnings:"
      if report.fetch(:warnings).any?
        report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      else
        puts "  none"
      end

      puts "Next steps:"
      report.fetch(:next_steps).each { |step| puts "  #{step}" }
    end

    exit(false) if report.fetch(:status) == "BLOCKED"
  end

  desc "Run testnet-only emergency close for Aerodrome ETH short"
  task testnet_emergency_close: :environment do
    report = AerodromeTestnetEmergencyClose.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "HYPERLIQUID_TESTNET=#{report.fetch(:hyperliquid_testnet)}"
      puts "live_approved=#{report.fetch(:live_approved)}"
      puts "current ETH position before: #{report.fetch(:before_position).inspect}"
      puts "attempts:"
      report.fetch(:attempts).each { |attempt| puts "  #{attempt.inspect}" }
      puts "current ETH position after: #{report.fetch(:after_position).inspect}"
      puts "final status: #{report.fetch(:status)}"
      if report.fetch(:errors).any?
        puts "errors:"
        report.fetch(:errors).each { |error| puts "  #{error}" }
      end
    end

    exit(false) if report.fetch(:status) == "failed"
  end

  desc "Run a read-only Aerodrome first-live preflight check"
  task live_preflight_check: :environment do
    report = AerodromeLivePreflightCheck.new(
      check_hyperliquid: ENV["CHECK_HYPERLIQUID"].to_s.downcase == "true"
    ).report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts

      report.fetch(:checks).each do |section, checks|
        puts section.to_s.tr("_", " ")
        checks.each do |check|
          value = check[:value] ? " (#{check[:value]})" : ""
          puts "  #{check.fetch(:status).upcase}: #{check.fetch(:name)}#{value}"
        end
        puts
      end

      puts "Blockers:"
      if report.fetch(:blockers).any?
        report.fetch(:blockers).each { |blocker| puts "  #{blocker}" }
      else
        puts "  none"
      end

      puts "Warnings:"
      if report.fetch(:warnings).any?
        report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      else
        puts "  none"
      end

      puts "Next steps:"
      report.fetch(:next_steps).each { |step| puts "  #{step}" }
    end

    exit(false) if report.fetch(:status) == "BLOCKED"
  end
end
