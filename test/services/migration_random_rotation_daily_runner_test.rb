require "test_helper"

class MigrationRandomRotationDailyRunnerTest < ActiveSupport::TestCase
  test "daily dry-run plans when env gate is false" do
    position = migration_position
    result = runner(env: { "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "false" }).call(position_id: position.id, force: true)

    assert_equal "ok", result.status
    assert_equal 1, result.positions.size
    assert_equal 0, result.orders_submitted
    assert_equal 0, result.signatures_created
    assert_includes result.warnings, "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED is false; dry-run plan only."
  end

  test "daily dry-run uses READY_FOR_RANDOM route proofs and writes receipt" do
    position = migration_position
    dirs = receipt_dirs
    result = runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")

    assert_equal "ok", result.status
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)
    assert receipt
    assert_equal "daily_random_rotation_dry_run", receipt.fetch("action")
    assert_equal position.id, receipt.fetch("position_id")
    assert_equal false, receipt.fetch("would_migrate")
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
    assert_equal "READY_FOR_RANDOM", receipt.fetch("route_proof_source")
    assert_equal %w[extended->ethereal extended->nado], receipt.fetch("eligible_random_routes")
    assert_equal true, receipt.fetch("active_venue_rebalance_watchdog").fetch("checked")
  end

  test "daily runner does not mutate hedge execution venue" do
    position = migration_position
    original_venue = position.hedge.execution_venue

    runner(**receipt_dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")

    assert_equal original_venue, position.hedge.reload.execution_venue
  end

  test "daily runner handles no eligible route safely" do
    position = migration_position
    dirs = receipt_dirs
    result = runner(**dirs, preflight_factory: ready_daily_preflight_factory(routes: [])).call(position_id: position.id, enabled_override: true, force: true)
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "NO_READY_FOR_RANDOM_ROUTE", receipt.fetch("status")
    assert_empty receipt.fetch("eligible_random_routes")
    assert_nil receipt.fetch("selected_route")
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  end

  test "daily dry-run includes Nado route when route proof is READY_FOR_RANDOM" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, force: true, seed: "seed-5")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_includes receipt.fetch("eligible_random_routes"), "extended->nado"
    assert_equal false, receipt.fetch("live_available")
    assert_equal false, receipt.fetch("would_migrate")
    assert_includes receipt.fetch("live_blockers"), "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED must be true for live daily random rotation"
  end

  test "daily dry-run reports disabled daily flag as live warning without skipping" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs, env: { "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "false" }).call(position_id: position.id, force: true, seed: "seed-5")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal false, receipt.fetch("daily_enabled")
    assert_includes receipt.fetch("warnings"), "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED is false; dry-run plan only."
    assert_includes receipt.fetch("live_blockers"), "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED must be true for live daily random rotation"
  end

  test "daily dry-run uses active venue watchdog no-op" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")
    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-1")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    watchdog = receipt.fetch("active_venue_rebalance_watchdog")
    assert_equal true, watchdog.fetch("checked")
    assert_equal "extended", watchdog.fetch("venue")
    assert_equal false, watchdog.fetch("needed")
    assert_equal 0, watchdog.fetch("orders_submitted")
  end

  test "daily dry-run does not mutate production venue" do
    position = migration_position
    dirs = receipt_dirs
    original = position.hedge.execution_venue

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")

    assert_equal original, position.hedge.reload.execution_venue
  end

  test "daily live random uses direct preflight and executor instead of dashboard optional partial" do
    OperationalSetting.delete_all
    position = migration_position
    fake_snapshot_refresh_class.new(position: position).refresh
    position.hedge.update!(execution_venue: "ethereal")
    position.position_dashboard_snapshot.update!(
      refresh_status: "partial",
      production_venue: "ethereal",
      selected_venue: "ethereal",
      extended_short_eth: "0",
      ethereal_short_eth: "0.8",
      nado_short_eth: "0",
      extended_optional_read_status: "timed_out"
    )
    dirs = receipt_dirs
    executor = live_executor

    result = runner(
      **dirs,
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_AUTO_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true",
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true",
        "MIGRATION_ROUTE_ETHEREAL_TO_NADO_ENABLED" => "true"
      },
      preflight_factory: live_preflight_factory,
      executor_factory: -> { executor },
      active_rebalance_factory: noop_active_rebalance_factory
    ).call(position_id: position.id, force: true, seed: "seed-live")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "daily_random_rotation_live", receipt.fetch("action")
    assert_equal "success", receipt.fetch("status")
    assert_equal "nado", receipt.fetch("selected_target_venue")
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, executor.received_direct_preflight
    assert_equal true, executor.nado_gates_enabled
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
    assert_equal "0.5", receipt.dig("migration_timing", "target_accept_to_source_close_submit_latency_seconds")
    assert_empty receipt.fetch("blockers")
  end

  test "daily live random can use source-first Nado target route after route proof is ready" do
    OperationalSetting.delete_all
    position = migration_position
    fake_snapshot_refresh_class.new(position: position).refresh
    position.hedge.update!(execution_venue: "ethereal")
    dirs = receipt_dirs
    executor = live_executor

    result = runner(
      **dirs,
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_AUTO_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true",
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
      },
      preflight_factory: live_preflight_factory,
      executor_factory: -> { executor },
      active_rebalance_factory: noop_active_rebalance_factory
    ).call(position_id: position.id, force: true, seed: "seed-live")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "nado", receipt.fetch("selected_target_venue")
    assert_equal "nado", position.hedge.reload.execution_venue
    assert_equal true, OperationalSettings.enabled?("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
  end

  test "daily live random runs pre-cycle and post-migration active venue rebalance hooks" do
    OperationalSetting.delete_all
    position = migration_position
    fake_snapshot_refresh_class.new(position: position).refresh
    position.hedge.update!(execution_venue: "ethereal")
    dirs = receipt_dirs
    executor = live_executor(orders_submitted: 0, signatures_created: 0)
    active = SequencedActiveRebalance.new([
      active_rebalance_payload(venue: "ethereal", needed: false, reason: "inside_tolerance"),
      active_rebalance_payload(venue: "nado", needed: true, reason: "executed", orders_submitted: 1, signatures_created: 1)
    ])

    result = runner(
      **dirs,
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_AUTO_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true",
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
      },
      preflight_factory: live_preflight_factory,
      executor_factory: -> { executor },
      active_rebalance_factory: ->(position:) { active }
    ).call(position_id: position.id, force: true, seed: "seed-live")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "success", receipt.fetch("status")
    assert_equal true, receipt.fetch("pre_next_cycle_rebalance").fetch("checked")
    assert_equal true, receipt.fetch("post_migration_rebalance").fetch("needed")
    assert_equal "nado", receipt.fetch("post_migration_rebalance").fetch("venue")
    assert_equal 1, receipt.fetch("orders_submitted")
    assert_equal 1, receipt.fetch("signatures_created")
  end

  test "daily live random blocks before submit when active venue capability matrix blocks" do
    OperationalSetting.delete_all
    position = migration_position
    fake_snapshot_refresh_class.new(position: position).refresh
    position.hedge.update!(execution_venue: "ethereal")
    dirs = receipt_dirs
    executor = live_executor
    blocker = "Extended active rebalance cannot handle drift 0.071 ETH because EXTENDED_ONE_SHOT_MAX_SIZE_ETH=0.02 and scoped migration rebalance gate is unavailable."

    result = runner(
      **dirs,
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_AUTO_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true",
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
      },
      preflight_factory: live_preflight_factory,
      executor_factory: -> { executor },
      active_rebalance_factory: noop_active_rebalance_factory,
      active_rebalance_capability_matrix_factory: ->(position:) { CapabilityMatrixStub.new(blockers: [ blocker ]) }
    ).call(position_id: position.id, force: true, seed: "seed-live")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "blocked_before_submit", receipt.fetch("status")
    assert_includes receipt.fetch("blockers"), blocker
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  end

  test "daily live random records target-open source-still-open as manual action" do
    OperationalSetting.delete_all
    position = migration_position
    fake_snapshot_refresh_class.new(position: position).refresh
    position.hedge.update!(execution_venue: "ethereal")
    dirs = receipt_dirs
    executor = live_executor(status: "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", orders_submitted: 1, signatures_created: 1)

    runner(
      **dirs,
      env: {
        "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "true",
        "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED" => "true",
        "MIGRATION_AUTO_ENABLED" => "true",
        "MIGRATION_LIVE_ENABLED" => "true",
        "AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED" => "true"
      },
      preflight_factory: live_preflight_factory,
      executor_factory: -> { executor },
      active_rebalance_factory: noop_active_rebalance_factory
    ).call(position_id: position.id, force: true, seed: "seed-live")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "daily_random_rotation_live", receipt.fetch("action")
    assert_equal "MANUAL_ACTION_REQUIRED_TARGET_OPEN_SOURCE_STILL_OPEN", receipt.fetch("status")
    assert_equal false, receipt.fetch("would_migrate")
    assert_includes receipt.fetch("blockers"), "source still open after target accepted"
    assert_equal 1, receipt.fetch("orders_submitted")
    assert_equal 1, receipt.fetch("signatures_created")
  end

  private

  def runner(env: {}, receipt_dir: nil, route_receipt_dir: nil, random_receipt_dir: nil, state_dir: nil, route_matrix_class: ready_route_matrix_class, preflight_factory: nil, executor_factory: nil, active_rebalance_factory: nil, active_rebalance_capability_matrix_factory: nil)
    MigrationRandomRotationDailyRunner.new(
      env: { "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "false", "MIGRATION_MIN_COOLDOWN_HOURS" => "0" }.merge(env),
      receipt_dir: receipt_dir || Rails.root.join("tmp/test-daily-random-#{SecureRandom.hex(4)}"),
      route_receipt_dir: route_receipt_dir || Rails.root.join("tmp/test-route-proof-#{SecureRandom.hex(4)}"),
      random_receipt_dir: random_receipt_dir || Rails.root.join("tmp/test-random-#{SecureRandom.hex(4)}"),
      state_dir: state_dir || Rails.root.join("tmp/test-random-state-#{SecureRandom.hex(4)}"),
      route_matrix_class: route_matrix_class,
      snapshot_refresh_class: fake_snapshot_refresh_class,
      preflight_factory: preflight_factory || ready_daily_preflight_factory,
      executor_factory: executor_factory,
      active_rebalance_factory: active_rebalance_factory || noop_active_rebalance_factory,
      active_rebalance_capability_matrix_factory: active_rebalance_capability_matrix_factory,
      now: -> { Time.zone.local(2026, 5, 28, 12, 0, 0) }
    )
  end

  def noop_active_rebalance_factory
    ->(position:) { NoopActiveRebalance.new(position) }
  end

  def ready_daily_preflight_factory(production_venue: "extended", routes: nil)
    ->(position:, stage:) {
      proof_routes = routes || MigrationLiveRouteCapability::ROUTES.map do |from, to|
        { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "READY_FOR_RANDOM", blockers: [] }
      end
      {
        preflight_source: "test_daily_random_preflight",
        accepted: true,
        blockers: [],
        warnings: [],
        production_venue: production_venue,
        target: {
          target_short_eth: BigDecimal("0.8"),
          target_source: "test",
          target_fresh: true,
          exposure_refreshed_at: Time.zone.local(2026, 5, 28, 12, 0, 0).utc.iso8601
        },
        venues: {
          "extended" => { short_eth: production_venue == "extended" ? BigDecimal("0.8") : BigDecimal("0"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 },
          "ethereal" => { short_eth: production_venue == "ethereal" ? BigDecimal("0.8") : BigDecimal("0"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 },
          "nado" => { short_eth: production_venue == "nado" ? BigDecimal("0.8") : BigDecimal("0"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 }
        },
        active_short_venues: [ production_venue ],
        combined_short_eth: BigDecimal("0.8"),
        drift_eth: BigDecimal("0"),
        tolerance_abs_eth: BigDecimal("0.024"),
        inside_tolerance: true,
        proof_report: {
          routes: proof_routes,
          completed_route_proofs: proof_routes,
          missing_route_proofs: [],
          stale_route_proofs: []
        },
        readiness: { blockers: [] },
        signer: { status: "ok", payload: { ok: true } }
      }
    }
  end

  def active_rebalance_payload(venue:, needed:, reason:, orders_submitted: 0, signatures_created: 0)
    {
      checked: true,
      checked_at: Time.zone.local(2026, 5, 28, 12, 0, 0).utc.iso8601,
      needed: needed,
      venue: venue,
      reason: reason,
      target_short_eth: "0.8",
      current_short_eth: needed ? "0.7" : "0.8",
      drift_eth: needed ? "0.1" : "0",
      tolerance_eth: "0.024",
      inside_tolerance: !needed,
      orders_submitted: orders_submitted,
      orders_placed: orders_submitted,
      signatures_created: signatures_created,
      final_inside_tolerance: true,
      blockers: []
    }
  end

  def receipt_dirs
    {
      receipt_dir: Rails.root.join("tmp/test-daily-random-#{SecureRandom.hex(4)}"),
      route_receipt_dir: Rails.root.join("tmp/test-route-proof-#{SecureRandom.hex(4)}"),
      random_receipt_dir: Rails.root.join("tmp/test-random-#{SecureRandom.hex(4)}"),
      state_dir: Rails.root.join("tmp/test-random-state-#{SecureRandom.hex(4)}")
    }
  end

  def fake_snapshot_refresh_class
    Class.new do
      def initialize(position:, **)
        @position = position
      end

      def refresh
        @position.position_dashboard_snapshot || @position.create_position_dashboard_snapshot!(
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
          nado_source_status: "ok"
        )
      end
    end
  end

  def ready_route_matrix_class
    Class.new do
      def initialize(position:, snapshot:, receipt_dir:)
        @position = position
        @receipt_dir = receipt_dir
      end

      def prove_routes!
        {
          action: "migration_route_proof_summary",
          position_id: @position.id,
          receipt_paths: [ @receipt_dir.join("20260528.jsonl").to_s ],
          routes: [
            route("extended", "ethereal", []),
            route("extended", "nado", [ "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit" ]),
            nado_source_route("nado", "extended"),
            nado_source_route("nado", "ethereal")
          ],
          orders_submitted: 0,
          signatures_created: 0
        }
      end

      def route(from, to, blockers)
        {
          from_venue: from,
          to_venue: to,
          route_status: "READY_FOR_DRY_RUN",
          preview_available: true,
          live_available: false,
          blockers: blockers,
          last_proof_time: "2026-05-28T12:00:00Z"
        }
      end

      def nado_source_route(from, to)
        route(from, to, [ "source venue Nado has no current short to migrate.", "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit" ]).merge(
          route_status: "PREVIEW_BLOCKED",
          preview_available: false,
          nado_readiness: {
            nado_reduce_only_close_preview_available: true,
            nado_reduce_only_close_preview_proof_mode: "synthetic",
            nado_source_leg_preview_proof: { ok: true }
          }
        )
      end
    end
  end

  def nado_source_without_virtual_proof_matrix_class
    Class.new do
      def initialize(position:, snapshot:, receipt_dir:)
        @position = position
      end

      def prove_routes!
        {
          action: "migration_route_proof_summary",
          position_id: @position.id,
          receipt_paths: [],
          routes: [
            {
              from_venue: "nado",
              to_venue: "extended",
              route_status: "PREVIEW_BLOCKED",
              preview_available: false,
              live_available: false,
              blockers: [ "source venue Nado has no current short to migrate.", "AERODROME_NADO_HEDGE_LIVE_ENABLED must be true for Nado live submit" ],
              nado_readiness: {
                nado_reduce_only_close_preview_available: false
              },
              last_proof_time: "2026-05-28T12:00:00Z"
            }
          ],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end
  end

  def blocked_route_matrix_class
    Class.new do
      def initialize(position:, snapshot:, receipt_dir:)
        @position = position
      end

      def prove_routes!
        {
          action: "migration_route_proof_summary",
          position_id: @position.id,
          receipt_paths: [],
          routes: [
            {
              from_venue: "extended",
              to_venue: "ethereal",
              route_status: "PREVIEW_BLOCKED",
              preview_available: false,
              live_available: false,
              blockers: [ "open orders present" ],
              last_proof_time: "2026-05-28T12:00:00Z"
            }
          ],
          orders_submitted: 0,
          signatures_created: 0
        }
      end
    end
  end

  def migration_position
    Position.create!(
      user: users(:one),
      wallet: wallets(:one),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_AERODROME_DIRECT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1",
      asset1_amount: "1000",
      asset0_price_usd: "2000",
      asset1_price_usd: "1",
      external_id: SecureRandom.hex(4),
      active: true
    ).tap do |position|
      position.create_hedge!(target: "0.8", tolerance: "0.03", active: true, execution_venue: "extended")
    end
  end

  def latest_daily_receipt(dir, position_id)
    path = Dir.glob(Pathname(dir).join("*.jsonl")).sort.last
    File.readlines(path).reverse_each do |line|
      receipt = JSON.parse(line)
      return receipt if receipt["position_id"] == position_id
    end
    nil
  end

  def live_preflight_factory
    ->(position:, stage:) {
      routes = MigrationLiveRouteCapability::ROUTES.map do |from, to|
        { route: "#{from}->#{to}", from_venue: from, to_venue: to, status: "READY_FOR_RANDOM", blockers: [] }
      end
      {
        preflight_source: "dedicated_burn_in_preflight",
        accepted: true,
        blockers: [],
        warnings: [ "dashboard snapshot optional diagnostics ignored by direct preflight" ],
        production_venue: "ethereal",
        target: {
          target_short_eth: BigDecimal("0.8"),
          target_source: "test_direct_preflight",
          target_fresh: true,
          exposure_refreshed_at: Time.zone.local(2026, 5, 28, 12, 0, 0).utc.iso8601
        },
        venues: {
          "extended" => { short_eth: BigDecimal("0"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 },
          "ethereal" => { short_eth: BigDecimal("0.8"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 },
          "nado" => { short_eth: BigDecimal("0"), position_status: "ok", open_orders_status: "zero", open_orders_count: 0 }
        },
        combined_short_eth: BigDecimal("0.8"),
        drift_eth: BigDecimal("0"),
        tolerance_abs_eth: BigDecimal("0.024"),
        inside_tolerance: true,
        proof_report: {
          routes: routes,
          completed_route_proofs: routes,
          missing_route_proofs: [],
          stale_route_proofs: []
        },
        readiness: {
          pending_nado_target_continuation: nil,
          pending_nado_target_continuation_blocking: false,
          stale_pending_continuation_ignored: false,
          blockers: []
        },
        signer: { status: "ok", payload: { ok: true } }
      }
    }
  end

  def live_executor(status: "success", orders_submitted: 2, signatures_created: 2)
    Class.new do
      define_method(:initialize) do |configured_status, configured_orders, configured_signatures|
        @configured_status = configured_status
        @configured_orders = configured_orders
        @configured_signatures = configured_signatures
      end

      attr_reader :received_direct_preflight, :nado_gates_enabled

      def run(position:, from_venue:, to_venue:, execution_preflight:, **)
        @received_direct_preflight = execution_preflight[:accepted] == true
        @nado_gates_enabled = OperationalSettings.enabled?("AERODROME_NADO_HEDGE_LIVE_ENABLED") &&
          OperationalSettings.enabled?("AERODROME_NADO_LIVE_MIGRATION_ENABLED")
        position.hedge.update!(execution_venue: to_venue) if @configured_status == "success"
        HedgeVenueMigrationExecutor::Result.new(
          @configured_status,
          @configured_status == "success" ? [] : [ "source still open after target accepted" ],
          [],
          {
            from_venue: from_venue,
            to_venue: to_venue,
            final_status: @configured_status,
            orders_submitted: @configured_orders,
            orders_placed: @configured_orders,
            signatures_created: @configured_signatures,
            receipt_path: "tmp/daily-live-executor.jsonl",
            target_accept_to_source_close_submit_latency_seconds: "0.5"
          }
        )
      end
    end.new(status, orders_submitted, signatures_created)
  end

  class NoopActiveRebalance
    def initialize(position)
      @position = position
    end

    def run(reason:)
      {
        checked: true,
        checked_at: Time.zone.local(2026, 5, 28, 12, 0, 0).utc.iso8601,
        needed: false,
        venue: HedgeVenues.normalize(@position.hedge.execution_venue),
        reason: "inside_tolerance",
        target_short_eth: "0.8",
        current_short_eth: "0.8",
        drift_eth: "0",
        tolerance_eth: "0.024",
        inside_tolerance: true,
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        final_inside_tolerance: true,
        blockers: []
      }
    end
  end

  class SequencedActiveRebalance
    def initialize(payloads)
      @payloads = payloads
    end

    def run(reason:)
      @payloads.shift.merge(trigger: reason)
    end
  end

  class CapabilityMatrixStub
    def initialize(blockers: [])
      @blockers = blockers
    end

    def report
      {
        all_supported: @blockers.empty?,
        venues: [],
        blockers: @blockers,
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0
      }
    end
  end
end
