require "test_helper"

class NadoHedgeExecutionServiceTest < ActiveSupport::TestCase
  test "rebalance short respects explicit require confirmation false outside migration" do
    service = ConfirmationBypassNadoService.new
    result = service.rebalance_short(
      position: mellow_position,
      delta_eth: "0.1",
      current_position: { size: BigDecimal("-0.9"), short_size: BigDecimal("0.9"), margin_mode: "isolated" },
      confirmation: nil,
      max_slippage: "0.01",
      require_confirmation: false
    )

    assert_equal "submitted_and_confirmed", result.status, result.blockers.inspect
    assert_empty result.blockers.grep(/submitted confirmation/)
    assert_equal 1, service.sign_calls
  end

  test "rebalance short still requires confirmation by default for manual live path" do
    service = ConfirmationBypassNadoService.new
    result = service.rebalance_short(
      position: mellow_position,
      delta_eth: "0.1",
      current_position: { size: BigDecimal("-0.9"), short_size: BigDecimal("0.9"), margin_mode: "isolated" },
      confirmation: nil,
      max_slippage: "0.01"
    )

    assert_equal "blocked_before_submit", result.status
    assert_includes result.blockers, "submitted confirmation must equal #{ConfirmationVenue::CONFIRMATION}"
    assert_equal 0, service.sign_calls
  end

  test "accepted digest stale readback confirms late when final readback is inside tolerance" do
    service = ConfirmationBypassNadoService.new(late_position: { size: BigDecimal("-1.18"), short_size: BigDecimal("1.18"), margin_mode: "isolated" })
    result = service.reconcile_pending_result(
      NadoHedgeExecutionService::Result.new(
        "submitted_but_readback_pending",
        [],
        [],
        {
          exchange_order_id: "0x79ac4726d931064c75c606055ed54eacc6944d3f059d098aecc99920c72ad55e",
          pre_submit_readback: { size: "-1.11" },
          action_plan: { expected_after_short_eth: "1.180225", delta_eth: "0.070225" },
          post_submit_readback_poll_attempts: [ { attempt: 1, readback: { size: "-1.11" }, confirmed: false } ],
          final_status: "submitted_but_readback_pending",
          manual_action_required: true
        }
      ),
      expected_short: "1.180225",
      target_short: "1.157",
      tolerance_eth: "0.0347"
    )

    assert_equal "rebalance_confirmed_late", result.status
    assert_equal "REBALANCE_CONFIRMED_LATE", result.receipt.fetch(:final_status)
    assert_equal "CONFIRMED_LATE_BY_RECONCILIATION", result.receipt.fetch(:lifecycle_state)
    assert_equal true, result.receipt.fetch(:readback_confirmed)
    assert_equal false, result.receipt.fetch(:manual_action_required)
    assert_equal "0x79ac4726d931064c75c606055ed54eacc6944d3f059d098aecc99920c72ad55e", result.receipt.fetch(:exchange_order_id)
    assert_empty result.blockers
  end

  test "accepted digest stays pending when later readback is outside tolerance" do
    service = ConfirmationBypassNadoService.new(late_position: { size: BigDecimal("-1.11"), short_size: BigDecimal("1.11"), margin_mode: "isolated" })
    result = service.reconcile_pending_result(
      NadoHedgeExecutionService::Result.new(
        "submitted_but_readback_pending",
        [],
        [],
        {
          exchange_order_id: "0x#{"34" * 32}",
          action_plan: { expected_after_short_eth: "1.180225", delta_eth: "0.070225" },
          final_status: "submitted_but_readback_pending"
        }
      ),
      expected_short: "1.180225",
      target_short: "1.157",
      tolerance_eth: "0.0347"
    )

    assert_equal "submitted_pending_readback", result.status
    assert_equal "REBALANCE_REQUIRES_RECHECK", result.receipt.fetch(:final_status)
    assert_equal "SUBMITTED_PENDING_READBACK", result.receipt.fetch(:lifecycle_state)
    assert_equal false, result.receipt.fetch(:readback_confirmed)
    assert_equal true, result.receipt.fetch(:manual_action_required)
    assert_equal "0x#{"34" * 32}", result.receipt.fetch(:exchange_order_id)
  end

  private

  def mellow_position
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
      external_id: "mellow:#{SecureRandom.hex(4)}",
      active: true,
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: "1",
        user_usdc_exposure: "1000",
        user_total_value_usd: "3000"
      }.to_json
    ).tap do |position|
      position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "nado")
    end
  end

  class ConfirmationVenue
    CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_ORDERS".freeze

    def live_flag_enabled?
      true
    end

    def live_confirmation_phrase
      CONFIRMATION
    end

    def raw_positions_present_but_unnormalized?
      false
    end
  end

  class ConfirmationBypassNadoService < NadoHedgeExecutionService
    attr_reader :sign_calls

    def initialize(late_position: nil)
      @env = {}
      @venue = ConfirmationVenue.new
      @now = -> { Time.zone.parse("2026-06-01 12:00:00 UTC") }
      @sign_calls = 0
      @late_position = late_position
    end

    def build_order_preview(position:, action:, size_eth:, max_slippage:, current_position: nil)
      {
        ok: true,
        typed_data: { message: {} },
        summary: {
          side: "sell",
          reduce_only: false,
          rounded_size_eth: BigDecimal(size_eth.to_s).abs.to_s("F"),
          estimated_notional_usd: "200",
          expected_after_short_eth: "1.0"
        },
        blockers: [],
        warnings: []
      }
    end

    def sign(_typed_data, order:, action:)
      @sign_calls += 1
      { status: "signed", signature: "0xsigned" }
    end

    def post_execute(_payload)
      { status: "ok" }
    end

    def submit_payload(order:, signature:)
      { order: order, signature: signature }
    end

    def parse_submit_response(_response)
      { status: "submitted", message: "accepted", exchange_order_id: "0x#{"12" * 32}" }
    end

    def poll_post_submit_readback(action:, expected_short:)
      {
        attempts: [ { attempt: 1, confirmed: true } ],
        position: { size: -expected_short, short_size: expected_short, margin_mode: "isolated" },
        confirmed: true
      }
    end

    def read_position
      @late_position || { size: BigDecimal("-1.0"), short_size: BigDecimal("1.0"), margin_mode: "isolated" }
    end

    def signer_url
      "http://signer.test"
    end

    def signer_available?
      true
    end

    def submit_base_url
      "http://nado.test"
    end

    def subaccount
      "0xsub"
    end
  end
end
