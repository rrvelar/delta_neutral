require "test_helper"
require "rake"

class NadoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nado:auto_readiness")
    Rake::Task["nado:auto_readiness"].reenable
    Rake::Task["nado:confirm_digest_readonly"].reenable if Rake::Task.task_defined?("nado:confirm_digest_readonly")
    Rake::Task["nado:auto_rebalance_once"].reenable if Rake::Task.task_defined?("nado:auto_rebalance_once")
    Rake::Task["nado:market_metadata"].reenable if Rake::Task.task_defined?("nado:market_metadata")
  end

  test "nado auto readiness task exists and reports env-gated readiness without live counters" do
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")

    fake_adapter = Object.new
    def fake_adapter.readiness(position:)
      {
        venue: "nado",
        position_id: position.id,
        continuous_auto_ready: false,
        blockers: [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ],
        orders_submitted: 0,
        signatures_created: 0
      }
    end

    HedgeVenueAutoAdapters::Nado.stub(:new, fake_adapter) do
      with_position_id(position.id) do
        out, = capture_io { Rake::Task["nado:auto_readiness"].invoke }
        payload = JSON.parse(out)

        assert_equal "nado_auto_readiness", payload.fetch("action")
        assert_equal false, payload.fetch("continuous_auto_ready")
        assert_includes payload.fetch("blockers"), "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true"
        assert_equal 0, payload.fetch("orders_submitted")
        assert_equal 0, payload.fetch("signatures_created")
      end
    end
  end

  test "nado market metadata task prints read-only diagnostics" do
    fake_metadata = {
      status: "ok",
      product_id: 4,
      source: "test",
      market_price: "2300.0",
      price_increment: "1.0",
      size_increment: "0.001",
      diagnostics: {
        market_price_query: {
          endpoint: "/query",
          query_params: { type: "market_price", product_id: "4" },
          status: "ok",
          top_level_keys: [ "data" ],
          response_keys: %w[ask_x18 bid_x18],
          bid_x18: "2299000000000000000000",
          ask_x18: "2301000000000000000000",
          parsed_bid: "2299.0",
          parsed_ask: "2301.0",
          selected_mark_price: "2300.0"
        }
      },
      blockers: [],
      warnings: []
    }
    service = Object.new
    service.define_singleton_method(:market_metadata) { |position: nil| fake_metadata }

    NadoHedgeExecutionService.stub(:new, service) do
      out, = capture_io { Rake::Task["nado:market_metadata"].invoke }
      payload = JSON.parse(out)

      assert_equal "nado_market_metadata", payload.fetch("action")
      assert_equal "ok", payload.fetch("status")
      assert_equal "/query", payload.fetch("endpoint")
      assert_equal "4", payload.fetch("query_params").fetch("product_id")
      assert_equal "2299000000000000000000", payload.fetch("bid_x18")
      assert_equal "2300.0", payload.fetch("selected_mark_price")
      assert_equal "0.001", payload.fetch("size_increment")
      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
    end
  ensure
    Rake::Task["nado:market_metadata"].reenable if Rake::Task.task_defined?("nado:market_metadata")
  end

  test "nado confirm digest readonly task prints request summaries with zero side effects" do
    result = {
      status: "unconfirmed",
      confirmed: false,
      confirmed_at: nil,
      source: nil,
      digest: "0xabc",
      gateway_order_request: {
        method: "GET",
        url: "https://nado.example/v1/query?type=order&product_id=4&digest=0xabc",
        params: { type: "order", product_id: "4", digest: "0xabc" }
      },
      archive_order_request: {
        method: "POST",
        url: nil,
        payload: { orders: { digests: [ "0xabc" ], limit: 1 } }
      },
      attempts: [
        {
          source: "gateway_order",
          status: "ok",
          response_summary: { row_present: true, order_digest: "", base_filled: "0.0", unfilled_amount: "0.0" }
        },
        {
          source: "archive_order",
          status: "skipped",
          blocker: "NADO_ARCHIVE_ENDPOINT is not configured"
        }
      ],
      blockers: [ "NADO_ARCHIVE_ENDPOINT is not configured" ]
    }

    NadoExecutionConfirmation.stub(:confirm_digest, ->(digest:, product_id:, env:) {
      assert_equal "0xabc", digest
      assert_equal "4", product_id
      assert_same ENV, env
      result
    }) do
      with_digest_env("0xabc", "4") do
        out, = capture_io { Rake::Task["nado:confirm_digest_readonly"].invoke }
        payload = JSON.parse(out)

        assert_equal "nado_confirm_digest_readonly", payload.fetch("action")
        assert_equal false, payload.fetch("confirmed")
        assert_equal "none", payload.fetch("source")
        assert_equal "https://nado.example/v1/query?type=order&product_id=4&digest=0xabc", payload.fetch("gateway_order_request").fetch("url")
        assert_equal "0.0", payload.fetch("gateway_order_response_summary").fetch("base_filled")
        assert_includes payload.fetch("blockers"), "NADO_ARCHIVE_ENDPOINT is not configured"
        assert_equal 0, payload.fetch("orders_submitted")
        assert_equal 0, payload.fetch("signatures_created")
        assert_equal 0, payload.fetch("cancels_submitted")
      end
    end
  ensure
    Rake::Task["nado:confirm_digest_readonly"].reenable if Rake::Task.task_defined?("nado:confirm_digest_readonly")
  end

  test "nado auto rebalance once does not abort as blocked for confirmed late accepted submit" do
    position = nado_position
    runner = FakeNadoAutoRebalanceRunner.new(
      HedgeVenueAutoRebalanceOnce::Result.new("rebalance_confirmed_late", [], [], {
        venue: "nado",
        source: "manual_one_shot",
        final_status: "REBALANCE_CONFIRMED_LATE",
        lifecycle_state: "CONFIRMED_LATE_BY_RECONCILIATION",
        exchange_order_id: "0x#{"79" * 32}",
        readback_confirmed: true,
        orders_submitted: 1,
        signatures_created: 1,
        blockers: []
      })
    )

    HedgeVenueAutoRebalanceAdapters::Nado.stub(:new, runner) do
      with_position_id(position.id) do
        with_live_env do
          out, err = capture_io { Rake::Task["nado:auto_rebalance_once"].invoke }
          payload = JSON.parse(out)

          assert_empty err
          assert_equal "confirmed_late", payload.fetch("cli_status")
          assert_equal "REBALANCE_CONFIRMED_LATE", payload.fetch("final_status")
          assert_equal "0x#{"79" * 32}", payload.fetch("exchange_order_id")
          assert_equal 1, payload.fetch("orders_submitted")
        end
      end
    end
  end

  test "nado auto rebalance once reports pending recheck without blocked prefix after accepted submit" do
    position = nado_position
    runner = FakeNadoAutoRebalanceRunner.new(
      HedgeVenueAutoRebalanceOnce::Result.new("submitted_pending_readback", [], [], {
        venue: "nado",
        source: "manual_one_shot",
        final_status: "REBALANCE_REQUIRES_RECHECK",
        lifecycle_state: "SUBMITTED_PENDING_READBACK",
        exchange_order_id: "0x#{"45" * 32}",
        readback_confirmed: false,
        manual_action_required: true,
        orders_submitted: 1,
        signatures_created: 1,
        blockers: []
      })
    )

    HedgeVenueAutoRebalanceAdapters::Nado.stub(:new, runner) do
      with_position_id(position.id) do
        with_live_env do
          out, err = capture_io { Rake::Task["nado:auto_rebalance_once"].invoke }
          payload = JSON.parse(out)

          assert_empty err
          assert_equal "pending_recheck", payload.fetch("cli_status")
          assert_equal "REBALANCE_REQUIRES_RECHECK", payload.fetch("final_status")
          assert_equal "0x#{"45" * 32}", payload.fetch("exchange_order_id")
          assert_equal 1, payload.fetch("orders_submitted")
        end
      end
    end
  end

  private

  def with_position_id(position_id)
    previous = ENV["position_id"]
    ENV["position_id"] = position_id.to_s
    yield
  ensure
    ENV["position_id"] = previous
    Rake::Task["nado:auto_readiness"].reenable
    Rake::Task["nado:auto_rebalance_once"].reenable if Rake::Task.task_defined?("nado:auto_rebalance_once")
  end

  def with_live_env
    previous = {
      "live" => ENV["live"],
      "confirmation" => ENV["confirmation"]
    }
    ENV["live"] = "true"
    ENV["confirmation"] = "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_ORDERS"
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_digest_env(digest, product_id)
    previous = {
      "digest" => ENV["digest"],
      "product_id" => ENV["product_id"]
    }
    ENV["digest"] = digest
    ENV["product_id"] = product_id
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    Rake::Task["nado:confirm_digest_readonly"].reenable if Rake::Task.task_defined?("nado:confirm_digest_readonly")
  end

  def nado_position
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    ).tap do |position|
      position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
    end
  end

  class FakeNadoAutoRebalanceRunner
    def initialize(result)
      @result = result
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:)
      @result
    end
  end
end
