require "test_helper"
require "rake"

class DashboardTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("dashboard:refresh_all_position_snapshots")
    Rake::Task["dashboard:refresh_all_position_snapshots"].reenable
    Rake::Task["dashboard:refresh_position_snapshot"].reenable if Rake::Task.task_defined?("dashboard:refresh_position_snapshot")
    Rake::Task["dashboard:production_health"].reenable if Rake::Task.task_defined?("dashboard:production_health")
    Rake::Task["dashboard:production_smoke"].reenable if Rake::Task.task_defined?("dashboard:production_smoke")
  end

  test "refresh all position snapshots runs all read-only refreshers" do
    position = Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.random_number(1_000_000).to_s,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    )
    Hedge.create!(position: position, target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    calls = []

    DashboardSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :position, snapshot_result(11)) }) do
      RewardsFeesSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :rewards_fees, snapshot_result(12)) }) do
        HedgeAccountingSnapshotRefresh.stub(:new, ->(position:) { refresher(calls, :hedge_accounting, snapshot_result(13)) }) do
          original_position_id = ENV["position_id"]
          ENV["position_id"] = position.id.to_s
          begin
            out, = capture_io { Rake::Task["dashboard:refresh_all_position_snapshots"].invoke }

            assert_equal %i[position rewards_fees hedge_accounting], calls
            assert_match '"orders_submitted": 0', out
            assert_match '"signatures_created": 0', out
          ensure
            ENV["position_id"] = original_position_id
          end
        end
      end
    end
  end

  test "refresh position snapshot task does not deactivate active production position" do
    position = aerodrome_position
    snapshot = position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "1.6",
      combined_short_eth: "1.6",
      drift_eth: "0",
      inside_tolerance: true,
      ethereal_short_eth: "1.6",
      extended_short_eth: "0",
      nado_short_eth: "0"
    )

    DashboardSnapshotRefresh.stub(:new, ->(position:) { refresher([], :position, snapshot) }) do
      original_position_id = ENV["position_id"]
      ENV["position_id"] = position.id.to_s
      begin
        out, = capture_io { Rake::Task["dashboard:refresh_position_snapshot"].invoke }

        assert_match '"orders_submitted": 0', out
        assert_match '"signatures_created": 0', out
      ensure
        ENV["position_id"] = original_position_id
      end
    end

    assert_predicate position.reload, :active?
    assert_predicate position.hedge.reload, :active?
  end

  test "production health task outputs read-only counters" do
    position = aerodrome_position
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.8",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      extended_auto_enabled: true,
      signer_status: "ok",
      signer_checked_at: Time.current,
      open_orders_count_extended: 0
    )
    position.create_position_rewards_fees_snapshot!(refreshed_at: Time.current, refresh_status: "ok")
    position.create_position_hedge_accounting_snapshot!(refreshed_at: Time.current, refresh_status: "ok", venue: "extended")

    with_position_id(position.id) do
      out, = capture_io { Rake::Task["dashboard:production_health"].invoke }
      payload = JSON.parse(out)

      assert_equal 0, payload.fetch("orders_submitted")
      assert_equal 0, payload.fetch("signatures_created")
      assert_equal "active", payload.dig("current_snapshot_summary", "exposure", "extended_status")
    end
  end

  test "production smoke outputs expected read-only diagnostics" do
    position = aerodrome_position
    mellow = { status: "ok", exposure_source: "current_share_token_resolver", successful_method: "previewMint(uint256)" }
    readiness = {
      extended_current_short_eth: "0.8",
      target_short_eth: "0.8",
      within_tolerance: true,
      continuous_auto_ready: true,
      planned_auto_action: "no_op",
      action_suppressed_reason: nil,
      auto_can_act: false,
      min_rebalance_size_eth: "0.03",
      cooldown_remaining_seconds: 0,
      consecutive_outside_tolerance_count: 0,
      strong_drift_bypass_used: false,
      blockers: []
    }

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(mellow) }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "ok", payload.fetch("mellow_current_exposure_status")
          assert_equal "current_share_token_resolver", payload.fetch("current_mellow_exposure_source")
          assert_equal "previewMint(uint256)", payload.fetch("successful_method")
          assert_equal "ok", payload.fetch("current_resolver_status")
          assert_equal "previewMint(uint256)", payload.fetch("current_resolver_successful_method")
          assert_equal "0.8", payload.fetch("current_target_short_eth")
          assert_equal true, payload.fetch("extended_auto_within_tolerance")
          assert_equal "no_op", payload.fetch("extended_auto_planned_action")
          assert_equal "In tolerance", payload.fetch("dashboard_header_status")
          assert_equal "HEALTHY", payload.fetch("production_health_status")
          assert_equal "inside tolerance", payload.fetch("production_health_reason")
          assert_equal "No-op / inside tolerance", payload.fetch("hedge_control_action_label")
          assert_equal true, payload.fetch("hedge_control_uses_readiness_preview")
          assert_equal false, payload.fetch("stale_preview_warning_present")
          assert_equal [], payload.fetch("mismatch_warnings")
          assert_equal "no_op", payload.dig("active_auto_readiness", "planned_auto_action")
          assert_equal payload.fetch("active_auto_readiness"), payload.fetch("extended_auto_readiness")
          assert_equal 0, payload.fetch("orders_submitted")
          assert_equal 0, payload.fetch("signatures_created")
          assert_equal true, payload.fetch("tx_hash_onboarding_route_exists")
        end
      end
    end
  end

  test "production smoke uses Ethereal active venue readiness after migration" do
    position = aerodrome_position
    position.hedge.update!(execution_venue: "ethereal")
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "ethereal",
      selected_venue: "ethereal",
      target_short_eth: "0.88",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.0264",
      combined_short_eth: "0.8829",
      drift_eth: "-0.0029",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0.8829",
      nado_short_eth: "0",
      extended_status: "flat",
      ethereal_status: "active",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      signer_status: "ok",
      signer_checked_at: Time.current
    )
    mellow = { status: "ok", exposure_source: "current_share_token_resolver", successful_method: "previewMint(uint256)" }
    readiness = {
      execution_venue: "ethereal",
      active_auto_venue: "ethereal",
      active_current_short_eth: "0.8829",
      active_target_short_eth: "0.88",
      active_drift_eth: "-0.0029",
      active_tolerance_eth: "0.0264",
      active_within_tolerance: true,
      active_planned_auto_action: "no_op",
      active_auto_enabled: false,
      active_live_enabled: true,
      active_auto_ready: false,
      active_auto_blockers: [ "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true" ],
      active_auto_warnings: [ "Ethereal continuous auto is disabled; inside-tolerance production health should be stable but manual." ],
      current_short_eth: "0.8829",
      ethereal_current_short_eth: "0.8829",
      target_short_eth: "0.88",
      within_tolerance: true,
      continuous_auto_ready: false,
      planned_auto_action: "no_op",
      blockers: [ "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true" ],
      warnings: []
    }

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(mellow) }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "ethereal", payload.fetch("production_venue")
          assert_equal "ethereal", payload.fetch("active_auto_venue")
          assert_equal "0.8829", payload.fetch("active_current_short_eth")
          assert_equal "0.8829", payload.fetch("ethereal_current_short_eth")
          assert_equal true, payload.fetch("active_within_tolerance")
          assert_equal "no_op", payload.fetch("active_planned_auto_action")
          assert_equal "HEALTHY", payload.fetch("production_health_status")
          assert_equal "inside tolerance", payload.fetch("production_health_reason")
          assert_includes payload.fetch("active_auto_blockers"), "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true"
          assert_not_includes payload.fetch("active_auto_blockers"), "EXTENDED_AUTO_REBALANCE_ENABLED must be true"
          assert_equal "0.8829", payload.dig("combined_hedge", "ethereal_short_eth")
          assert_equal true, payload.dig("combined_hedge", "combined_inside_tolerance")
          assert_equal 0, payload.fetch("orders_submitted")
          assert_equal 0, payload.fetch("signatures_created")
        end
      end
    end
  end

  test "production smoke uses active readiness current short fallback when venue alias is omitted" do
    position = aerodrome_position
    position.hedge.update!(execution_venue: "ethereal")
    mellow = { status: "ok", exposure_source: "current_share_token_resolver", successful_method: "previewMint(uint256)" }
    readiness = {
      execution_venue: "ethereal",
      active_auto_venue: "ethereal",
      current_short_eth: "0.8829",
      target_short_eth: "0.898",
      drift_eth: "0.0151",
      tolerance_eth: "0.02694",
      within_tolerance: true,
      planned_auto_action: "no_op",
      active_auto_enabled: false,
      active_live_enabled: true,
      active_auto_ready: false,
      blockers: [ "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true" ],
      warnings: []
    }

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(mellow) }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "0.8829", payload.fetch("active_current_short_eth")
          assert_equal "0.8829", payload.fetch("ethereal_current_short_eth")
          assert_equal true, payload.fetch("active_within_tolerance")
          assert_equal "HEALTHY", payload.fetch("production_health_status")
          assert_includes payload.fetch("active_auto_blockers"), "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED must be true"
          assert_equal 0, payload.fetch("orders_submitted")
          assert_equal 0, payload.fetch("signatures_created")
        end
      end
    end
  end

  test "production smoke reports Nado production venue fail closed" do
    position = aerodrome_position
    position.hedge.update!(execution_venue: "nado")
    mellow = { status: "ok", exposure_source: "current_share_token_resolver", successful_method: "previewMint(uint256)" }
    readiness = {
      execution_venue: "nado",
      active_auto_venue: "nado",
      active_current_short_eth: "0",
      active_target_short_eth: "0.9",
      active_within_tolerance: false,
      active_planned_auto_action: "increase_short",
      active_auto_ready: false,
      active_auto_blockers: [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ],
      target_short_eth: "0.9",
      within_tolerance: false,
      planned_auto_action: "increase_short",
      blockers: [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ],
      warnings: []
    }

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(mellow) }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "nado", payload.fetch("production_venue")
          assert_equal "nado", payload.fetch("active_auto_venue")
          assert_equal "BLOCKED", payload.fetch("production_health_status")
          assert_includes payload.fetch("active_auto_blockers"), "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true"
          assert_equal 0, payload.fetch("orders_submitted")
          assert_equal 0, payload.fetch("signatures_created")
        end
      end
    end
  end

  test "production smoke reports Nado production venue healthy when inside tolerance while auto is disabled" do
    position = aerodrome_position
    position.hedge.update!(execution_venue: "nado")
    mellow = { status: "ok", exposure_source: "current_share_token_resolver", successful_method: "previewMint(uint256)" }
    readiness = {
      execution_venue: "nado",
      active_auto_venue: "nado",
      active_current_short_eth: "1.11",
      active_target_short_eth: "1.11",
      active_drift_eth: "0",
      active_tolerance_eth: "0.0333",
      active_within_tolerance: true,
      active_planned_auto_action: "no_op",
      active_auto_enabled: false,
      active_live_enabled: false,
      active_auto_ready: false,
      active_auto_blockers: [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ],
      active_auto_warnings: [ "Nado continuous auto is disabled; inside-tolerance production health should be stable but manual." ],
      current_short_eth: "1.11",
      nado_current_short_eth: "1.11",
      target_short_eth: "1.11",
      within_tolerance: true,
      continuous_auto_ready: false,
      planned_auto_action: "no_op",
      blockers: [ "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true" ],
      warnings: []
    }

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(mellow) }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "nado", payload.fetch("production_venue")
          assert_equal "nado", payload.fetch("active_auto_venue")
          assert_equal "1.11", payload.fetch("active_current_short_eth")
          assert_equal true, payload.fetch("active_within_tolerance")
          assert_equal "HEALTHY", payload.fetch("production_health_status")
          assert_equal "inside tolerance", payload.fetch("production_health_reason")
          assert_includes payload.fetch("active_auto_blockers"), "AERODROME_NADO_AUTO_REBALANCE_ENABLED must be true"
          assert_equal "no_op", payload.dig("active_auto_readiness", "planned_auto_action")
          assert_equal payload.fetch("active_auto_readiness"), payload.fetch("extended_auto_readiness")
          assert_equal 0, payload.fetch("orders_submitted")
          assert_equal 0, payload.fetch("signatures_created")
        end
      end
    end
  end

  test "production smoke does not report healthy when another venue is also open" do
    position = aerodrome_position
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0.5",
      ethereal_short_eth: "0.3",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "active",
      nado_status: "flat"
    )
    readiness = readiness_payload(within_tolerance: true, current_short: "0.5", target: "0.8")

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(status: "ok") }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "OVERHEDGED", payload.fetch("production_health_status")
          assert_match(/multiple venues/, payload.fetch("production_health_reason"))
        end
      end
    end
  end

  test "production smoke does not report healthy when combined hedge is outside tolerance" do
    position = aerodrome_position
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.91",
      drift_eth: "-0.11",
      inside_tolerance: false,
      extended_short_eth: "0.91",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat"
    )
    readiness = readiness_payload(within_tolerance: true, current_short: "0.91", target: "0.8")

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(status: "ok") }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "ACTION REQUIRED", payload.fetch("production_health_status")
          assert_equal "combined hedge outside tolerance", payload.fetch("production_health_reason")
        end
      end
    end
  end

  test "production smoke reports healthy when single venue short is inside tolerance" do
    position = aerodrome_position
    position.create_position_dashboard_snapshot!(
      refreshed_at: Time.current,
      refresh_status: "ok",
      stale: false,
      production_venue: "nado",
      selected_venue: "nado",
      target_short_eth: "0.8",
      tolerance_ratio: "0.03",
      tolerance_abs_eth: "0.024",
      combined_short_eth: "0.8",
      drift_eth: "0",
      inside_tolerance: true,
      extended_short_eth: "0",
      ethereal_short_eth: "0",
      nado_short_eth: "0.8",
      extended_status: "flat",
      ethereal_status: "flat",
      nado_status: "active"
    )
    readiness = readiness_payload(venue: "nado", within_tolerance: true, current_short: "0.8", target: "0.8")

    MellowCurrentExposureResolver.stub(:new, ->(position:) { resolver_result(status: "ok") }) do
      HedgeVenueAutoReadiness.stub(:new, -> { resolver_result(readiness, method_name: :report) }) do
        with_position_id(position.id) do
          out, = capture_io { Rake::Task["dashboard:production_smoke"].invoke }
          payload = JSON.parse(out)

          assert_equal "HEALTHY", payload.fetch("production_health_status")
          assert_equal "inside tolerance", payload.fetch("production_health_reason")
        end
      end
    end
  end

  private

  def aerodrome_position
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      external_id: SecureRandom.random_number(1_000_000).to_s,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      pool_address: "0x#{SecureRandom.hex(20)}",
      active: true
    ).tap do |position|
      Hedge.create!(position: position, target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end

  SnapshotResult = Struct.new(:id, :refresh_status, keyword_init: true)

  def snapshot_result(id)
    SnapshotResult.new(id: id, refresh_status: "ok")
  end

  def refresher(calls, name, snapshot)
    Object.new.tap do |object|
      object.define_singleton_method(:refresh) do
        calls << name
        snapshot
      end
    end
  end

  def resolver_result(result, method_name: :resolve)
    Object.new.tap do |object|
      object.define_singleton_method(method_name) do |**|
        result
      end
    end
  end

  def readiness_payload(venue: "extended", within_tolerance:, current_short:, target:)
    {
      execution_venue: venue,
      active_auto_venue: venue,
      active_current_short_eth: current_short,
      active_target_short_eth: target,
      active_within_tolerance: within_tolerance,
      active_planned_auto_action: "no_op",
      target_short_eth: target,
      within_tolerance: within_tolerance,
      continuous_auto_ready: true,
      planned_auto_action: "no_op",
      action_suppressed_reason: nil,
      auto_can_act: false,
      min_rebalance_size_eth: "0.03",
      cooldown_remaining_seconds: 0,
      consecutive_outside_tolerance_count: 0,
      strong_drift_bypass_used: false,
      blockers: []
    }
  end

  def with_position_id(position_id)
    original_position_id = ENV["position_id"]
    ENV["position_id"] = position_id.to_s
    yield
  ensure
    original_position_id.nil? ? ENV.delete("position_id") : ENV["position_id"] = original_position_id
  end
end
