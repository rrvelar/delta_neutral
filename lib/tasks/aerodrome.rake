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

  desc "Run strictly gated Aerodrome live emergency ETH close"
  task live_emergency_close: :environment do
    report = AerodromeLiveEmergencyClose.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "LIVE ORDER CAPABLE — REQUIRES MANUAL GATES"
      puts "HYPERLIQUID_TESTNET=#{report.dig(:gates, :hyperliquid_testnet)}"
      puts "live approved=#{report.dig(:gates, :live_approved)}"
      puts "paused=#{report.dig(:gates, :hedge_paused)}"
      puts "confirmation valid=#{report.dig(:gates, :confirmation_valid)}"
      puts "max close ETH=#{report.dig(:gates, :max_close_eth).inspect}"
      puts "ETH position before: #{report.fetch(:before_position).inspect}"
      puts "attempts:"
      report.fetch(:attempts).each { |attempt| puts "  #{attempt.inspect}" }
      puts "ETH position after: #{report.fetch(:after_position).inspect}"
      puts "final status: #{report.fetch(:status)}"
      if report.fetch(:errors).any?
        puts "errors:"
        report.fetch(:errors).each { |error| puts "  #{error}" }
      end
    end

    exit(false) if %w[blocked failed close_unknown].include?(report.fetch(:status))
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

  desc "Acknowledge a reviewed zero-size failed Aerodrome WETH rebalance"
  task acknowledge_failed_rebalance: :environment do
    report = AerodromeFailedRebalanceAcknowledgment.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "status: #{report.fetch(:status)}"
      puts "rebalance id: #{report.fetch(:rebalance_id).inspect}"
      puts "asset: #{report.fetch(:asset).inspect}"
      puts "old short size: #{report.fetch(:old_short_size).inspect}"
      puts "new short size: #{report.fetch(:new_short_size).inspect}"
      puts "acknowledgment marker: #{report.fetch(:acknowledgment_marker)}"
      if report.fetch(:errors).any?
        puts "errors:"
        report.fetch(:errors).each { |error| puts "  #{error}" }
      end
    end

    exit(false) if report.fetch(:status) == "blocked"
  end

  desc "Run a strictly gated one-off Aerodrome live observation window"
  task live_observation_window: :environment do
    report = AerodromeLiveObservationWindow.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "LIVE ORDER CAPABLE — MANUAL GATES REQUIRED"
      puts "duration seconds: #{report.dig(:gates, :duration_seconds).inspect}"
      puts "interval seconds: #{report.dig(:gates, :interval_seconds).inspect}"
      puts "max short ETH: #{report.dig(:gates, :max_short_eth).inspect}"
      puts "max short notional USD: #{report.dig(:gates, :max_short_notional_usd).inspect}"
      puts "log path: #{report.fetch(:log_path).inspect}"
      puts "iteration count: #{report.fetch(:iterations).size}"
      puts "final close status: #{report.dig(:final_close, :status).inspect}"
      final_position = report.fetch(:final_position)
      final_position_display = report.fetch(:final_position_confirmed, true) ? final_position.inspect : "unknown"
      puts "final mainnet ETH position: #{final_position_display}"
      puts "manual action required: #{report.fetch(:manual_action_required, false)}"
      puts "final status: #{report.fetch(:status)}"
      if report.fetch(:errors).any?
        puts "errors:"
        report.fetch(:errors).each { |error| puts "  #{error}" }
      end
    end

    exit(false) if %w[blocked failed].include?(report.fetch(:status))
  end

  desc "Run a read-only Aerodrome production supervised readiness check"
  task production_supervised_readiness: :environment do
    report = AerodromeProductionSupervisedReadiness.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts "git SHA: #{report.fetch(:git_sha).inspect}"
      puts "git SHA source: #{report.fetch(:git_sha_source)}"
      puts "Rails env: #{report.fetch(:rails_env)}"
      puts

      report.fetch(:checks).each do |section, checks|
        puts section.to_s.tr("_", " ")
        checks.each do |check|
          value = check[:value] ? " (#{check[:value]})" : ""
          puts "  #{check.fetch(:status).upcase}: #{check.fetch(:name)}#{value}"
        end
        puts
      end

      puts "Observation summary:"
      summary = report.fetch(:observation_summary)
      puts "  log path: #{summary.fetch(:log_path).inspect}"
      puts "  iterations: #{summary.fetch(:iterations).inspect}"
      puts "  final close status: #{summary.fetch(:final_close_status).inspect}"
      puts "  final position: #{summary.fetch(:final_position).inspect}"
      puts "  manual action required: #{summary.fetch(:manual_action_required).inspect}"

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

  desc "Summarize the latest Aerodrome live observation JSONL log read-only"
  task live_observation_summary: :environment do
    report = AerodromeLiveObservationSummary.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts "log path: #{report.fetch(:log_path).inspect}"
      puts "duration seconds: #{report.fetch(:duration_seconds).inspect}"
      puts "iterations: #{report.fetch(:iterations)}"
      puts "first timestamp: #{report.fetch(:first_timestamp).inspect}"
      puts "last timestamp: #{report.fetch(:last_timestamp).inspect}"
      puts "max observed ETH short: #{report.fetch(:max_observed_eth_short)}"
      puts "rebalances: #{report.fetch(:rebalances_count)}"
      puts "errors count: #{report.fetch(:errors_count)}"
      puts "final close status: #{report.fetch(:final_close_status).inspect}"
      puts "final position: #{report.fetch(:final_position).inspect}"
      puts "manual action required: #{report.fetch(:manual_action_required).inspect}"
    end

    exit(false) if report.fetch(:status) == "BLOCKED"
  end

  desc "Run a read-only Aerodrome watchdog check"
  task watchdog_check: :environment do
    report = AerodromeWatchdogCheck.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "status: #{report.fetch(:status)}"
      puts "critical alerts:"
      if report.fetch(:alerts).any?
        report.fetch(:alerts).each { |alert| puts "  #{alert}" }
      else
        puts "  none"
      end
      puts "warnings:"
      if report.fetch(:warnings).any?
        report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      else
        puts "  none"
      end
      puts "next actions:"
      report.fetch(:next_steps).each { |step| puts "  #{step}" }
    end

    exit(false) if report.fetch(:status) == "BLOCKED"
  end

  desc "Build read-only dry-run Aerodrome watchdog alert messages"
  task watchdog_alerts: :environment do
    report = AerodromeWatchdogAlerts.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "status: #{report.fetch(:status)}"
      puts "severity: #{report.fetch(:severity)}"
      puts "title: #{report.fetch(:title)}"
      puts "summary: #{report.fetch(:summary)}"
      puts "delivery: #{report.dig(:delivery, :mode)}"
      puts "sent: #{report.dig(:delivery, :sent)}"
      puts "recipient: #{report.dig(:delivery, :recipient) || "none"}"
      puts "skipped_reason: #{report.dig(:delivery, :skipped_reason) || "none"}"
      puts "fingerprint: #{report.fetch(:fingerprint)}"
      puts "fingerprint_changed: #{report.fetch(:fingerprint_changed)}"
      puts "cooldown_seconds: #{report.fetch(:cooldown_seconds)}"
      puts "last_sent_at: #{report.fetch(:last_sent_at) || "none"}"
      puts "state_write=#{report.fetch(:state_write)}"
      puts "database_write=#{report.fetch(:database_write)}"
      puts "orders_enabled=#{report.fetch(:orders_enabled)}"
      puts "hyperliquid_execution=#{report.fetch(:hyperliquid_execution)}"
      puts "blockers:"
      if report.fetch(:blockers).any?
        report.fetch(:blockers).each { |blocker| puts "  #{blocker}" }
      else
        puts "  none"
      end
      puts "warnings:"
      if report.fetch(:warnings).any?
        report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      else
        puts "  none"
      end
      puts "recommended actions:"
      report.fetch(:recommended_actions).each { |action| puts "  #{action}" }
    end

    exit(false) if report.fetch(:severity) == "blocked"
  end

  desc "Run a read-only Aerodrome watchdog scheduler readiness check"
  task watchdog_scheduler_check: :environment do
    report = AerodromeWatchdogSchedulerCheck.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "READ ONLY"
      puts "NO ORDERS"
      puts "NO HYPERLIQUID EXECUTION"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "status: #{report.fetch(:status)}"
      puts "blockers:"
      if report.fetch(:blockers).any?
        report.fetch(:blockers).each { |blocker| puts "  #{blocker}" }
      else
        puts "  none"
      end
      puts "warnings:"
      if report.fetch(:warnings).any?
        report.fetch(:warnings).each { |warning| puts "  #{warning}" }
      else
        puts "  none"
      end
      puts "next steps:"
      report.fetch(:next_steps).each { |step| puts "  #{step}" }
    end

    exit(false) if report.fetch(:status) == "BLOCKED"
  end

  desc "Run a strictly gated supervised Aerodrome production canary"
  task production_canary_run: :environment do
    report = AerodromeProductionCanaryRunner.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "LIVE ORDER CAPABLE — SUPERVISED ONLY"
      puts "duration: #{report.dig(:gates, :duration_seconds)}"
      puts "interval: #{report.dig(:gates, :interval_seconds)}"
      puts "max short ETH: #{report.dig(:gates, :max_short_eth)}"
      puts "max short notional USD: #{report.dig(:gates, :max_short_notional_usd)}"
      puts "log path: #{report.fetch(:log_path) || "none"}"
      puts "iterations: #{report.fetch(:iterations)}"
      puts "rebalances count: #{report.fetch(:rebalances_count)}"
      puts "stop reason: #{report.fetch(:stop_reason) || "none"}"
      puts "final close status: #{report.dig(:final_close, :status) || "none"}"
      puts "final mainnet ETH position: #{report.fetch(:final_position).inspect}"
      puts "manual_action_required: #{report.fetch(:manual_action_required)}"
      puts "final status: #{report.fetch(:status)}"
      puts "errors:"
      if report.fetch(:errors).any?
        report.fetch(:errors).each { |error| puts "  #{error}" }
      else
        puts "  none"
      end
    end

    exit(false) unless report.fetch(:status) == "success"
  end

  desc "Run a read-only Aerodrome AERO rewards discovery check"
  task rewards_check: :environment do
    report = AerodromeRewardsCheck.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "NO CLAIMS"
      puts "NO TRANSACTIONS"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts "pool: #{report.fetch(:pool_address).inspect}"
      puts "token id: #{report.fetch(:token_id).inspect}"
      puts "position wallet address: #{report.fetch(:position_wallet_address).inspect}"
      puts "depositor/wallet address used: #{report.fetch(:depositor_address).inspect}"
      puts "depositor source: #{report.fetch(:depositor_source)}"
      puts "gauge status: #{report.fetch(:gauge_status)}"
      puts "gauge address: #{report.fetch(:gauge_address).inspect}"
      puts "staked: #{report.fetch(:staked).inspect}"
      puts "claimable AERO: #{report.fetch(:claimable_aero).inspect}"
      puts "AERO USD price: #{report.fetch(:aero_usd_price).inspect}"
      puts "AERO USD price source: #{report.fetch(:aero_usd_price_source)}"
      puts "claimable AERO USD: #{report.fetch(:claimable_aero_usd).inspect}"

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

  desc "Run a read-only Aerodrome LP fees discovery check"
  task fees_check: :environment do
    report = AerodromeFeesCheck.new.report

    if ENV["FORMAT"].to_s.downcase == "json"
      puts JSON.pretty_generate(report)
    else
      puts report.fetch(:safety_banner)
      puts "NO COLLECT"
      puts "NO TRANSACTIONS"
      puts "DB write: #{report.fetch(:database_write)}"
      puts "Overall status: #{report.fetch(:status)}"
      puts "pool: #{report.fetch(:pool_address).inspect}"
      puts "token id: #{report.fetch(:token_id).inspect}"
      puts "fee source/method: #{report.fetch(:fee_source)}"
      puts "fee0: #{report.fetch(:fee0_amount).inspect} #{report.fetch(:fee0_symbol)}"
      puts "fee0 USD: #{report.fetch(:fee0_usd).inspect}"
      puts "fee1: #{report.fetch(:fee1_amount).inspect} #{report.fetch(:fee1_symbol)}"
      puts "fee1 USD: #{report.fetch(:fee1_usd).inspect}"
      puts "total fees USD: #{report.fetch(:total_fees_usd).inspect}"

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
