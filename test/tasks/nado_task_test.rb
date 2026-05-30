require "test_helper"
require "rake"

class NadoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("nado:auto_readiness")
    Rake::Task["nado:auto_readiness"].reenable
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
