require "test_helper"
require "rake"

class AerodromeTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("aerodrome:dry_run")
    Rake::Task["aerodrome:dry_run"].reenable
    Rake::Task["aerodrome:verify_config"].reenable
    Rake::Task["aerodrome:pre_live_check"].reenable
    Rake::Task["aerodrome:testnet_emergency_close"].reenable
    Rake::Task["aerodrome:live_emergency_close"].reenable
    Rake::Task["aerodrome:live_preflight_check"].reenable
    Rake::Task["aerodrome:acknowledge_failed_rebalance"].reenable
    Rake::Task["aerodrome:live_observation_window"].reenable
    Rake::Task["aerodrome:production_supervised_readiness"].reenable
    Rake::Task["aerodrome:live_observation_summary"].reenable
    Rake::Task["aerodrome:watchdog_check"].reenable
    Rake::Task["aerodrome:watchdog_alerts"].reenable
    Rake::Task["aerodrome:watchdog_scheduler_check"].reenable
    Rake::Task["aerodrome:production_canary_run"].reenable
    Rake::Task["aerodrome:rewards_check"].reenable
    Rake::Task["aerodrome:fees_check"].reenable
  end

  test "dry run task fails clearly with no token ids" do
    with_env("TOKEN_IDS" => nil, "AERODROME_SLIPSTREAM_TOKEN_IDS" => nil) do
      _, err = capture_io do
        exit_error = assert_raises(SystemExit) do
          Rake::Task["aerodrome:dry_run"].invoke
        end
        assert_equal false, exit_error.success?
      end

      assert_match "requires explicit token ids", err
    end
  end

  test "dry run task uses TOKEN_IDS override" do
    captured_token_ids = nil
    fake_report = ok_report("999")

    with_env("TOKEN_IDS" => "999", "AERODROME_SLIPSTREAM_TOKEN_IDS" => "5016", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        captured_token_ids = token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { fake_report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:dry_run"].invoke }

        assert_equal [ "999" ], captured_token_ids
        assert_match AerodromeSlipstreamDryRun::SAFETY_BANNER, out
        assert_match "Token 999: ok", out
      end
    end
  end

  test "dry run task trims spaces and deduplicates token ids" do
    captured_token_ids = nil
    fake_report = ok_report("5016")
    fake_report[:notes] = [ "Duplicate token id 5016 ignored" ]

    with_env("TOKEN_IDS" => " 5016, 5016 , 999 ", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        captured_token_ids = token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { fake_report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:dry_run"].invoke }

        assert_equal [ "5016", "999" ], captured_token_ids
        assert_match "Duplicate token id 5016 ignored", out
      end
    end
  end

  test "dry run task rejects blank token ids" do
    with_env("TOKEN_IDS" => " , , ", "AERODROME_SLIPSTREAM_TOKEN_IDS" => nil) do
      _, err = capture_io do
        exit_error = assert_raises(SystemExit) do
          Rake::Task["aerodrome:dry_run"].invoke
        end
        assert_equal false, exit_error.success?
      end

      assert_match "requires explicit token ids", err
    end
  end

  test "dry run task human output includes safety statements" do
    report = ok_report("5016")

    with_env("TOKEN_IDS" => "5016", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        assert_equal [ "5016" ], token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:dry_run"].invoke }

        assert_match "READ-ONLY", out
        assert_match "NO DB WRITES", out
        assert_match "NO HYPERLIQUID", out
        assert_match "NO HEDGES", out
        assert_match "HEDGE PREVIEW ONLY", out
        assert_match "NO ORDERS", out
        assert_match "EXECUTION DISABLED", out
        assert_match "AMOUNT MATH VERIFIED", out
        assert_no_match(/AMOUNT MATH DEFERRED/, out)
        assert_match "verification_status: verified_math", out
        assert_match "token0_price_usd:", out
        assert_match "token1_price_usd:", out
        assert_match "total_value_usd:", out
        assert_match "valuation_status: supported", out
        assert_match "hedge_preview_supported: true", out
        assert_match "hedge_asset: \"ETH\"", out
        assert_match "execution_enabled: false", out
        assert_match "hyperliquid_called: false", out
      end
    end
  end

  test "dry run task human output warns when amount math is deferred" do
    report = ok_report("5016")
    report[:amount_math_deferred] = true
    report[:results] = [
      report.fetch(:results).first.merge(
        status: "partial",
        amount0_raw: nil,
        amount1_raw: nil,
        amount0_decimal: nil,
        amount1_decimal: nil,
        math_source: nil,
        verification_status: "partial",
        partial_data_reason: "amount0/amount1 math deferred",
        token0_price_usd: nil,
        token1_price_usd: nil,
        total_value_usd: nil,
        valuation_status: "unsupported",
        valuation_source: nil,
        valuation_reason: "amount math unavailable",
        hedge_preview_supported: false,
        hedge_preview_reason: "amount math is not verified",
        hedge_asset: nil,
        hedge_side: nil,
        suggested_short_amount: nil,
        suggested_short_notional_usd: nil,
        lp_weth_amount: nil,
        lp_usdc_amount: nil,
        lp_total_value_usd: nil,
        weth_price_usd: nil,
        hedge_preview_source: nil,
        hedge_preview_verification_status: "unsupported",
        execution_enabled: false,
        hyperliquid_called: false
      )
    ]

    with_env("TOKEN_IDS" => "5016", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        assert_equal [ "5016" ], token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:dry_run"].invoke }

        assert_match "AMOUNT MATH DEFERRED", out
        assert_no_match(/AMOUNT MATH VERIFIED/, out)
        assert_match "Token 5016: partial", out
      end
    end
  end

  test "dry run task supports JSON output" do
    report = ok_report("5016")

    with_env("TOKEN_IDS" => "5016", "FORMAT" => "json") do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        assert_equal [ "5016" ], token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:dry_run"].invoke }
        parsed = JSON.parse(out)

        assert_equal AerodromeSlipstreamDryRun::SAFETY_BANNER, parsed.fetch("safety_banner")
        result = parsed.fetch("results").first
        assert_equal "5016", result.fetch("token_id")
        assert_equal "supported", result.fetch("valuation_status")
        assert_equal "2000.0", result.fetch("token0_price_usd")
        assert_equal true, result.fetch("hedge_preview_supported")
        assert_equal false, result.fetch("execution_enabled")
        assert_equal false, result.fetch("hyperliquid_called")
      end
    end
  end

  test "dry run task reports per-token errors without hiding later tokens" do
    report = ok_report("5016")
    report[:token_count] = 2
    report[:results] = [
      report.fetch(:results).first.merge(token_id: "bad", status: "error", error_class: "AerodromeSlipstreamService::RpcError", error_message: "RPC failed"),
      report.fetch(:results).first
    ]

    with_env("TOKEN_IDS" => "bad,5016", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        assert_equal [ "bad", "5016" ], token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io do
          exit_error = assert_raises(SystemExit) do
            Rake::Task["aerodrome:dry_run"].invoke
          end
          assert_equal false, exit_error.success?
        end

        assert_match "Token bad: error", out
        assert_match "Token 5016: ok", out
      end
    end
  end

  test "dry run task prints missing config errors safely" do
    report = ok_report("5016")
    report[:results] = [
      report.fetch(:results).first.merge(
        status: "error",
        error_class: "AerodromeSlipstreamService::ConfigError",
        error_message: "Missing required Aerodrome config: BASE_RPC_URL"
      )
    ]

    with_env("TOKEN_IDS" => "5016", "FORMAT" => nil) do
      AerodromeSlipstreamDryRun.stub(:new, ->(token_ids:) {
        assert_equal [ "5016" ], token_ids
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io do
          exit_error = assert_raises(SystemExit) do
            Rake::Task["aerodrome:dry_run"].invoke
          end
          assert_equal false, exit_error.success?
        end

        assert_match "Token 5016: error", out
        assert_match "BASE_RPC_URL", out
      end
    end
  end

  test "verify config without CHECK_RPC does not call RPC" do
    with_env(
      "BASE_RPC_URL" => "https://base.example/rpc",
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      "AERODROME_SLIPSTREAM_FACTORY" => "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      "CHECK_RPC" => nil,
      "FORMAT" => nil
    ) do
      out, = capture_io { Rake::Task["aerodrome:verify_config"].invoke }

      assert_match "Config status: ok", out
      assert_match "CHECK_RPC: false", out
      assert_not_requested :post, "https://base.example/rpc"
    end
  end

  test "verify config with CHECK_RPC uses mocked read-only RPC only" do
    stub_request(:post, "https://base.example/rpc")
      .to_return(
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x2105" }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x60016001" }.to_json, headers: { "Content-Type" => "application/json" } },
        { status: 200, body: { jsonrpc: "2.0", id: 1, result: "0x60026002" }.to_json, headers: { "Content-Type" => "application/json" } }
      )

    with_env(
      "BASE_RPC_URL" => "https://base.example/rpc",
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      "AERODROME_SLIPSTREAM_FACTORY" => "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      "CHECK_RPC" => "true",
      "FORMAT" => "json"
    ) do
      out, = capture_io { Rake::Task["aerodrome:verify_config"].invoke }
      parsed = JSON.parse(out)

      assert_equal "ok", parsed.fetch("status")
      assert_equal true, parsed.fetch("check_rpc")
      assert_equal [ "eth_chainId", "eth_getCode", "eth_getCode" ], parsed.fetch("rpc_checks").map { |check| check.fetch("method") }
      assert_requested :post, "https://base.example/rpc", times: 3
    end
  end

  test "rewards check task outputs read-only safety banner" do
    report = rewards_report

    AerodromeRewardsCheck.stub(:new, -> {
      Object.new.tap { |object| object.define_singleton_method(:report) { report } }
    }) do
      out, = capture_io { Rake::Task["aerodrome:rewards_check"].invoke }

      assert_match "AERODROME REWARDS CHECK — READ ONLY", out
      assert_match "NO CLAIMS", out
      assert_match "NO TRANSACTIONS", out
      assert_match "DB write: false", out
      assert_match "position wallet address: \"0x23cb5f48fa3f4502232f3442637f90e8e3355701\"", out
      assert_match "depositor/wallet address used: \"0x23cb5f48fa3f4502232f3442637f90e8e3355701\"", out
      assert_match "depositor source: position_wallet", out
      assert_match "claimable AERO: \"12.5\"", out
      assert_match "AERO USD price: \"0.75\"", out
      assert_match "AERO USD price source: manual", out
      assert_match "claimable AERO USD: \"9.375\"", out
    end
  end

  test "rewards check task supports JSON output" do
    report = rewards_report

    with_env("FORMAT" => "json") do
      AerodromeRewardsCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:rewards_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("transactions_enabled")
        assert_equal false, parsed.fetch("claims_enabled")
        assert_equal "0x23cb5f48fa3f4502232f3442637f90e8e3355701", parsed.fetch("position_wallet_address")
        assert_equal "0x23cb5f48fa3f4502232f3442637f90e8e3355701", parsed.fetch("wallet_address")
        assert_equal "0x23cb5f48fa3f4502232f3442637f90e8e3355701", parsed.fetch("depositor_address")
        assert_equal "position_wallet", parsed.fetch("depositor_source")
        refute_equal parsed.fetch("gauge_address"), parsed.fetch("depositor_address")
        assert_equal true, parsed.fetch("staked")
        assert_equal "12.5", parsed.fetch("claimable_aero")
        assert_equal "0.75", parsed.fetch("aero_usd_price")
        assert_equal "manual", parsed.fetch("aero_usd_price_source")
        assert_equal "9.375", parsed.fetch("claimable_aero_usd")
      end
    end
  end

  test "fees check task outputs read-only safety banner" do
    report = fees_report

    AerodromeFeesCheck.stub(:new, -> {
      Object.new.tap { |object| object.define_singleton_method(:report) { report } }
    }) do
      out, = capture_io { Rake::Task["aerodrome:fees_check"].invoke }

      assert_match "AERODROME FEES CHECK — READ ONLY", out
      assert_match "NO COLLECT", out
      assert_match "NO TRANSACTIONS", out
      assert_match "DB write: false", out
      assert_match "fee source/method: nonfungible_position_manager.positions.tokens_owed", out
      assert_match "fee0: \"0.01\" WETH", out
      assert_match "fee1: \"3.5\" USDC", out
      assert_match "total fees USD: \"23.5\"", out
    end
  end

  test "fees check task supports JSON output" do
    report = fees_report

    with_env("FORMAT" => "json") do
      AerodromeFeesCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:fees_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("transactions_enabled")
        assert_equal false, parsed.fetch("collect_enabled")
        assert_equal "WETH", parsed.fetch("fee0_symbol")
        assert_equal "0.01", parsed.fetch("fee0_amount")
        assert_equal "20.0", parsed.fetch("fee0_usd")
        assert_equal "USDC", parsed.fetch("fee1_symbol")
        assert_equal "3.5", parsed.fetch("fee1_amount")
        assert_equal "23.5", parsed.fetch("total_fees_usd")
      end
    end
  end

  test "verify config invalid manager address fails safely" do
    with_env(
      "BASE_RPC_URL" => "https://base.example/rpc",
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => "bad",
      "AERODROME_SLIPSTREAM_FACTORY" => "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      "CHECK_RPC" => "true",
      "FORMAT" => nil
    ) do
      out, = capture_io do
        exit_error = assert_raises(SystemExit) do
          Rake::Task["aerodrome:verify_config"].invoke
        end
        assert_equal false, exit_error.success?
      end

      assert_match "Invalid AERODROME_SLIPSTREAM_POSITION_MANAGER address", out
      assert_not_requested :post, "https://base.example/rpc"
    end
  end

  test "verify config missing BASE_RPC_URL fails safely for Aerodrome tooling" do
    with_env(
      "BASE_RPC_URL" => nil,
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
      "AERODROME_SLIPSTREAM_FACTORY" => "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
      "CHECK_RPC" => nil,
      "FORMAT" => nil
    ) do
      out, = capture_io do
        exit_error = assert_raises(SystemExit) do
          Rake::Task["aerodrome:verify_config"].invoke
        end
        assert_equal false, exit_error.success?
      end

      assert_match "Missing BASE_RPC_URL", out
    end
  end

  test "pre live check task outputs read-only safety banner" do
    report = pre_live_report(status: "WARN", warnings: [ "review warning" ])

    with_env("FORMAT" => nil, "CHECK_HYPERLIQUID" => nil) do
      AerodromePreLiveCheck.stub(:new, ->(check_hyperliquid:) {
        assert_equal false, check_hyperliquid
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:pre_live_check"].invoke }

        assert_match "PRE-LIVE READINESS CHECK", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "DB write: false", out
        assert_match "Overall status: WARN", out
        assert_match "Blockers:", out
        assert_match "Warnings:", out
        assert_match "Next steps:", out
      end
    end
  end

  test "pre live check task supports JSON output" do
    report = pre_live_report(status: "PASS")

    with_env("FORMAT" => "json", "CHECK_HYPERLIQUID" => "true") do
      AerodromePreLiveCheck.stub(:new, ->(check_hyperliquid:) {
        assert_equal true, check_hyperliquid
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:pre_live_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "pre live check task exits false when blocked" do
    report = pre_live_report(status: "BLOCKED", blockers: [ "missing env" ])

    with_env("FORMAT" => nil) do
      AerodromePreLiveCheck.stub(:new, ->(check_hyperliquid:) {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        assert_raises(SystemExit) do
          capture_io { Rake::Task["aerodrome:pre_live_check"].invoke }
        end
      end
    end
  end

  test "testnet emergency close task outputs status" do
    report = emergency_close_report(status: "success")

    with_env("FORMAT" => nil) do
      AerodromeTestnetEmergencyClose.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:testnet_emergency_close"].invoke }

        assert_match "TESTNET EMERGENCY CLOSE", out
        assert_match "HYPERLIQUID_TESTNET=true", out
        assert_match "live_approved=false", out
        assert_match "current ETH position before", out
        assert_match "attempts", out
        assert_match "current ETH position after", out
        assert_match "final status: success", out
      end
    end
  end

  test "testnet emergency close task supports JSON output" do
    report = emergency_close_report(status: "noop")

    with_env("FORMAT" => "json") do
      AerodromeTestnetEmergencyClose.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:testnet_emergency_close"].invoke }
        parsed = JSON.parse(out)

        assert_equal "noop", parsed.fetch("status")
        assert_equal [], parsed.fetch("attempts")
        assert_equal [], parsed.fetch("errors")
      end
    end
  end

  test "live emergency close task outputs gated live safety banner" do
    report = live_emergency_close_report(status: "success")

    with_env("FORMAT" => nil) do
      AerodromeLiveEmergencyClose.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_emergency_close"].invoke }

        assert_match "AERODROME LIVE EMERGENCY CLOSE", out
        assert_match "LIVE ORDER CAPABLE", out
        assert_match "HYPERLIQUID_TESTNET=false", out
        assert_match "live approved=true", out
        assert_match "paused=true", out
        assert_match "confirmation valid=true", out
        assert_match "max close ETH=\"0.5\"", out
        assert_match "ETH position before", out
        assert_match "ETH position after", out
        assert_match "final status: success", out
      end
    end
  end

  test "live emergency close task supports JSON output" do
    report = live_emergency_close_report(status: "noop")

    with_env("FORMAT" => "json") do
      AerodromeLiveEmergencyClose.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_emergency_close"].invoke }
        parsed = JSON.parse(out)

        assert_equal "noop", parsed.fetch("status")
        assert_equal true, parsed.fetch("live_order_capable")
        assert_equal "ETH", parsed.fetch("touched_asset")
      end
    end
  end

  test "live emergency close task exits false when blocked" do
    report = live_emergency_close_report(status: "blocked", errors: [ "blocked gate" ])

    with_env("FORMAT" => nil) do
      AerodromeLiveEmergencyClose.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        assert_raises(SystemExit) do
          capture_io { Rake::Task["aerodrome:live_emergency_close"].invoke }
        end
      end
    end
  end

  test "live preflight check task outputs read-only safety banner" do
    report = live_preflight_report(status: "WARN", warnings: [ "review warning" ])

    with_env("FORMAT" => nil, "CHECK_HYPERLIQUID" => nil) do
      AerodromeLivePreflightCheck.stub(:new, ->(check_hyperliquid:) {
        assert_equal false, check_hyperliquid
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_preflight_check"].invoke }

        assert_match "AERODROME LIVE PREFLIGHT", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "DB write: false", out
        assert_match "Overall status: WARN", out
        assert_match "Blockers:", out
        assert_match "Warnings:", out
        assert_match "Next steps:", out
      end
    end
  end

  test "live preflight check task supports JSON output" do
    report = live_preflight_report(status: "PASS")

    with_env("FORMAT" => "json", "CHECK_HYPERLIQUID" => "true") do
      AerodromeLivePreflightCheck.stub(:new, ->(check_hyperliquid:) {
        assert_equal true, check_hyperliquid
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_preflight_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "acknowledge failed rebalance task outputs safety details" do
    report = acknowledge_failed_rebalance_report(status: "success")

    with_env("FORMAT" => nil) do
      AerodromeFailedRebalanceAcknowledgment.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:acknowledge_failed_rebalance"].invoke }

        assert_match "AERODROME FAILED REBALANCE ACKNOWLEDGMENT", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "DB write: true", out
        assert_match "status: success", out
        assert_match AerodromeFailedRebalanceAcknowledgment::MARKER, out
      end
    end
  end

  test "acknowledge failed rebalance task supports JSON output" do
    report = acknowledge_failed_rebalance_report(status: "success")

    with_env("FORMAT" => "json") do
      AerodromeFailedRebalanceAcknowledgment.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:acknowledge_failed_rebalance"].invoke }
        parsed = JSON.parse(out)

        assert_equal "success", parsed.fetch("status")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
        assert_equal AerodromeFailedRebalanceAcknowledgment::MARKER, parsed.fetch("acknowledgment_marker")
      end
    end
  end

  test "acknowledge failed rebalance task exits false when blocked" do
    report = acknowledge_failed_rebalance_report(status: "blocked", errors: [ "missing id" ])

    with_env("FORMAT" => nil) do
      AerodromeFailedRebalanceAcknowledgment.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        assert_raises(SystemExit) do
          capture_io { Rake::Task["aerodrome:acknowledge_failed_rebalance"].invoke }
        end
      end
    end
  end

  test "live observation window task outputs gated live safety banner" do
    report = live_observation_report(status: "success")

    with_env("FORMAT" => nil) do
      AerodromeLiveObservationWindow.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_observation_window"].invoke }

        assert_match "AERODROME LIVE OBSERVATION WINDOW", out
        assert_match "LIVE ORDER CAPABLE", out
        assert_match "duration seconds: 60", out
        assert_match "interval seconds: 60", out
        assert_match "max short ETH: \"0.02\"", out
        assert_match "log path:", out
        assert_match "iteration count: 1", out
        assert_match "final close status: \"success\"", out
        assert_match "manual action required: false", out
        assert_match "final status: success", out
      end
    end
  end

  test "live observation window task supports JSON output" do
    report = live_observation_report(status: "success")

    with_env("FORMAT" => "json") do
      AerodromeLiveObservationWindow.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_observation_window"].invoke }
        parsed = JSON.parse(out)

        assert_equal "success", parsed.fetch("status")
        assert_equal true, parsed.fetch("live_order_capable")
        assert_equal "/tmp/aerodrome-live-observation.jsonl", parsed.fetch("log_path")
        assert_equal 1, parsed.fetch("iterations").size
        assert_equal "success", parsed.fetch("final_close").fetch("status")
      end
    end
  end

  test "production supervised readiness task outputs read-only report" do
    report = production_readiness_report(status: "WARN")

    with_env("FORMAT" => nil) do
      AerodromeProductionSupervisedReadiness.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:production_supervised_readiness"].invoke }

        assert_match "AERODROME PRODUCTION SUPERVISED READINESS", out
        assert_match "READ ONLY", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "Overall status: WARN", out
        assert_match "git SHA source: env", out
        assert_match "Observation summary:", out
      end
    end
  end

  test "production supervised readiness task supports JSON output" do
    report = production_readiness_report(status: "PASS")

    with_env("FORMAT" => "json") do
      AerodromeProductionSupervisedReadiness.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:production_supervised_readiness"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "live observation summary task outputs read-only report" do
    report = observation_summary_report(status: "PASS")

    with_env("FORMAT" => nil) do
      AerodromeLiveObservationSummary.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:live_observation_summary"].invoke }

        assert_match "AERODROME LIVE OBSERVATION SUMMARY", out
        assert_match "READ ONLY", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "final close status: \"success\"", out
      end
    end
  end

  test "watchdog check task outputs read-only report" do
    report = watchdog_report(status: "WARN")

    with_env("FORMAT" => nil) do
      AerodromeWatchdogCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_check"].invoke }

        assert_match "AERODROME WATCHDOG CHECK", out
        assert_match "READ ONLY", out
        assert_match "NO ORDERS", out
        assert_match "NO HYPERLIQUID EXECUTION", out
        assert_match "status: WARN", out
        assert_match "critical alerts:", out
        assert_match "next actions:", out
      end
    end
  end

  test "watchdog check task supports JSON output" do
    report = watchdog_report(status: "PASS")

    with_env("FORMAT" => "json") do
      AerodromeWatchdogCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "watchdog alerts task outputs dry-run alert" do
    report = watchdog_alerts_report(severity: "warn")

    with_env("FORMAT" => nil) do
      AerodromeWatchdogAlerts.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_alerts"].invoke }

        assert_match "AERODROME WATCHDOG ALERTS", out
        assert_match "severity: warn", out
        assert_match "delivery: dry_run", out
        assert_match "sent: false", out
        assert_match "skipped_reason: delivery mode dry_run", out
        assert_match "recommended actions:", out
      end
    end
  end

  test "watchdog alerts task supports JSON output" do
    report = watchdog_alerts_report(severity: "pass")

    with_env("FORMAT" => "json") do
      AerodromeWatchdogAlerts.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_alerts"].invoke }
        parsed = JSON.parse(out)

        assert_equal "pass", parsed.fetch("severity")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
        assert_equal "dry_run", parsed.fetch("delivery").fetch("mode")
      end
    end
  end

  test "watchdog scheduler check task outputs read-only status" do
    report = watchdog_scheduler_report(status: "PASS")

    with_env("FORMAT" => nil) do
      AerodromeWatchdogSchedulerCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_scheduler_check"].invoke }

        assert_match "AERODROME WATCHDOG SCHEDULER CHECK", out
        assert_match "READ ONLY", out
        assert_match "NO ORDERS", out
        assert_match "status: PASS", out
      end
    end
  end

  test "watchdog scheduler check task supports JSON output" do
    report = watchdog_scheduler_report(status: "PASS")

    with_env("FORMAT" => "json") do
      AerodromeWatchdogSchedulerCheck.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:watchdog_scheduler_check"].invoke }
        parsed = JSON.parse(out)

        assert_equal "PASS", parsed.fetch("status")
        assert_equal false, parsed.fetch("database_write")
        assert_equal false, parsed.fetch("orders_enabled")
        assert_equal false, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "production canary run task outputs supervised status" do
    report = production_canary_report(status: "success")

    with_env("FORMAT" => nil) do
      AerodromeProductionCanaryRunner.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:production_canary_run"].invoke }

        assert_match "AERODROME PRODUCTION CANARY RUN", out
        assert_match "LIVE ORDER CAPABLE", out
        assert_match "final status: success", out
      end
    end
  end

  test "production canary run task supports JSON output" do
    report = production_canary_report(status: "success")

    with_env("FORMAT" => "json") do
      AerodromeProductionCanaryRunner.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        out, = capture_io { Rake::Task["aerodrome:production_canary_run"].invoke }
        parsed = JSON.parse(out)

        assert_equal "success", parsed.fetch("status")
        assert_equal true, parsed.fetch("orders_enabled")
        assert_equal true, parsed.fetch("hyperliquid_execution")
      end
    end
  end

  test "live observation window task exits false when blocked" do
    report = live_observation_report(status: "blocked", errors: [ "blocked gate" ])

    with_env("FORMAT" => nil) do
      AerodromeLiveObservationWindow.stub(:new, -> {
        Object.new.tap { |object| object.define_singleton_method(:report) { report } }
      }) do
        assert_raises(SystemExit) do
          capture_io { Rake::Task["aerodrome:live_observation_window"].invoke }
        end
      end
    end
  end

  private

  def ok_report(token_id)
    {
      safety_banner: AerodromeSlipstreamDryRun::SAFETY_BANNER,
      database_write: false,
      hedge_enabled: false,
      amount_math_deferred: false,
      notes: [],
      token_count: 1,
      results: [
        {
          token_id: token_id,
          status: "ok",
          owner_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
          position_manager_address: "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53",
          factory_address: "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef",
          pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
          token0_address: "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b",
          token1_address: "0x4200000000000000000000000000000000000006",
          token0_symbol: "AERO",
          token1_symbol: "WETH",
          token0_decimals: 18,
          token1_decimals: 18,
          tick_spacing: 200,
          tick_lower: -151400,
          tick_upper: -147400,
          liquidity: 123,
          sqrt_price_x96: 456,
          current_tick: -155876,
          tokens_owed0_raw: 7,
          tokens_owed1_raw: 11,
          amount0_raw: 1_290_590_456_994_170_212,
          amount1_raw: 4_594_633_482,
          amount0_decimal: "1.290590456994170212",
          amount1_decimal: "0.000000004594633482",
          math_source: AerodromeSlipstreamService::VERIFIED_AMOUNT_MATH_SOURCE,
          verification_status: "verified_math",
          partial_data_reason: nil,
          token0_price_usd: "2000.0",
          token1_price_usd: "1.0",
          total_value_usd: "7081.180913988340424",
          valuation_status: "supported",
          valuation_source: AerodromeSlipstreamValuation::VALUATION_SOURCE,
          valuation_reason: nil,
          hedge_preview_supported: true,
          hedge_preview_reason: nil,
          hedge_asset: "ETH",
          hedge_side: "short",
          suggested_short_amount: "1.290590456994170212",
          suggested_short_notional_usd: "2581.180913988340424",
          lp_weth_amount: "1.290590456994170212",
          lp_usdc_amount: "0.000000004594633482",
          lp_total_value_usd: "7081.180913988340424",
          weth_price_usd: "2000.0",
          hedge_preview_source: AerodromeHedgePreview::SOURCE,
          hedge_preview_verification_status: "preview_only",
          execution_enabled: false,
          hyperliquid_called: false,
          hedge_enabled: false,
          database_write: false,
          error_class: nil,
          error_message: nil
        }
      ]
    }
  end

  def pre_live_report(status:, blockers: [], warnings: [])
    {
      safety_banner: AerodromePreLiveCheck::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      checks: {
        env: [ { name: "AERODROME_HEDGE_ENABLED is false", status: "pass" } ],
        db: [],
        risk_limits: [],
        rehearsal_evidence: [],
        hyperliquid_readback: []
      },
      blockers: blockers,
      warnings: warnings,
      next_steps: [ "Passing this check is not live approval." ]
    }
  end

  def emergency_close_report(status:)
    {
      safety_banner: AerodromeTestnetEmergencyClose::BANNER,
      status: status,
      hyperliquid_testnet: true,
      live_approved: false,
      attempts: [],
      before_position: { asset: "ETH", size: "0.25" },
      after_position: nil,
      errors: [],
      database_write: false,
      touched_asset: "ETH"
    }
  end

  def live_emergency_close_report(status:, errors: [])
    {
      safety_banner: AerodromeLiveEmergencyClose::BANNER,
      status: status,
      live_order_capable: true,
      gates: {
        hyperliquid_testnet: "false",
        live_approved: true,
        hedge_paused: true,
        emergency_close_enabled: true,
        confirmation_present: true,
        confirmation_valid: true,
        max_close_eth: "0.5"
      },
      before_position: { asset: "ETH", size: "-0.25" },
      after_position: nil,
      attempts: [],
      errors: errors,
      database_write: false,
      touched_asset: "ETH"
    }
  end

  def live_preflight_report(status:, blockers: [], warnings: [])
    {
      safety_banner: AerodromeLivePreflightCheck::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      checks: {
        env: [ { name: "HYPERLIQUID_TESTNET is false", status: "pass" } ],
        db: [],
        risk: [],
        testnet_evidence: [],
        hyperliquid_readback: []
      },
      blockers: blockers,
      warnings: warnings,
      next_steps: [ "PASS is not permission to live trade." ]
    }
  end

  def acknowledge_failed_rebalance_report(status:, errors: [])
    {
      safety_banner: AerodromeFailedRebalanceAcknowledgment::BANNER,
      status: status,
      database_write: status == "success",
      orders_enabled: false,
      hyperliquid_execution: false,
      rebalance_id: 182,
      asset: "WETH",
      old_short_size: "0.0",
      new_short_size: "0.0",
      acknowledgment_marker: AerodromeFailedRebalanceAcknowledgment::MARKER,
      errors: errors
    }
  end

  def live_observation_report(status:, errors: [])
    {
      safety_banner: AerodromeLiveObservationWindow::BANNER,
      status: status,
      live_order_capable: true,
      log_path: "/tmp/aerodrome-live-observation.jsonl",
      gates: {
        duration_seconds: 60,
        interval_seconds: 60,
        max_short_eth: "0.02",
        max_short_notional_usd: "50.0"
      },
      iterations: [ { iteration: 1 } ],
      final_close: { status: "success" },
      final_position: nil,
      final_position_confirmed: true,
      final_readback_attempts: [ { attempt: 1, status: "success", position: nil } ],
      manual_action_required: false,
      errors: errors
    }
  end

  def production_readiness_report(status:)
    {
      safety_banner: AerodromeProductionSupervisedReadiness::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      git_sha: "abc123",
      git_sha_source: "env",
      rails_env: "test",
      safe_env: {
        "AERODROME_HEDGE_ENABLED" => "false",
        "AERODROME_HEDGE_PAUSED" => "true",
        "AERODROME_LIVE_APPROVED" => "false",
        "HYPERLIQUID_TESTNET" => "true"
      },
      checks: {
        env: [ { name: "AERODROME_HEDGE_ENABLED is false", status: "pass" } ],
        logs: [ { name: "Latest observation final position nil", status: "pass" } ]
      },
      observation_summary: observation_summary_report(status: "PASS"),
      backup_path_suggestion: "storage/backups",
      blockers: [],
      warnings: status == "WARN" ? [ "review warning" ] : [],
      next_steps: [ "Readiness is not live approval." ]
    }
  end

  def observation_summary_report(status:)
    {
      safety_banner: AerodromeLiveObservationSummary::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      log_path: "storage/aerodrome_live_observation/test.jsonl",
      duration_seconds: 10_800,
      iterations: 36,
      first_timestamp: "2026-05-10T06:01:57Z",
      last_timestamp: "2026-05-10T09:01:57Z",
      max_observed_eth_short: "0.011",
      rebalances_count: 1,
      errors_count: 0,
      final_close_status: "success",
      final_position: nil,
      final_position_confirmed: true,
      manual_action_required: false,
      blockers: [],
      warnings: [],
      next_steps: [ "Observation summary is read-only evidence only." ]
    }
  end

  def watchdog_report(status:)
    {
      safety_banner: AerodromeWatchdogCheck::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      alerts: status == "WARN" ? [ "review warning" ] : [],
      warnings: status == "WARN" ? [ "stale pnl" ] : [],
      blockers: [],
      checks: {
        env: [ { name: "AERODROME_HEDGE_ENABLED is false", status: "pass" } ],
        hyperliquid: [ { name: "Mainnet ETH position nil while safe env", status: "pass" } ]
      },
      next_steps: [ "Watchdog is read-only." ]
    }
  end

  def watchdog_alerts_report(severity:)
    {
      safety_banner: AerodromeWatchdogAlerts::BANNER,
      status: severity == "pass" ? "PASS" : "WARN",
      severity: severity,
      title: "Aerodrome watchdog #{severity}",
      summary: "status=#{severity}",
      body: "body",
      blockers: [],
      warnings: severity == "warn" ? [ "Latest PnL snapshot fresh" ] : [],
      recommended_actions: [ "Review warnings before any further live window." ],
      delivery: { enabled: false, mode: "dry_run", sent: false, recipient: nil, skipped_reason: "delivery mode dry_run", min_severity: "warn" },
      timestamp: "2026-05-10T12:00:00Z",
      git_sha: "abc123",
      sent: false,
      recipient: nil,
      skipped_reason: "delivery mode dry_run",
      fingerprint: "abc123fingerprint",
      fingerprint_changed: true,
      cooldown_seconds: 1800,
      last_sent_at: nil,
      state_write: false,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false
    }
  end

  def watchdog_scheduler_report(status:)
    {
      safety_banner: AerodromeWatchdogSchedulerCheck::BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      checks: {},
      blockers: [],
      warnings: [],
      next_steps: [ "Scheduler foundation is read-only." ]
    }
  end

  def production_canary_report(status:)
    {
      safety_banner: AerodromeProductionCanaryRunner::BANNER,
      status: status,
      live_order_capable: true,
      log_path: "storage/aerodrome_production_canary/test.jsonl",
      gates: {
        duration_seconds: 900,
        interval_seconds: 180,
        max_short_eth: "0.02",
        max_short_notional_usd: "50"
      },
      iterations: 1,
      iteration_events: [],
      rebalances_count: 1,
      stop_reason: "duration complete",
      final_close: { status: "success" },
      final_position: nil,
      final_position_confirmed: true,
      manual_action_required: false,
      errors: [],
      database_write: true,
      orders_enabled: true,
      hyperliquid_execution: true
    }
  end

  def rewards_report
    {
      safety_banner: AerodromeRewardsCheck::BANNER,
      status: "PASS",
      database_write: false,
      transactions_enabled: false,
      claims_enabled: false,
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token_id: "315985",
      position_wallet_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      wallet_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      depositor_address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701",
      depositor_source: "position_wallet",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.25",
      asset1_amount: "500",
      current_pooled_value_usd: "3000",
      gauge_status: "detected",
      gauge_address: "0x1111111111111111111111111111111111111111",
      staked: true,
      staked_token_ids: nil,
      reward_rate_raw: 77,
      claimable_aero: "12.5",
      claimable_aero_raw: 12_500_000_000_000_000_000,
      aero_usd_price: "0.75",
      aero_usd_price_source: "manual",
      claimable_aero_usd: "9.375",
      checks: [],
      blockers: [],
      warnings: [],
      next_steps: [ "Rewards are read-only discovery only." ]
    }
  end

  def fees_report
    {
      safety_banner: AerodromeFeesCheck::BANNER,
      status: "PASS",
      database_write: false,
      transactions_enabled: false,
      collect_enabled: false,
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      token_id: "315985",
      fee_source: AerodromeFeesService::SOURCE,
      fee0_symbol: "WETH",
      fee0_amount: "0.01",
      fee0_usd: "20.0",
      fee1_symbol: "USDC",
      fee1_amount: "3.5",
      fee1_usd: "3.5",
      total_fees_usd: "23.5",
      blockers: [],
      warnings: [],
      next_steps: [ "Fee values are read-only estimates until collected." ]
    }
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
