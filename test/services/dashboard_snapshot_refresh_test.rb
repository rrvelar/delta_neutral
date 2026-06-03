require "test_helper"

class DashboardSnapshotRefreshTest < ActiveSupport::TestCase
  setup do
    DashboardSnapshotRefresh.extended_optional_attempts.clear
    OperationalSetting.delete_all
  end

  test "refresh stores current venue readbacks without using rebalance history" do
    position = create_position_with_hedge
    position.hedge.short_rebalances.create!(
      asset: "ETH",
      venue: "ethereal",
      old_short_size: "0",
      new_short_size: "9.9",
      status: ShortRebalance::STATUS_SUCCESS,
      rebalanced_at: 1.minute.ago
    )

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => {
          position: {
            short_size: "0.8",
            notional_usd: "1600",
            entry_price: "2000",
            mark_price: "2100",
            unrealized_pnl_usd: "-80",
            leverage: "1",
            effective_leverage: "1",
            margin_mode: "isolated"
          },
          account_state: { open_orders_count: 0, margin_gate: { status: "pass" } }
        },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal "ok", snapshot.refresh_status
    assert_equal BigDecimal("0.8"), snapshot.extended_short_eth
    assert_equal BigDecimal("0"), snapshot.ethereal_short_eth
    assert_equal BigDecimal("0"), snapshot.nado_short_eth
    assert_equal BigDecimal("1.25"), snapshot.target_short_eth
    assert_equal BigDecimal("0.0625"), snapshot.tolerance_abs_eth
    assert_equal BigDecimal("0.8"), snapshot.combined_short_eth
    assert_equal BigDecimal("0.45"), snapshot.drift_eth
    assert_equal false, snapshot.inside_tolerance
    assert_equal "active", snapshot.extended_status
    assert_equal "flat", snapshot.ethereal_status
    assert_equal "flat", snapshot.nado_status
    assert_equal "ok", snapshot.signer_status
    assert_equal 0, snapshot.open_orders_count_extended
  end

  test "refresh derives target from position and hedge even when valuation exposure is unavailable" do
    position = create_position_with_hedge
    PositionValuation.stub(:current, PositionValuation::Result.new(
      source: "test",
      current_value_usd: nil,
      entry_value_usd: nil,
      pool_delta_usd: nil,
      weth_exposure: nil,
      usdc_exposure: nil,
      current_value_label: "Current value",
      entry_value_label: "Entry value",
      pool_delta_label: "Delta",
      hedge_target_label: "Target",
      status: "stale_unavailable",
      warnings: []
    )) do
      snapshot = DashboardSnapshotRefresh.new(
        position: position,
        env: snapshot_env,
        venue_builder: fake_builder(
          "extended" => { position: { short_size: "1.25" }, account_state: { open_orders_count: 0, margin_gate: { status: "pass" } } },
          "ethereal" => { position: nil },
          "nado" => { position: nil }
        ),
        signer_client: fake_signer(ok: true)
      ).refresh

      assert_equal "ok", snapshot.refresh_status
      assert_equal BigDecimal("1.25"), snapshot.target_short_eth
      assert_equal BigDecimal("1.25"), snapshot.combined_short_eth
      assert_equal BigDecimal("0"), snapshot.drift_eth
      assert_equal true, snapshot.inside_tolerance
    end
  end

  test "refresh status is partial when critical migration fields are missing" do
    position = Position.create!(
      user: users(:one),
      wallet: base_wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: SecureRandom.hex(4),
      active: true
    )

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "1.25" }, account_state: { open_orders_count: 0 } },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal "partial", snapshot.refresh_status
    assert_includes snapshot.source_errors_hash.fetch("critical_derived_fields"), "target_short_eth"
    assert_includes snapshot.source_errors_hash.fetch("critical_derived_fields"), "production_venue"
  end

  test "refresh stores partial snapshot when one venue read fails" do
    position = create_position_with_hedge

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.7" }, account_state: { open_orders_count: 0 } },
        "ethereal" => { position: RuntimeError.new("ethereal read failed") },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal "partial", snapshot.refresh_status
    assert_equal BigDecimal("0.7"), snapshot.extended_short_eth
    assert_nil snapshot.ethereal_short_eth
    assert_equal BigDecimal("0"), snapshot.nado_short_eth
    assert_nil snapshot.combined_short_eth
    assert_equal "error", snapshot.ethereal_status
    assert_equal "error", snapshot.ethereal_source_status
    assert_includes snapshot.source_errors_hash.fetch("ethereal"), "ethereal read failed"
  end

  test "missing venue configuration stores unknown without faking zero" do
    position = create_position_with_hedge
    env = snapshot_env.except("EXTENDED_API_KEY", "ETHEREAL_READ_ONLY_ENABLED", "NADO_READ_ONLY_ENABLED")

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: env,
      venue_builder: fake_builder,
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal "partial", snapshot.refresh_status
    assert_nil snapshot.extended_short_eth
    assert_nil snapshot.ethereal_short_eth
    assert_nil snapshot.nado_short_eth
    assert_nil snapshot.combined_short_eth
    assert_equal "unknown", snapshot.extended_status
    assert_equal "not_configured", snapshot.extended_source_status
  end

  test "refresh stores DB operational auto overrides over env" do
    position = create_position_with_hedge
    position.hedge.update!(execution_venue: "ethereal")
    OperationalSettings.set!(key: "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED", enabled: true)
    OperationalSettings.set!(key: "AERODROME_NADO_AUTO_REBALANCE_ENABLED", enabled: false)
    env = snapshot_env.merge(
      "AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED" => "false",
      "AERODROME_NADO_AUTO_REBALANCE_ENABLED" => "true"
    )

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: env,
      venue_builder: fake_builder(
        "extended" => { position: nil, account_state: { open_orders_count: 0 } },
        "ethereal" => { position: { short_size: "1.25" }, account_state: { open_orders_count: 0 } },
        "nado" => { position: nil, account_state: { open_orders_count: 0 } }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal true, snapshot.ethereal_auto_enabled
    assert_equal false, snapshot.nado_auto_enabled
  end

  test "uses dashboard snapshot timeout instead of page section timeout" do
    position = create_position_with_hedge

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env.merge(
        "POSITIONS_DASHBOARD_SECTION_TIMEOUT_SECONDS" => "0.01",
        "DASHBOARD_SNAPSHOT_VENUE_TIMEOUT_SECONDS" => "8"
      ),
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.831" }, read_delay: 0.05, account_state: {} },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal BigDecimal("0.831"), snapshot.extended_short_eth
    assert_equal "active", snapshot.extended_status
    assert_equal BigDecimal("8.0"), snapshot.timeout_seconds_used
    assert_equal "ok", snapshot.extended_critical_read_status
  end

  test "extended read_position taking two seconds succeeds with default snapshot timeout" do
    position = create_position_with_hedge

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.831" }, read_delay: 2.0, account_state: {} },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal BigDecimal("0.831"), snapshot.extended_short_eth
    assert_equal "active", snapshot.extended_status
    assert_equal "ok", snapshot.extended_critical_read_status
    assert_operator snapshot.extended_critical_read_duration_ms, :>=, 1_900
  end

  test "optional extended diagnostics timeout does not clear critical exposure" do
    position = create_position_with_hedge

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      timeout_seconds: 0.01,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.831" }, account_state: {}, account_delay: 0.05 },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal BigDecimal("0.831"), snapshot.extended_short_eth
    assert_equal "active", snapshot.extended_status
    assert_equal "ok", snapshot.extended_critical_read_status
    assert_equal "error", snapshot.extended_optional_read_status
    assert_equal BigDecimal("0.831"), snapshot.combined_short_eth
    assert_includes snapshot.source_errors_hash.fetch("extended_optional"), "Timeout::Error"
  end

  test "optional extended diagnostics are throttled while critical exposure still updates" do
    position = create_position_with_hedge
    previous = position.create_position_dashboard_snapshot!(
      refreshed_at: 5.minutes.ago,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "1.25",
      tolerance_ratio: "0.05",
      tolerance_abs_eth: "0.0625",
      combined_short_eth: "0.7",
      drift_eth: "0.55",
      inside_tolerance: false,
      extended_short_eth: "0.7",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok",
      open_orders_count_extended: 3,
      leverage_margin_gate_status: "pass"
    )
    DashboardSnapshotRefresh.extended_optional_attempts["dashboard_snapshot:extended_optional_attempt:position:#{position.id}"] = Time.current.to_i

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.831" }, account_state: RuntimeError.new("optional should be skipped") },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal previous.id, snapshot.id
    assert_equal BigDecimal("0.831"), snapshot.extended_short_eth
    assert_equal 3, snapshot.open_orders_count_extended
    assert_equal "skipped_throttled", snapshot.extended_optional_read_status
  ensure
    DashboardSnapshotRefresh.extended_optional_attempts.delete("dashboard_snapshot:extended_optional_attempt:position:#{position.id}") if defined?(position) && position
    Rails.cache.delete("dashboard_snapshot:extended_optional_attempt:position:#{position.id}") if defined?(position) && position
  end

  test "critical extended timeout carries forward previous good snapshot" do
    position = create_position_with_hedge
    previous = position.create_position_dashboard_snapshot!(
      refreshed_at: 5.minutes.ago,
      refresh_status: "ok",
      stale: false,
      production_venue: "extended",
      selected_venue: "extended",
      target_short_eth: "1.25",
      tolerance_ratio: "0.05",
      tolerance_abs_eth: "0.0625",
      combined_short_eth: "0.7",
      drift_eth: "0.55",
      inside_tolerance: false,
      extended_short_eth: "0.7",
      ethereal_short_eth: "0",
      nado_short_eth: "0",
      extended_status: "active",
      ethereal_status: "flat",
      nado_status: "flat",
      extended_source_status: "ok",
      ethereal_source_status: "ok",
      nado_source_status: "ok"
    )
    previous_refreshed_at = previous.refreshed_at

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      timeout_seconds: 0.01,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.9" }, read_delay: 0.05, account_state: {} },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_equal previous.id, snapshot.id
    assert_equal BigDecimal("0.7"), snapshot.extended_short_eth
    assert_equal "error", snapshot.extended_status
    assert_equal "stale", snapshot.extended_source_status
    assert_equal "error_carried_forward", snapshot.extended_critical_read_status
    assert_equal previous_refreshed_at.to_i, snapshot.extended_value_stale_as_of.to_i
    assert_equal BigDecimal("0.7"), snapshot.combined_short_eth
    assert_equal BigDecimal("0.55"), snapshot.drift_eth
    assert_equal false, snapshot.inside_tolerance
  end

  test "critical extended timeout without previous snapshot leaves extended error unknown" do
    position = create_position_with_hedge

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      timeout_seconds: 0.01,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "0.9" }, read_delay: 0.05, account_state: {} },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true)
    ).refresh

    assert_nil snapshot.extended_short_eth
    assert_equal "error", snapshot.extended_status
    assert_equal "error", snapshot.extended_source_status
    assert_nil snapshot.combined_short_eth
    assert_nil snapshot.drift_eth
    assert_nil snapshot.inside_tolerance
  end

  test "refresh uses fresh Mellow target before building snapshot" do
    position = create_position_with_hedge
    position.update!(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0_amount: "1.017",
      mellow_metadata: {
        "hedge_ready" => true,
        "last_probe_confidence" => "current_share_token_resolver_high",
        "exposure_source" => "current_share_token_resolver",
        "last_current_exposure_at" => Time.current.iso8601
      }.to_json
    )

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "1.033" }, account_state: { open_orders_count: 0, margin_gate: { status: "pass" } } },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true),
      fresh_target_factory: ->(_position) { FakeFreshTarget.new(status: "ok", target: BigDecimal("1.017")) }
    ).refresh

    assert_equal "ok", snapshot.refresh_status
    assert_equal BigDecimal("1.017"), snapshot.target_short_eth
    assert_equal true, snapshot.inside_tolerance
  end

  test "snapshot is partial when Mellow target refresh is blocked" do
    position = create_position_with_hedge
    position.update!(source: Position::SOURCE_MELLOW_AUTOPILOT)

    snapshot = DashboardSnapshotRefresh.new(
      position: position,
      env: snapshot_env,
      venue_builder: fake_builder(
        "extended" => { position: { short_size: "1.033" }, account_state: { open_orders_count: 0, margin_gate: { status: "pass" } } },
        "ethereal" => { position: nil },
        "nado" => { position: nil }
      ),
      signer_client: fake_signer(ok: true),
      fresh_target_factory: ->(_position) { FakeFreshTarget.new(status: "blocked") }
    ).refresh

    assert_equal "partial", snapshot.refresh_status
    assert_nil snapshot.target_short_eth
    assert_includes JSON.parse(snapshot.source_errors).fetch("mellow_exposure"), "fresh Mellow exposure required before hedge sizing"
  end

  private

  def create_position_with_hedge
    position = Position.create!(
      user: users(:one),
      wallet: base_wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("1.25"),
      asset1_amount: BigDecimal("500"),
      asset0_price_usd: BigDecimal("2000"),
      asset1_price_usd: BigDecimal("1"),
      external_id: SecureRandom.hex(4),
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      active: true
    )
    position.create_hedge!(target: "1.0", tolerance: "0.05", active: true, execution_venue: "extended")
    position
  end

  def base_wallet
    Wallet.find_or_create_by!(
      user: users(:one),
      network: networks(:base),
      address: "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
    )
  end

  def snapshot_env
    {
      "EXTENDED_API_BASE_URL" => "https://extended.example/api/v1",
      "EXTENDED_API_KEY" => "test-api-key",
      "EXTENDED_ACCOUNT_ID" => "acct",
      "EXTENDED_VAULT_NUMBER" => "123",
      "EXTENDED_CLIENT_ID" => "client",
      "EXTENDED_STARK_PUBLIC_KEY" => "0xpublic",
      "ETHEREAL_READ_ONLY_ENABLED" => "true",
      "ETHEREAL_API_BASE_URL" => "https://ethereal.example",
      "ETHEREAL_SUBACCOUNT_ID" => "sub",
      "NADO_READ_ONLY_ENABLED" => "true",
      "NADO_GATEWAY_QUERY_BASE_URL" => "https://nado.example",
      "NADO_ACCOUNT_ADDRESS" => "0xwallet",
      "EXTENDED_SIGNER_URL" => "http://127.0.0.1:8776"
    }
  end

  def fake_builder(results = {})
    FakeVenueBuilder.new(results)
  end

  def fake_signer(ok:)
    FakeSigner.new({ ok: ok })
  end

  class FakeVenueBuilder
    def initialize(results)
      @results = results
    end

    def build(venue)
      FakeVenue.new(@results.fetch(venue))
    end
  end

  class FakeVenue
    def initialize(result)
      @result = result
    end

    def read_position(symbol:)
      sleep @result[:read_delay] if @result[:read_delay]
      value = @result.fetch(:position)
      raise value if value.is_a?(Exception)

      value
    end

    def account_state
      sleep @result[:account_delay] if @result[:account_delay]
      value = @result.fetch(:account_state, {})
      raise value if value.is_a?(Exception)

      value
    end
  end

  class FakeSigner
    def initialize(payload)
      @payload = payload
    end

    def health
      @payload
    end
  end

  FakeFreshTarget = Struct.new(:status, :target, keyword_init: true) do
    def resolve(refresh_if_stale: true)
      if status == "ok"
        {
          status: "ok",
          target_short_eth: target,
          target_source: "current_share_token_resolver",
          target_fresh: true,
          exposure_source: "current_share_token_resolver",
          exposure_refreshed_at: Time.current.iso8601,
          exposure_stale: false,
          blockers: []
        }
      else
        {
          status: "blocked",
          target_short_eth: nil,
          target_fresh: false,
          blockers: [ "fresh Mellow exposure required before hedge sizing" ]
        }
      end
    end
  end
end
