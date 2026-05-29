require "test_helper"

class HedgeEmergencyRestoreTest < ActiveSupport::TestCase
  test "dry-run restore computes target from position asset0 amount and hedge target" do
    result = restore(position: position(asset0_amount: "1.28366857878458"), venue: FakeExtendedVenue.new).run

    assert_equal "dry_run", result.status
    assert_equal "1.28366857878458", result.receipt.fetch(:target_short_eth)
    assert_equal "1.28366857878458", result.receipt.fetch(:order_size_eth)
    assert_equal "sell", result.receipt.fetch(:side)
    assert_equal false, result.receipt.fetch(:reduce_only)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "emergency restore refuses stale DB target unless refresh succeeds" do
    result = restore(position: position, venue: FakeExtendedVenue.new, refresher: FakeExposureRefresher.new(status: "blocked")).run

    assert_equal "dry_run", result.status
    assert_includes result.blockers, "fresh Mellow exposure required before hedge sizing"
    assert_equal 0, result.receipt.fetch(:orders_submitted)
  end

  test "emergency refresh updates position exposure from mocked fresh Mellow source" do
    current = position(asset0_amount: "1.28366857878458", source: Position::SOURCE_MELLOW_AUTOPILOT, mellow_metadata: { "hedge_ready" => false })

    result = restore(position: current, venue: FakeExtendedVenue.new(current_short: "1.283"), action: "adjust", refresher: FakeExposureRefresher.new(asset0: "1.01675", asset1: "532.91")).run

    assert_equal "dry_run", result.status
    assert_equal BigDecimal("1.01675"), current.reload.asset0_amount
    assert_equal "1.28366857878458", result.receipt.fetch(:db_asset0_before)
    assert_equal "1.01675", result.receipt.fetch(:fresh_asset0_after)
  end

  test "overhedged adjust builds buy reduce only order" do
    current = position(asset0_amount: "1.28366857878458")

    result = restore(position: current, venue: FakeExtendedVenue.new(current_short: "1.283"), action: "adjust", refresher: FakeExposureRefresher.new(asset0: "1.01675", asset1: "532.91")).run

    assert_equal "dry_run", result.status
    assert_equal "buy", result.receipt.fetch(:side)
    assert_equal true, result.receipt.fetch(:reduce_only)
    assert_in_delta BigDecimal("0.26625"), BigDecimal(result.receipt.fetch(:order_size_eth)), BigDecimal("0.0001")
  end

  test "underhedged adjust builds sell non reduce-only order" do
    current = position(asset0_amount: "0.8")

    result = restore(position: current, venue: FakeExtendedVenue.new(current_short: "0.8"), action: "adjust", refresher: FakeExposureRefresher.new(asset0: "1.01675", asset1: "532.91")).run

    assert_equal "dry_run", result.status
    assert_equal "sell", result.receipt.fetch(:side)
    assert_equal false, result.receipt.fetch(:reduce_only)
  end

  test "dry-run does not depend on PositionValuation weth exposure" do
    PositionValuation.stub(:current, ->(*) { raise "PositionValuation must not be used" }) do
      result = restore(position: position, venue: FakeExtendedVenue.new).run

      assert_equal "dry_run", result.status
      assert_empty result.blockers
    end
  end

  test "dry-run ignores Mellow hedge-ready blocker" do
    mellow = position(source: Position::SOURCE_MELLOW_AUTOPILOT, mellow_metadata: { "hedge_ready" => false })

    result = restore(position: mellow, venue: FakeExtendedVenue.new).run

    assert_equal "dry_run", result.status
    assert_not_includes result.blockers, "Mellow Autopilot pro-rata exposure is not hedge-ready"
  end

  test "dry-run ignores old failed ShortRebalance history" do
    current = position
    3.times do
      current.hedge.short_rebalances.create!(
        asset: "WETH",
        old_short_size: "0",
        new_short_size: "0",
        status: "failed",
        message: "old failure",
        venue: "extended",
        rebalanced_at: 1.hour.ago
      )
    end

    result = restore(position: current, venue: FakeExtendedVenue.new).run

    assert_equal "dry_run", result.status
    assert_empty result.blockers
  end

  test "live blocks without emergency restore env gate" do
    lifecycle = FakeLifecycle.new
    result = restore(position: position, venue: FakeExtendedVenue.new, live: true, confirmation: HedgeEmergencyRestore::CONFIRMATION, lifecycle: lifecycle).run

    assert_equal "RESTORE_BLOCKED", result.status
    assert_includes result.blockers, "HEDGE_EMERGENCY_ADJUST_ENABLED or HEDGE_EMERGENCY_RESTORE_ENABLED must be true"
    assert_equal 0, lifecycle.calls
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "live blocks without exact confirmation" do
    lifecycle = FakeLifecycle.new
    result = restore(position: position, venue: FakeExtendedVenue.new, live: true, confirmation: "wrong", env: live_env, lifecycle: lifecycle).run

    assert_equal "RESTORE_BLOCKED", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{HedgeEmergencyRestore::CONFIRMATION}"
    assert_equal 0, lifecycle.calls
  end

  test "live blocks if another venue has conflicting short above tolerance" do
    current = position(ethereal_short: "0.2")

    result = restore(position: current, venue: FakeExtendedVenue.new, live: true, confirmation: HedgeEmergencyRestore::CONFIRMATION, env: live_env).run

    assert_equal "RESTORE_BLOCKED", result.status
    assert_includes result.blockers, "Ethereal has a conflicting short above tolerance"
  end

  test "live builds Extended sell non reduce-only order and confirms readback" do
    lifecycle = FakeLifecycle.new(final_short: "1.0")
    result = restore(position: position, venue: FakeExtendedVenue.new, live: true, confirmation: HedgeEmergencyRestore::CONFIRMATION, env: live_env, lifecycle: lifecycle).run

    assert_equal "RESTORE_CONFIRMED", result.status
    assert_equal 1, lifecycle.calls
    assert_equal "open_only", lifecycle.last_args.fetch(:mode)
    assert_equal BigDecimal("1.0"), lifecycle.last_args.fetch(:size_eth)
    assert_nil lifecycle.last_args[:delta_eth]
    assert_equal "sell", result.receipt.dig(:preview_payload, :side)
    assert_equal false, result.receipt.dig(:preview_payload, :reduce_only)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal true, result.receipt.fetch(:readback_confirmed)
    assert_equal true, result.receipt.fetch(:inside_tolerance)
  end

  test "live mocked adjust confirms readback against fresh target" do
    current = position(asset0_amount: "1.28366857878458")
    lifecycle = FakeLifecycle.new(final_short: "1.01675")

    result = restore(
      position: current,
      venue: FakeExtendedVenue.new(current_short: "1.283"),
      live: true,
      confirmation: HedgeEmergencyRestore::ADJUST_CONFIRMATION,
      env: live_env.merge("HEDGE_EMERGENCY_ADJUST_ENABLED" => "true"),
      lifecycle: lifecycle,
      action: "adjust",
      refresher: FakeExposureRefresher.new(asset0: "1.01675", asset1: "532.91")
    ).run

    assert_equal "RESTORE_CONFIRMED", result.status
    assert_equal "rebalance_delta", lifecycle.last_args.fetch(:mode)
    assert_equal BigDecimal("-0.26625"), lifecycle.last_args.fetch(:delta_eth)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal true, result.receipt.fetch(:inside_tolerance)
  end

  private

  def restore(position:, venue:, live: false, confirmation: nil, env: base_env, lifecycle: FakeLifecycle.new, action: "restore", refresher: nil)
    refresher ||= FakeExposureRefresher.new
    refresher.position = position
    HedgeEmergencyRestore.new(
      position: position,
      dry_run: !live,
      live: live,
      confirmation: confirmation,
      env: env,
      venue: venue,
      lifecycle_factory: ->(_lifecycle_env, _venue) { lifecycle },
      exposure_refresher: refresher,
      receipt_dir: Rails.root.join("tmp/test-hedge-emergency-restore-#{SecureRandom.hex(4)}"),
      action: action
    )
  end

  def position(asset0_amount: "1.0", ethereal_short: "0", nado_short: "0", source: Position::SOURCE_AERODROME_DIRECT, mellow_metadata: {})
    current = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: source,
      mellow_metadata: JSON.generate(mellow_metadata),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: asset0_amount,
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    )
    current.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    current.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      production_venue: "extended",
      target_short_eth: asset0_amount,
      combined_short_eth: "0",
      drift_eth: asset0_amount,
      inside_tolerance: false,
      extended_short_eth: "0",
      ethereal_short_eth: ethereal_short,
      nado_short_eth: nado_short
    )
    current
  end

  def base_env
    {
      "AERODROME_MAX_SHORT_ETH" => "1.5",
      "AERODROME_MAX_SHORT_NOTIONAL_USD" => "4000",
      "AERODROME_MIN_ORDER_NOTIONAL_USD" => "10"
    }
  end

  def live_env
    base_env.merge(
      "HEDGE_EMERGENCY_RESTORE_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false"
    )
  end

  class FakeExtendedVenue
    attr_reader :env

    def initialize(current_short: "0", open_orders_count: 0)
      @current_short = BigDecimal(current_short)
      @open_orders_count = open_orders_count
      @env = {}
    end

    def read_position(symbol:)
      return nil if @current_short.zero?

      { venue: "Extended", symbol: symbol, side: "short", short_size: @current_short.to_s("F") }
    end

    def open_short_preview(symbol:, size_eth:, max_slippage:)
      preview(action: "open_short", symbol: symbol, size_eth: size_eth, max_slippage: max_slippage)
    end

    def rebalance_preview(symbol:, delta_eth:, max_slippage:)
      delta = BigDecimal(delta_eth.to_s)
      preview(action: delta.negative? ? "decrease_short" : "increase_short", symbol: symbol, size_eth: delta.abs, max_slippage: max_slippage, reduce_only: delta.negative?)
    end

    def account_state
      { open_orders_count: @open_orders_count, margin_gate: { blockers: [] } }
    end

    def live_enabled? = true
    def market_metadata_diagnostics = { mark_price: "2000" }

    private

    def preview(action:, symbol:, size_eth:, max_slippage:, reduce_only: false)
      size = BigDecimal(size_eth.to_s)
      {
        payload: {
          action: action,
          symbol: symbol,
          side: reduce_only ? "buy" : "sell",
          extended_side: reduce_only ? "BUY" : "SELL",
          reduce_only: reduce_only,
          requested_size_eth: size.to_s("F"),
          rounded_size_eth: size.to_s("F"),
          estimated_notional_usd: (size * BigDecimal("2000")).to_s("F"),
          validation_blockers: [],
          max_slippage: max_slippage
        },
        blockers: [],
        warnings: []
      }
    end
  end

  class FakeLifecycle
    attr_reader :calls, :last_args

    def initialize(final_short: "1.0")
      @final_short = final_short
      @calls = 0
    end

    def run(**kwargs)
      @calls += 1
      @last_args = kwargs
      ExtendedMainnetLifecycleCheck::Result.new(
        "success",
        [],
        [],
        {
          exchange_order_id: "restore-order-1",
          orders_placed: 1,
          signatures_created: 1,
          readback_attempts: [ { attempt: 1, short_size: @final_short, side: "short", confirmed: true } ],
          final_status: "success"
        }
      )
    end
  end

  class FakeExposureRefresher
    def initialize(status: "synced", asset0: nil, asset1: nil)
      @status = status
      @asset0 = asset0
      @asset1 = asset1
    end

    def refresh
      before = snapshot
      if @status == "synced"
        @position.update!(asset0_amount: @asset0, asset1_amount: @asset1) if @asset0
        @position.reload
      end
      {
        status: @status,
        before: before,
        after: snapshot,
        blockers: @status == "synced" ? [] : [ "fresh Mellow exposure required before hedge sizing" ]
      }
    end

    def position=(value)
      @position = value
    end

    private

    def snapshot
      {
        asset0_amount: @position.asset0_amount&.to_s("F"),
        asset1_amount: @position.asset1_amount&.to_s("F")
      }
    end
  end
end
