require "test_helper"

class MellowExposureRefreshJobTest < ActiveJob::TestCase
  test "recurring schedule includes mellow exposure refresh" do
    config = YAML.safe_load_file(Rails.root.join("config", "recurring.yml"), aliases: true)
    entry = config.fetch("default").fetch("mellow_exposure_refresh")

    assert_equal "MellowExposureRefreshJob", entry.fetch("class")
    assert_equal "every 2 minutes", entry.fetch("schedule")
  end

  test "job exits disabled without refreshing" do
    position = mellow_position
    with_env("MELLOW_EXPOSURE_AUTO_REFRESH_ENABLED" => "false") do
      result = MellowExposureRefreshJob.perform_now(position.id)

      assert_equal "disabled", result.fetch(:status)
      assert_equal 0, result.fetch(:orders_submitted)
      assert_equal 0, result.fetch(:signatures_created)
    end
  end

  test "job refreshes active Mellow positions and enqueues dashboard snapshot" do
    position = mellow_position
    result = nil

    MellowAutopilotPositionSync.stub(:new, ->(position:) { SyncMock.new(position) }) do
      assert_enqueued_with(job: DashboardSnapshotJob, args: [ position.id, { force: true } ]) do
        result = MellowExposureRefreshJob.perform_now(position.id)
      end
    end

    row = result.fetch(:positions).first
    assert_equal "synced", row.fetch(:status)
    assert_equal "1.02", row.fetch(:new_asset0)
    assert_equal "current_share_token_resolver", row.fetch(:exposure_source)
    assert_equal 0, row.fetch(:orders_submitted)
    assert_equal 0, row.fetch(:signatures_created)
  end

  private

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  class SyncMock
    def initialize(position)
      @position = position
    end

    def sync
      @position.update!(
        asset0_amount: "1.02",
        asset1_amount: "530",
        mellow_metadata: @position.mellow_metadata_hash.merge(
          "hedge_ready" => true,
          "last_probe_confidence" => "current_share_token_resolver_high",
          "exposure_source" => "current_share_token_resolver",
          "successful_method" => "previewMint(uint256)",
          "last_current_exposure_at" => Time.current.iso8601
        ).to_json
      )
      { status: "synced", blockers: [] }
    end
  end

  def mellow_position
    wallet = Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644")
    position = Position.create!(
      user: users(:one),
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.28",
      asset1_amount: "0",
      asset0_price_usd: "2500",
      asset1_price_usd: "1",
      active: true,
      mellow_metadata: { "share_token" => "0xshare", "submitted_wallet" => wallet.address }.to_json
    )
    position.create_hedge!(target: "1", tolerance: "0.03", active: true, execution_venue: "extended")
    position
  end
end
