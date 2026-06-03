require "test_helper"

class AutoRebalanceRoutesTest < ActionDispatch::IntegrationTest
  test "auto settings helper exists and routes to settings update_auto" do
    assert_equal "/settings/auto", auto_settings_path
    assert_routing(
      { method: :patch, path: "/settings/auto" },
      { controller: "settings", action: "update_auto" }
    )
  end

  test "position auto rebalance helper exists and routes to positions auto_rebalance" do
    position = positions(:eth_usdc)

    assert_equal "/positions/#{position.id}/auto_rebalance", auto_rebalance_position_path(position)
    assert_routing(
      { method: :post, path: "/positions/#{position.id}/auto_rebalance" },
      { controller: "positions", action: "auto_rebalance", id: position.id.to_s }
    )
  end
end
