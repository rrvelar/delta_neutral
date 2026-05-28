require "test_helper"

class MigrationRandomRotationDailyRunnerTest < ActiveSupport::TestCase
  test "daily runner exits disabled when env gate is false" do
    result = runner(env: { "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "false" }).call

    assert_equal "disabled", result.status
    assert_empty result.positions
    assert_equal 0, result.orders_submitted
    assert_equal 0, result.signatures_created
  end

  test "enabled override runs proof and random decision and writes daily receipt" do
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
    assert_match "test-random", receipt.fetch("random_rotation_receipt_path")
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
    result = runner(**dirs, route_matrix_class: blocked_route_matrix_class).call(position_id: position.id, enabled_override: true, force: true)
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "ok", result.status
    assert_equal "NO_ELIGIBLE_ROUTE", receipt.fetch("status")
    assert_includes receipt.fetch("blockers"), "no eligible random rotation route"
    assert_equal 0, receipt.fetch("orders_submitted")
    assert_equal 0, receipt.fetch("signatures_created")
  end

  test "daily runner records extended to nado decision only with live blocked" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "nado", receipt.fetch("selected_target_venue")
    assert_equal false, receipt.fetch("live_available")
    assert_equal false, receipt.fetch("would_migrate")
    nado_live_blocked = receipt.fetch("live_blocked_routes").find { |route| route.fetch("to_venue") == "nado" }
    assert nado_live_blocked
    assert_includes nado_live_blocked.fetch("live_blockers"), "Nado live migration path not implemented."
  end

  test "first virtual dry run initializes state from production venue and advances selected target" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")
    state = JSON.parse(File.read(Pathname(dirs.fetch(:state_dir)).join("position_#{position.id}.json")))
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "extended", receipt.fetch("production_venue")
    assert_equal "extended", receipt.fetch("virtual_current_venue_before")
    assert_equal "nado", receipt.fetch("selected_target_venue")
    assert_equal "nado", receipt.fetch("virtual_current_venue_after")
    assert_equal "nado", state.fetch("virtual_current_venue")
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  test "next virtual dry run starts from prior virtual venue not production venue" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")
    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-1")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)

    assert_equal "extended", receipt.fetch("production_venue")
    assert_equal "nado", receipt.fetch("virtual_current_venue_before")
    assert_includes %w[extended ethereal], receipt.fetch("selected_target_venue")
    assert_equal receipt.fetch("selected_target_venue"), receipt.fetch("virtual_current_venue_after")
    selected = receipt.fetch("selected_route")
    assert_equal "READY_FOR_VIRTUAL_DRY_RUN", selected.fetch("virtual_route_status")
    assert_equal "PREVIEW_BLOCKED", selected.fetch("production_route_status")
    assert_equal true, selected.fetch("virtual_preview_available")
    assert_equal true, selected.fetch("production_source_short_not_required")
    assert_equal false, selected.fetch("live_execution_eligible")
    assert_equal "extended", position.hedge.reload.execution_venue
  end

  test "daily runner does not advance virtual state without virtual proof" do
    position = migration_position
    dirs = receipt_dirs

    runner(**dirs).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-5")
    runner(**dirs, route_matrix_class: nado_source_without_virtual_proof_matrix_class).call(position_id: position.id, enabled_override: true, force: true, seed: "seed-1")
    receipt = latest_daily_receipt(dirs.fetch(:receipt_dir), position.id)
    state = JSON.parse(File.read(Pathname(dirs.fetch(:state_dir)).join("position_#{position.id}.json")))

    assert_equal "NO_ELIGIBLE_ROUTE", receipt.fetch("status")
    assert_equal "nado", receipt.fetch("virtual_current_venue_before")
    assert_equal "nado", receipt.fetch("virtual_current_venue_after")
    assert_equal "nado", state.fetch("virtual_current_venue")
  end

  private

  def runner(env: {}, receipt_dir: nil, route_receipt_dir: nil, random_receipt_dir: nil, state_dir: nil, route_matrix_class: ready_route_matrix_class)
    MigrationRandomRotationDailyRunner.new(
      env: { "MIGRATION_RANDOM_ROTATION_DAILY_ENABLED" => "false", "MIGRATION_MIN_COOLDOWN_HOURS" => "0" }.merge(env),
      receipt_dir: receipt_dir || Rails.root.join("tmp/test-daily-random-#{SecureRandom.hex(4)}"),
      route_receipt_dir: route_receipt_dir || Rails.root.join("tmp/test-route-proof-#{SecureRandom.hex(4)}"),
      random_receipt_dir: random_receipt_dir || Rails.root.join("tmp/test-random-#{SecureRandom.hex(4)}"),
      state_dir: state_dir || Rails.root.join("tmp/test-random-state-#{SecureRandom.hex(4)}"),
      route_matrix_class: route_matrix_class,
      snapshot_refresh_class: fake_snapshot_refresh_class,
      now: -> { Time.zone.local(2026, 5, 28, 12, 0, 0) }
    )
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
            route("extended", "nado", [ "Nado live migration path not implemented." ]),
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
        route(from, to, [ "source venue Nado has no current short to migrate.", "Nado live migration path not implemented." ]).merge(
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
              blockers: [ "source venue Nado has no current short to migrate.", "Nado live migration path not implemented." ],
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
end
