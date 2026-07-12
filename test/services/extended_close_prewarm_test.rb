require "test_helper"

# Pre-window read warming for target_first Extended source closes
# (2026-07-12 extended->ethereal latency fix): static close-build reads happen
# BEFORE the target leg opens the double-exposure window; volatile safety reads
# (open orders, post-submit readback, final verification) stay inside/fresh.
class ExtendedClosePrewarmTest < ActiveSupport::TestCase
  class PrewarmProbeLegRunner
    attr_reader :calls, :prewarm_times

    def initialize(now:)
      @now = now
      @calls = []
      @prewarm_times = []
    end

    def prewarm_extended_source_close!(leg)
      @prewarm_times << @now.call
      { reads: %w[positions market leverage balance], size_eth: leg[:size_eth].to_s }
    end

    def call(leg, context:)
      @calls << { leg: leg, at: @now.call }
      {
        status: "confirmed", confirmed: true, orders_placed: 1, signatures_created: 1,
        exchange_order_id: leg.fetch(:venue) == "ethereal" ? "eth-open" : "ext-close",
        readback: { short_size: leg.fetch(:venue) == "ethereal" ? "0.8" : "0" }
      }
    end
  end

  def run_executor(leg_runner)
    position = migration_position
    HedgeVenueMigrationExecutor.new(
      env: { "MIGRATION_LIVE_ENABLED" => "true", "EXTENDED_LIVE_ENABLED" => "true", "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true" },
      leg_runner: leg_runner,
      now: advancing_clock,
      snapshot_refresher: ->(item) { item.position_dashboard_snapshot },
      final_verifier_factory: final_verifier_factory(from: "extended", to: "ethereal")
    ).run(
      position: position,
      from_venue: "extended",
      to_venue: "ethereal",
      dry_run: false,
      confirmation: HedgeVenueMigrationExecutor::CONFIRMATION,
      full_migration_allowed: true,
      mode: "full"
    )
  end

  test "prewarm runs before the target leg opens the double-exposure window" do
    runner = PrewarmProbeLegRunner.new(now: advancing_clock)
    result = run_executor(runner)

    assert_equal "success", result.status, result.blockers.inspect
    assert_equal 1, runner.prewarm_times.size
    receipt = result.receipt
    assert receipt[:pre_window_warmup_started_at].present?
    assert receipt[:pre_window_warmup_finished_at].present?
    assert_operator receipt[:pre_window_warmup_finished_at], :<=, receipt[:target_leg_submit_started_at]
    assert_operator receipt[:pre_window_warmup_finished_at], :<=, receipt[:double_exposure_started_at]
    assert_equal %w[positions market leverage balance], receipt[:pre_window_warmup_reads]
    assert_equal "pre_window_snapshot", receipt[:metadata_source]
  end

  test "prewarm failure is fail-closed: recorded and the migration proceeds on live reads" do
    runner = PrewarmProbeLegRunner.new(now: advancing_clock)
    def runner.prewarm_extended_source_close!(_leg)
      raise "warmup transport error"
    end
    result = run_executor(runner)

    assert_equal "success", result.status, result.blockers.inspect
    assert_match(/warmup transport error/, result.receipt[:pre_window_warmup_error].to_s)
    assert_equal "live_read", result.receipt[:metadata_source]
  end

  test "leg runners without prewarm support are unaffected" do
    runner = PrewarmProbeLegRunner.new(now: advancing_clock)
    runner.singleton_class.undef_method(:prewarm_extended_source_close!)
    result = run_executor(runner)

    assert_equal "success", result.status, result.blockers.inspect
    assert_nil result.receipt[:pre_window_warmup_started_at]
  end

  test "DefaultLegRunner exposes the prewarm hook publicly (executor guard depends on it)" do
    assert HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: {}).respond_to?(:prewarm_extended_source_close!),
      "prewarm_extended_source_close! must be public or the executor silently skips warming"
  end

  test "prewarmed venue is discarded on size mismatch (fail closed to fresh reads)" do
    fake_venue = Class.new do
      attr_reader :ended
      def respond_to_missing?(*) = true
      def end_read_snapshot! = (@ended = true)
      def respond_to?(name, include_all = false)
        name == :end_read_snapshot! || super
      end
    end.new
    leg_runner = HedgeVenueMigrationExecutor::DefaultLegRunner.new(env: {})
    leg_runner.instance_variable_set(:@prewarmed_extended, { venue: fake_venue, size: BigDecimal("2.0") })

    assert_nil leg_runner.send(:consume_prewarmed_extended, BigDecimal("1.5"))
    assert fake_venue.ended, "mismatched prewarm snapshot must be closed"
    assert_nil leg_runner.instance_variable_get(:@prewarmed_extended)
  end

  private

  def advancing_clock
    @advancing_clock ||= begin
      current = Time.zone.local(2026, 7, 12, 12, 0, 0)
      -> { current += 1.second }
    end
  end

  def final_verifier_factory(from:, to:)
    verifier = Class.new do
      def initialize(to) = (@to = to)
      def verify
        {
          latest_attempt: { source_short_eth: "0", target_venue_short_eth: "0.8", combined_short_eth: "0.8",
                            expected_target_short_eth: "0.8", open_orders_count: 0 },
          attempts: [ {} ],
          source_flat: true, target_confirmed: true, third_venue_flat: true,
          open_orders_clear: true, combined_inside_tolerance: true, blockers: []
        }
      end
    end.new(to)
    ->(position:, receipt:) { verifier }
  end

  def migration_position
    position = Position.create!(
      user: users(:one), wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH", asset1: "USDC", asset0_amount: "1", asset1_amount: "1000",
      asset0_price_usd: "2000", asset1_price_usd: "1",
      external_id: SecureRandom.hex(4), active: true
    )
    position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current, refresh_status: "ok", stale: false,
      production_venue: "extended", selected_venue: "extended",
      target_short_eth: "0.8", tolerance_ratio: "0.03",
      extended_short_eth: "0.8", ethereal_short_eth: "0", nado_short_eth: "0",
      combined_short_eth: "0.8", drift_eth: "0", inside_tolerance: true
    )
    position
  end
end
