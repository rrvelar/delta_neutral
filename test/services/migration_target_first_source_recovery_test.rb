require "test_helper"

class MigrationTargetFirstSourceRecoveryTest < ActiveSupport::TestCase
  test "dry-run builds Extended buy reduce-only close when Ethereal target exists" do
    result = recovery.run

    assert_equal "dry_run", result.status
    assert_empty result.blockers
    assert_equal "buy", result.receipt.fetch(:planned_side)
    assert_equal true, result.receipt.fetch(:reduce_only)
    assert_equal "0.977", result.receipt.fetch(:size_eth)
    assert_equal "1.0027", result.receipt.fetch(:expected_final_combined)
    assert_equal true, result.receipt.fetch(:expected_inside_tolerance)
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  test "dry-run blocks if Ethereal target is missing" do
    result = recovery(ethereal_short: "0").run

    assert_equal "dry_run", result.status
    assert_includes result.blockers, "Ethereal target short must be present"
  end

  test "dry-run blocks if Nado is not flat" do
    result = recovery(nado_short: "0.01").run

    assert_includes result.blockers, "Nado must be flat before source-close recovery"
  end

  test "dry-run blocks if Extended source short is zero" do
    result = recovery(extended_short: "0").run

    assert_includes result.blockers, "Extended source short must be present"
  end

  test "live mocked close confirms source recovery" do
    lifecycle = FakeLifecycle.new(final_short: "0")
    result = recovery(live: true, confirmation: MigrationTargetFirstSourceRecovery::CONFIRMATION, env: live_env, lifecycle: lifecycle).run

    assert_equal "SOURCE_CLOSE_RECOVERY_CONFIRMED", result.status
    assert_equal 1, lifecycle.calls
    assert_equal "close_only", lifecycle.last_args.fetch(:mode)
    assert_equal BigDecimal("0.977"), lifecycle.last_args.fetch(:size_eth)
    assert_equal 1, result.receipt.fetch(:orders_submitted)
    assert_equal 1, result.receipt.fetch(:signatures_created)
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  test "live blocks without exact confirmation and recovery gate" do
    lifecycle = FakeLifecycle.new(final_short: "0")
    result = recovery(live: true, confirmation: "wrong", env: live_env.except("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED"), lifecycle: lifecycle).run

    assert_equal "SOURCE_CLOSE_RECOVERY_BLOCKED", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{MigrationTargetFirstSourceRecovery::CONFIRMATION}"
    assert_includes result.blockers, "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be true"
    assert_equal 0, lifecycle.calls
    assert_equal 0, result.receipt.fetch(:orders_submitted)
    assert_equal 0, result.receipt.fetch(:signatures_created)
  end

  private

  def recovery(extended_short: "0.977", ethereal_short: "1.0027", nado_short: "0", live: false, confirmation: nil, env: {}, lifecycle: FakeLifecycle.new(final_short: "0"))
    MigrationTargetFirstSourceRecovery.new(
      position: position,
      from: "extended",
      to: "ethereal",
      dry_run: !live,
      live: live,
      confirmation: confirmation,
      env: env,
      extended_venue: FakeExtendedVenue.new(short: extended_short),
      ethereal_venue: FakeReadOnlyVenue.new(short: ethereal_short, venue: "Ethereal"),
      nado_venue: FakeReadOnlyVenue.new(short: nado_short, venue: "Nado"),
      fresh_target: FakeFreshTarget.new(target: "1.003478960323181"),
      lifecycle_factory: ->(_lifecycle_env, _venue) { lifecycle },
      receipt_dir: Rails.root.join("tmp/test-target-first-source-recovery-#{SecureRandom.hex(4)}")
    )
  end

  def position
    @position ||= begin
      current = Position.create!(
        user: users(:one),
        wallet: wallets(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        source: Position::SOURCE_MELLOW_AUTOPILOT,
        mellow_metadata: JSON.generate({ "hedge_ready" => true }),
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: "1.003478960323181",
        asset1_amount: "1000",
        asset0_price_usd: "2000",
        asset1_price_usd: "1",
        external_id: SecureRandom.hex(4),
        active: true
      )
      current.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
      current
    end
  end

  def live_env
    {
      "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED" => "true",
      "EXTENDED_LIVE_ENABLED" => "true",
      "EXTENDED_MAINNET_PROBE_ENABLED" => "true",
      "EXTENDED_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "false"
    }
  end

  class FakeFreshTarget
    def initialize(target:)
      @target = target
    end

    def resolve(refresh_if_stale:)
      {
        status: "ok",
        target_short_eth: BigDecimal(@target),
        target_source: "current_share_token_resolver",
        exposure_source: "current_share_token_resolver",
        exposure_refreshed_at: Time.current.iso8601,
        exposure_stale: false,
        blockers: [],
        orders_submitted: 0,
        signatures_created: 0
      }
    end
  end

  class FakeReadOnlyVenue
    def initialize(short:, venue:)
      @short = BigDecimal(short)
      @venue = venue
    end

    def read_position(symbol:)
      return nil if @short.zero?

      { venue: @venue, symbol: symbol, side: "short", short_size: @short.to_s("F") }
    end

    def account_state
      { open_orders_count: 0 }
    end
  end

  class FakeExtendedVenue < FakeReadOnlyVenue
    attr_reader :env

    def initialize(short:)
      super(short: short, venue: "Extended")
      @env = {}
    end

    def close_preview(symbol:, size_eth:)
      size = BigDecimal(size_eth.to_s)
      {
        payload: {
          action: "close_short",
          symbol: symbol,
          side: "buy",
          extended_side: "BUY",
          reduce_only: true,
          requested_size_eth: size.to_s("F"),
          rounded_size_eth: size.to_s("F"),
          estimated_notional_usd: (size * BigDecimal("2000")).to_s("F"),
          validation_blockers: []
        },
        blockers: [],
        warnings: []
      }
    end

    def live_enabled? = true
  end

  class FakeLifecycle
    attr_reader :calls, :last_args

    def initialize(final_short:)
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
          exchange_order_id: "extended-close-1",
          orders_placed: 1,
          signatures_created: 1,
          readback_attempts: [ { attempt: 1, short_size: @final_short, confirmed: true } ],
          final_status: "success"
        }
      )
    end
  end
end
