require "test_helper"

class MellowAutopilotPositionProbeTest < ActiveSupport::TestCase
  test "handles successful api response with WETH and USDC amounts" do
    client = HttpMock.new(
      "/users/0xabc" => {
        positions: [
          {
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
      assert_equal "0.42", position.fetch(:weth_amount)
      assert_equal "234.56", position.fetch(:usdc_amount)
      assert_equal "1234.56", position.fetch(:total_value_usd)
    end
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
