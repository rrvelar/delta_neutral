require "test_helper"

# Phase-3 hardening (2026-07-12): authoritative Nado close confirmation.
# A reduce-only Nado close may anchor the double-exposure end at the venue's
# canonical terminal execution evidence (NadoExecutionConfirmation gateway or
# archive order row) — never on submit/accept alone — and everything ambiguous
# falls back fail-closed to the position readback.
class NadoCloseAuthoritativeConfirmationTest < ActiveSupport::TestCase
  ENABLED_ENV = { "NADO_CLOSE_EXECUTION_CONFIRMATION_ENABLED" => "true" }.freeze
  DIGEST = "0x#{'a' * 64}".freeze

  test "confirmed close execution produces an executor-compatible reduce-only payload" do
    service = NadoHedgeExecutionService.new(env: ENABLED_ENV)
    confirmation = { status: "confirmed", confirmed: true, confirmed_at: "2026-07-12T06:00:01Z", source: "gateway_order", digest: DIGEST }
    NadoExecutionConfirmation.stub(:confirm_digest, confirmation) do
      result = service.send(:close_execution_confirmation, action: "close", parsed: { status: "submitted", exchange_order_id: DIGEST }, size_eth: "1.6")
      assert_equal true, result[:confirmed]
      payload = service.send(:close_fill_confirmation_payload, action: "close", close_execution: result, order: { summary: { rounded_size_eth: "1.6" } }, parsed: { exchange_order_id: DIGEST })
      assert_equal true, payload[:confirmed]
      assert_equal true, payload[:reduce_only]
      assert_equal "nado_execution_confirmation:gateway_order", payload[:source]
      assert_equal "2026-07-12T06:00:01Z", payload[:confirmed_at]
      assert_equal DIGEST, payload[:digest]
    end
  end

  test "flag off never confirms" do
    service = NadoHedgeExecutionService.new(env: {})
    NadoExecutionConfirmation.stub(:confirm_digest, ->(**) { flunk "must not be called when disabled" }) do
      assert_nil service.send(:close_execution_confirmation, action: "close", parsed: { status: "submitted", exchange_order_id: DIGEST }, size_eth: "1.6")
    end
  end

  test "unconfirmed or pending execution row fails closed to nil" do
    service = NadoHedgeExecutionService.new(env: ENABLED_ENV)
    NadoExecutionConfirmation.stub(:confirm_digest, { status: "unconfirmed", confirmed: false, confirmed_at: nil }) do
      assert_nil service.send(:close_execution_confirmation, action: "close", parsed: { status: "submitted", exchange_order_id: DIGEST }, size_eth: "1.6")
    end
  end

  test "submit-accepted alone with invalid or missing digest never confirms" do
    service = NadoHedgeExecutionService.new(env: ENABLED_ENV)
    assert_nil service.send(:close_execution_confirmation, action: "close", parsed: { status: "submitted", exchange_order_id: "not-a-digest" }, size_eth: "1.6")
    assert_nil service.send(:close_execution_confirmation, action: "close", parsed: { status: "unknown", exchange_order_id: DIGEST }, size_eth: "1.6")
  end

  test "non-close actions never confirm" do
    service = NadoHedgeExecutionService.new(env: ENABLED_ENV)
    NadoExecutionConfirmation.stub(:confirm_digest, { status: "confirmed", confirmed: true, confirmed_at: "2026-07-12T06:00:01Z", source: "gateway_order" }) do
      assert_nil service.send(:close_execution_confirmation, action: "open", parsed: { status: "submitted", exchange_order_id: DIGEST }, size_eth: "1.6")
    end
  end

  test "confirmation lookup errors fail closed to nil" do
    service = NadoHedgeExecutionService.new(env: ENABLED_ENV)
    NadoExecutionConfirmation.stub(:confirm_digest, ->(**) { raise "gateway down" }) do
      assert_nil service.send(:close_execution_confirmation, action: "close", parsed: { status: "submitted", exchange_order_id: DIGEST }, size_eth: "1.6")
    end
  end

  # --- executor anchoring semantics ---

  def executor
    HedgeVenueMigrationExecutor.new(env: {})
  end

  def nado_fill(confirmed_at: "2026-07-12T06:00:02.500000Z")
    { confirmed: true, source: "nado_execution_confirmation:gateway_order", reduce_only: true,
      confirmed_at: confirmed_at, digest: DIGEST, order_status: "confirmed" }
  end

  def base_receipt(flat: true)
    {
      migration_sequence: "target_first",
      source_flat_after: flat,
      target_leg_accepted_at: "2026-07-12T06:00:00.000000Z",
      source_close_submit_finished_at: "2026-07-12T06:00:02.000000Z",
      source_close_position_readback_confirmed_at: "2026-07-12T06:00:31.000000Z"
    }
  end

  test "nado terminal execution anchors the double-exposure end under 5s and final readback still gates" do
    receipt = base_receipt(flat: true)
    executor.send(:apply_authoritative_source_close_confirmation!, receipt, { close_fill_confirmation: nado_fill })
    executor.send(:compute_double_exposure_latency!, receipt)

    assert_equal "nado_execution_confirmation:gateway_order", receipt[:double_exposure_end_source]
    assert_equal "2026-07-12T06:00:02.500000Z", receipt[:source_close_flat_confirmed_at]
    assert_equal DIGEST, receipt[:nado_close_tx_hash]
    assert_equal "confirmed", receipt[:nado_close_tx_status]
    assert_equal true, receipt[:source_close_authoritative_confirmation_agreement]
    assert_operator BigDecimal(receipt[:double_exposure_seconds].to_s), :<, BigDecimal("5")
  end

  test "nado execution confirmed but final readback not flat keeps the slow window and flags disagreement" do
    receipt = base_receipt(flat: false)
    executor.send(:apply_authoritative_source_close_confirmation!, receipt, { close_fill_confirmation: nado_fill })

    assert_equal false, receipt[:source_close_fill_readback_agreement]
    assert_equal false, receipt[:source_close_authoritative_confirmation_agreement]
    assert_equal "position_readback", receipt[:double_exposure_end_source]
    assert_nil receipt[:source_close_flat_confirmed_at]
  end

  test "missing confirmation falls back to position readback" do
    receipt = base_receipt(flat: true)
    executor.send(:apply_authoritative_source_close_confirmation!, receipt, { close_fill_confirmation: nil })
    executor.send(:compute_double_exposure_latency!, receipt)

    assert_equal "position_readback", receipt[:double_exposure_end_source]
    assert_equal "2026-07-12T06:00:31.000000Z", receipt[:source_close_flat_confirmed_at]
    assert_operator BigDecimal(receipt[:double_exposure_seconds].to_s), :>, BigDecimal("5")
  end

  test "non-reduce-only confirmation is rejected by the executor validator" do
    receipt = base_receipt(flat: true)
    fill = nado_fill.merge(reduce_only: false)
    executor.send(:apply_authoritative_source_close_confirmation!, receipt, { close_fill_confirmation: fill })

    assert_equal "position_readback", receipt[:source_close_confirmation_source]
    assert_equal "position_readback", receipt[:double_exposure_end_source]
  end
end
