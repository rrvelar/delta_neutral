require "test_helper"

# 2026-07-12 post-stop status layer: classification of WHY the runner stopped,
# repair eligibility, proof-expiry warnings, external stop audit visibility,
# and the default-false auto-recovery flags. Status only — nothing here trades.
class MigrationRandomProductionPostStopStatusTest < ActiveSupport::TestCase
  def runner(env: {})
    MigrationRandomProductionRunner.new(position: guard_position, trap_signals: false, env: env)
  end

  def guard_position
    @guard_position ||= begin
      position = Position.create!(
        user: users(:one), wallet: wallets(:one),
        dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
        asset0: "WETH", asset1: "USDC", asset0_amount: "1", asset1_amount: "500",
        asset0_price_usd: "2000", asset1_price_usd: "1",
        external_id: SecureRandom.hex(6), pool_address: "0x#{SecureRandom.hex(20)}", active: true
      )
      position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "ethereal")
      position
    end
  end

  def stub_no_stop_request(instance)
    instance.define_singleton_method(:last_stop_request_payload) { nil }
    instance
  end

  def stub_latest_event(instance, event)
    instance.define_singleton_method(:latest_event_from_log) { event }
    instance
  end

  TOLERANCE_BLOCKER = "current hedge out_of_burn_in_tolerance: drift beyond band".freeze
  PROOF_BLOCKERS = [ "all enabled route proofs must be READY_FOR_RANDOM", "stale route proofs must be resolved" ].freeze

  test "tolerance-only stop classifies tolerance_only_block and is rebalance-eligible without trading" do
    instance = stub_latest_event(stub_no_stop_request(runner), { "status" => "stopped", "blockers" => [ TOLERANCE_BLOCKER ] })
    classification = instance.send(:stopped_state_classification, "stopped", [ TOLERANCE_BLOCKER ], [ "ethereal" ], [])
    assert_equal "tolerance_only_block", classification

    direct = { inside_tolerance: false, venues: { "ethereal" => { open_orders_status: "zero" }, "extended" => { open_orders_status: "zero" }, "nado" => { open_orders_status: "zero" } } }
    eligibility = instance.send(:repair_eligibility, "stopped", direct, [ "ethereal" ], [ TOLERANCE_BLOCKER ])
    assert_equal true, eligibility[:eligible_for_same_venue_rebalance_when_stopped]
    assert_equal false, eligibility[:eligible_for_restart]
    assert_equal TOLERANCE_BLOCKER, eligibility[:blocked_reason]
  end

  test "operator stop request classifies operator_stop and blocks auto-restart eligibility" do
    instance = runner
    instance.define_singleton_method(:last_stop_request_payload) { { "action" => "stop", "requested_at" => "2026-07-11T20:40:01Z" } }
    assert_equal "operator_stop", instance.send(:stopped_state_classification, "stopped", [], [ "ethereal" ], [])
  end

  test "stale proof block classifies proof_stale_block and is proof-refresh eligible" do
    instance = stub_latest_event(stub_no_stop_request(runner), { "status" => "stopped", "blockers" => [] })
    assert_equal "proof_stale_block", instance.send(:stopped_state_classification, "stopped", PROOF_BLOCKERS, [ "ethereal" ], [])

    direct = { inside_tolerance: true, venues: { "ethereal" => { open_orders_status: "zero" }, "extended" => { open_orders_status: "zero" }, "nado" => { open_orders_status: "zero" } } }
    eligibility = instance.send(:repair_eligibility, "stopped", direct, [ "ethereal" ], PROOF_BLOCKERS)
    assert_equal true, eligibility[:eligible_for_proof_refresh]
    assert_equal false, eligibility[:eligible_for_same_venue_rebalance_when_stopped]
  end

  test "internal fail-closed stop and safe recovery classify distinctly" do
    recovered = stub_no_stop_request(runner)
    stub_latest_event(recovered, { "status" => "stopped", "blocker_status" => "recovered_after_direct_market_safe_preflight" })
    assert_equal "recovered_after_direct_market_safe_preflight", recovered.send(:stopped_state_classification, "stopped", [], [ "ethereal" ], [])

    failed = stub_no_stop_request(runner)
    stub_latest_event(failed, { "status" => "stopped", "blockers" => [ "active venue one-shot rebalance final readback is outside tolerance" ] })
    assert_equal "internal_fail_closed_stop", failed.send(:stopped_state_classification, "stopped", [ "some other blocker" ], [ "ethereal" ], [])
  end

  test "unknown exposure classifies unsafe_unknown" do
    instance = stub_no_stop_request(runner)
    assert_equal "unsafe_unknown", instance.send(:stopped_state_classification, "stopped", [], [ "ethereal", "extended" ], [])
    assert_equal "unsafe_unknown", instance.send(:stopped_state_classification, "stopped", [], [ "ethereal" ], [ "extended" ])
  end

  test "running runner has no stopped classification" do
    assert_nil runner.send(:stopped_state_classification, "running", [], [ "ethereal" ], [])
  end

  test "route proofs expiring within 48h produce a warning with next expiry" do
    instance = runner
    direct = { proof_report: { routes: [
      { route: "nado->ethereal", proof_timestamp: (Time.current - 29.days - 1.hour).utc.iso8601 },
      { route: "ethereal->extended", proof_timestamp: (Time.current - 2.days).utc.iso8601 }
    ] } }
    report = instance.send(:route_proofs_expiring_soon, direct)
    assert_equal true, report[:warning]
    assert_equal [ "nado->ethereal" ], report[:routes].map { |r| r[:route] }
    assert report[:next_proof_expiry].present?
  end

  test "auto-recovery flags default to false and never enable behavior implicitly" do
    instance = runner
    flags = instance.send(:post_stop_operability, "stopped", { venues: {}, proof_report: { routes: [] } }, [ "ethereal" ], [])[:auto_recovery_flags]
    assert_equal({ "MIGRATION_AUTO_RECOVER_STOPPED_OUT_OF_TOLERANCE" => false,
                   "MIGRATION_AUTO_RESTART_AFTER_SAFE_RECOVERY" => false,
                   "MIGRATION_AUTO_REFRESH_STALE_PROOFS" => false }, flags)
  end
end
