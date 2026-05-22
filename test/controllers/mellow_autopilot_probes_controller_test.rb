require "test_helper"

class MellowAutopilotProbesControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in_as(users(:one))
  end

  test "renders probe form" do
    get mellow_autopilot_probe_path

    assert_response :success
    assert_match "Mellow Autopilot Probe", response.body
    assert_select "input[name='wallet_address']"
    assert_select "input[name='vault_address']"
    assert_select "input[name='network']"
  end

  test "renders probe results" do
    report = {
      source: "Mellow official points API",
      network: "base",
      hedge_target_computable: true,
      blockers: [],
      warnings: [],
      positions: [
        {
          vault_name: "Mellow WETH/USDC Autopilot",
          vault_identifier: "vault-1",
          vault_address: "0xvault",
          receipt_share_amount: "12.5",
          weth_amount: "0.42",
          usdc_amount: "234.56",
          total_value_usd: "1234.56"
        }
      ]
    }

    MellowAutopilotPositionProbe.stub(:new, ->(**) { ProbeMock.new(report) }) do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_no_difference [ "Position.count", "Hedge.count", "ShortRebalance.count" ] do
          get mellow_autopilot_probe_path, params: { wallet_address: "0xabc", vault_address: "0xvault" }
        end
      end
    end

    assert_response :success
    assert_match "Mellow WETH/USDC Autopilot", response.body
    assert_match "0.42", response.body
    assert_match "234.56", response.body
    assert_match "$1,234.56", response.body
    assert_match "hedge target computable", response.body
  end

  private

  class ProbeMock
    def initialize(report)
      @report = report
    end

    def report
      @report
    end
  end
end
