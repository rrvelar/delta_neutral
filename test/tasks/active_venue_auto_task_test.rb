require "test_helper"
require "rake"

class ActiveVenueAutoTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("extended:auto_readiness")
    %w[extended:auto_readiness ethereal:auto_readiness ethereal:auto_rebalance_once].each do |task_name|
      Rake::Task[task_name].reenable if Rake::Task.task_defined?(task_name)
    end
  end

  test "extended auto readiness task uses canonical active venue readiness" do
    position = active_auto_position("extended")
    readiness = FakeReadiness.new(
      venue: "extended",
      position_id: position.id,
      active_auto_venue: "extended",
      continuous_auto_ready: true,
      blockers: [],
      orders_submitted: 0,
      signatures_created: 0
    )

    HedgeVenueAutoReadiness.stub(:new, readiness) do
      with_position_id(position.id) do
        out, = capture_io { Rake::Task["extended:auto_readiness"].invoke }
        payload = JSON.parse(out)

        assert_equal "extended", payload.fetch("active_auto_venue")
        assert_equal 0, payload.fetch("orders_submitted")
        assert_equal 0, payload.fetch("signatures_created")
      end
    end
  end

  test "ethereal auto readiness task uses canonical active venue readiness" do
    position = active_auto_position("ethereal")
    readiness = FakeReadiness.new(
      venue: "ethereal",
      position_id: position.id,
      active_auto_venue: "ethereal",
      continuous_auto_ready: true,
      blockers: [],
      orders_submitted: 0,
      signatures_created: 0
    )

    HedgeVenueAutoReadiness.stub(:new, readiness) do
      with_position_id(position.id) do
        out, = capture_io { Rake::Task["ethereal:auto_readiness"].invoke }
        payload = JSON.parse(out)

        assert_equal "ethereal_auto_readiness", payload.fetch("action")
        assert_equal "ethereal", payload.fetch("active_auto_venue")
        assert_equal 0, payload.fetch("orders_submitted")
        assert_equal 0, payload.fetch("signatures_created")
      end
    end
  end

  test "ethereal auto rebalance once task uses canonical active venue rebalance once dry run" do
    position = active_auto_position("ethereal")
    runner = FakeRebalanceOnce.new(
      HedgeVenueAutoRebalanceOnce::Result.new(
        "dry_run",
        [],
        [],
        {
          venue: "ethereal",
          planned_auto_action: "no_op",
          orders_submitted: 0,
          orders_placed: 0,
          signatures_created: 0,
          final_status: "dry_run"
        }
      )
    )

    HedgeVenueAutoRebalanceOnce.stub(:new, runner) do
      with_position_id(position.id) do
        out, = capture_io { Rake::Task["ethereal:auto_rebalance_once"].invoke }
        payload = JSON.parse(out)

        assert_equal "ethereal_auto_rebalance_once", payload.fetch("action")
        assert_equal "ethereal", payload.fetch("venue")
        assert_equal "no_op", payload.fetch("planned_auto_action")
        assert_equal 0, payload.fetch("orders_submitted")
        assert_equal 0, payload.fetch("signatures_created")
      end
    end

    assert_equal 1, runner.calls.size
    assert_equal true, runner.calls.first.fetch(:dry_run)
    assert_equal false, runner.calls.first.fetch(:live)
  end

  private

  def active_auto_position(venue)
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
      position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: venue)
    end
  end

  def with_position_id(position_id)
    previous = ENV["position_id"]
    ENV["position_id"] = position_id.to_s
    yield
  ensure
    previous.nil? ? ENV.delete("position_id") : ENV["position_id"] = previous
    %w[extended:auto_readiness ethereal:auto_readiness ethereal:auto_rebalance_once].each do |task_name|
      Rake::Task[task_name].reenable if Rake::Task.task_defined?(task_name)
    end
  end

  class FakeReadiness
    def initialize(report)
      @report = report
    end

    def report(position:)
      @report.merge(position_id: position.id)
    end
  end

  class FakeRebalanceOnce
    attr_reader :calls

    def initialize(result)
      @result = result
      @calls = []
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:)
      @calls << { position: position, dry_run: dry_run, live: live, confirmation: confirmation, max_slippage: max_slippage }
      @result
    end
  end
end
