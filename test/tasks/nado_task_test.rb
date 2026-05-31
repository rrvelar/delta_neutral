require "test_helper"
require "rake"

class NadoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nado:auto_readiness")
    Rake::Task["nado:auto_readiness"].reenable
    Rake::Task["nado:market_metadata"].reenable if Rake::Task.task_defined?("nado:market_metadata")
  end

  test "nado auto readiness task exists and fails closed without live counters" do
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
        blockers: [ "Nado isolated live auto open/increase submit path is not proven in delta_neutral." ],
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
        assert payload.fetch("blockers").any? { |blocker| blocker.include?("Nado isolated live auto open/increase submit path") }
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

  private

  def with_position_id(position_id)
    previous = ENV["position_id"]
    ENV["position_id"] = position_id.to_s
    yield
  ensure
    ENV["position_id"] = previous
    Rake::Task["nado:auto_readiness"].reenable
  end
end
