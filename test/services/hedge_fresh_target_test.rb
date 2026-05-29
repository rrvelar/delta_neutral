require "test_helper"

class HedgeFreshTargetTest < ActiveSupport::TestCase
  test "mellow target refreshes stale exposure and uses fresh asset0" do
    position = mellow_position(last_current_exposure_at: 10.minutes.ago)
    refresher = Refresher.new(position, status: "synced", asset0: "1.017", asset1: "530")

    result = HedgeFreshTarget.new(position: position, exposure_refresher: refresher).resolve

    assert_equal "ok", result.fetch(:status)
    assert_equal BigDecimal("1.017"), result.fetch(:target_short_eth)
    assert_equal true, result.fetch(:target_fresh)
    assert_equal "current_share_token_resolver", result.fetch(:target_source)
  end

  test "mellow target blocks when refresh cannot prove current exposure" do
    position = mellow_position(last_current_exposure_at: 10.minutes.ago)
    refresher = Refresher.new(position, status: "blocked")

    result = HedgeFreshTarget.new(position: position, exposure_refresher: refresher).resolve

    assert_equal "blocked", result.fetch(:status)
    assert_nil result.fetch(:target_short_eth)
    assert_equal false, result.fetch(:target_fresh)
    assert_includes result.fetch(:blockers), "fresh Mellow exposure required before hedge sizing"
  end

  private

  class Refresher
    def initialize(position, status:, asset0: nil, asset1: nil)
      @position = position
      @status = status
      @asset0 = asset0
      @asset1 = asset1
    end

    def refresh
      before = snapshot
      if @status == "synced"
        metadata = @position.mellow_metadata_hash.merge(
          "hedge_ready" => true,
          "last_probe_confidence" => "current_share_token_resolver_high",
          "exposure_source" => "current_share_token_resolver",
          "last_current_exposure_at" => Time.current.iso8601
        )
        @position.update!(asset0_amount: @asset0, asset1_amount: @asset1, mellow_metadata: metadata.to_json)
      end
      {
        status: @status,
        before: before,
        after: snapshot,
        blockers: @status == "synced" ? [] : [ "current share-token total WETH/USDC unavailable" ]
      }
    end

    def snapshot
      { asset0_amount: @position.asset0_amount&.to_s("F"), asset1_amount: @position.asset1_amount&.to_s("F") }
    end
  end

  def mellow_position(last_current_exposure_at:)
    wallet = Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: "0xe8a204e487a026c353cb1438c8d43aaf1e47d644")
    position = Position.create!(
      user: users(:one),
      wallet: wallet,
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "1.28366857878458",
      asset1_amount: "0",
      asset0_price_usd: "2500",
      asset1_price_usd: "1",
      active: true,
      mellow_metadata: {
        "hedge_ready" => true,
        "last_probe_confidence" => "current_share_token_resolver_high",
        "exposure_source" => "current_share_token_resolver",
        "last_current_exposure_at" => last_current_exposure_at.iso8601
      }.to_json
    )
    position.create_hedge!(target: "1.0", tolerance: "0.03", active: true, execution_venue: "extended")
    position
  end
end
