require "test_helper"

class MellowAutopilotPositionProbeTest < ActiveSupport::TestCase
  test "direct token id remains hedgeable with WETH and USDC amounts" do
    client = HttpMock.new(
      "/users/0xabc" => {
        positions: [
          {
            type: "direct_lp_nft",
            owner: "0xabc",
            tokenId: "71141789",
            vaultAddress: "0xvault",
            vaultName: "Mellow WETH/USDC Autopilot",
            shareAmount: "12.5",
            totalValueUsd: "1234.56",
            underlyingTokens: [
              { symbol: "WETH", amount: "0.42", valueUsd: "1000" },
              { symbol: "USDC", amount: "234.56", valueUsd: "234.56" }
            ]
          }
        ]
      },
      "/defi/users/0xabc" => { positions: [] }
    )

    assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
      report = MellowAutopilotPositionProbe.new(wallet_address: "0xabc", http_client: client, api_base_url: "").report

      assert_equal false, report.fetch(:database_write)
      assert_equal true, report.fetch(:external_api)
      assert_empty report.fetch(:blockers)
      assert_equal true, report.fetch(:hedge_target_computable)
      position = report.fetch(:positions).first
      assert_equal "direct_lp_nft", position.fetch(:position_type)
      assert_equal true, position.fetch(:hedgeable)
      assert_equal "0.42", position.fetch(:weth_amount)
      assert_equal "234.56", position.fetch(:usdc_amount)
      assert_equal "1234.56", position.fetch(:total_value_usd)
    end
  end

  test "shared strategy token id is not hedgeable without shares" do
    client = HttpMock.new(
      "/users/0xabc" => {
        positions: [
          {
            type: "autopilot_strategy",
            strategyTokenId: "70927538",
            managerAddress: "0xmanager",
            vaultAddress: "0xvault",
            vaultName: "Shared Autopilot Strategy",
            underlyingTokens: [
              { symbol: "WETH", amount: "10.0" },
              { symbol: "USDC", amount: "5000.0" }
            ]
          }
        ]
      },
      "/defi/users/0xabc" => { positions: [] }
    )

    report = MellowAutopilotPositionProbe.new(wallet_address: "0xabc", http_client: client, api_base_url: "").report

    assert_equal false, report.fetch(:hedge_target_computable)
    assert_includes report.fetch(:blockers), "Cannot hedge: token_id appears to be a shared Autopilot/Mellow strategy position; user pro-rata WETH exposure is unknown."
    position = report.fetch(:positions).first
    assert_equal "shared_strategy", position.fetch(:position_type)
    assert_equal "70927538", position.fetch(:strategy_token_id)
    assert_equal false, position.fetch(:hedgeable)
    assert_nil position.fetch(:weth_amount)
  end

  test "shared strategy token id is hedgeable with pro rata shares and underlying WETH" do
    client = HttpMock.new(
      "/users/0xabc" => {
        positions: [
          {
            type: "autopilot_strategy",
            strategyTokenId: "70927538",
            managerAddress: "0xmanager",
            vaultAddress: "0xvault",
            vaultName: "Shared Autopilot Strategy",
            userShares: "25",
            totalShares: "100",
            strategyWethAmount: "4.0",
            strategyUsdcAmount: "2000.0"
          }
        ]
      },
      "/defi/users/0xabc" => { positions: [] }
    )

    report = MellowAutopilotPositionProbe.new(wallet_address: "0xabc", http_client: client, api_base_url: "").report

    assert_empty report.fetch(:blockers)
    assert_equal true, report.fetch(:hedge_target_computable)
    position = report.fetch(:positions).first
    assert_equal "shared_strategy", position.fetch(:position_type)
    assert_equal true, position.fetch(:hedgeable)
    assert_equal "1.0", position.fetch(:weth_amount)
    assert_equal "500.0", position.fetch(:usdc_amount)
    assert_equal "25.0", position.fetch(:receipt_share_amount)
    assert_equal "100.0", position.fetch(:total_shares)
  end

  test "blocks when only shares are available" do
    client = HttpMock.new(
      "/users/0xabc" => {
        vaults: [
          { vaultAddress: "0xvault", vaultName: "Shares only", shares: "12.5" }
        ]
      },
      "/defi/users/0xabc" => { positions: [] }
    )

    report = MellowAutopilotPositionProbe.new(wallet_address: "0xabc", http_client: client, api_base_url: "").report

    assert_equal false, report.fetch(:hedge_target_computable)
    assert_includes report.fetch(:blockers), "Cannot hedge: underlying WETH exposure unavailable."
    assert_includes report.fetch(:warnings), "Only vault/share balance is available; underlying token exposure is missing."
  end

  test "handles api failure" do
    client = HttpMock.new("/users/0xabc" => HttpResponse.new(500, "down"))

    report = MellowAutopilotPositionProbe.new(wallet_address: "0xabc", http_client: client, api_base_url: "").report

    assert_equal false, report.fetch(:hedge_target_computable)
    assert_match "Mellow Autopilot probe failed", report.fetch(:blockers).first
  end

  private

  class HttpResponse
    attr_reader :code, :body

    def initialize(code, body)
      @code = code.to_s
      @body = body
    end
  end

  class HttpMock
    def initialize(responses)
      @responses = responses
    end

    def get(uri)
      response = @responses.fetch(uri.path) { raise "unexpected path #{uri.path}" }
      return response if response.is_a?(HttpResponse)

      HttpResponse.new(200, JSON.generate(response))
    end
  end
end
