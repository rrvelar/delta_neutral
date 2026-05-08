require "test_helper"
require "rake"

class AerodromeTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("aerodrome:dry_run")
    Rake::Task["aerodrome:dry_run"].reenable
    Rake::Task["aerodrome:verify_config"].reenable
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
        assert_match "Token 999: partial", out
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
        assert_match "AMOUNT MATH DEFERRED", out
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
        assert_equal "5016", parsed.fetch("results").first.fetch("token_id")
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
        assert_match "Token 5016: partial", out
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

  private

  def ok_report(token_id)
    {
      safety_banner: AerodromeSlipstreamDryRun::SAFETY_BANNER,
      database_write: false,
      hedge_enabled: false,
      amount_math_deferred: true,
      notes: [],
      token_count: 1,
      results: [
        {
          token_id: token_id,
          status: "partial",
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
          amount0_raw: nil,
          amount1_raw: nil,
          partial_data_reason: AerodromeSlipstreamService::PARTIAL_AMOUNT_MATH_DEFERRED,
          hedge_enabled: false,
          database_write: false,
          error_class: nil,
          error_message: nil
        }
      ]
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
