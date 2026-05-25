require "test_helper"

class MellowUiParityRewardsTest < ActiveSupport::TestCase
  RPC_URL = "https://base.example.com/rpc"
  WALLET = "0xe8a204e487A026C353cB1438C8D43aAf1e47D644"
  RAW_RESULT = "0x000000000000000000000000000000000000000000000001618d43063904a59c"

  test "decodes candidate UI parity eth_call amount" do
    position = create_mellow_position
    stub_ui_parity_rpc(RAW_RESULT)

    result = MellowUiParityRewards.new(position: position, rpc_url: RPC_URL, expected_aero: "25.25").read

    assert_equal "mellow_ui_parity_eth_call", result.source
    assert_equal "estimated", result.status
    assert_equal "high", result.confidence
    assert_equal "Mellow share token / LpWrapper minimal proxy", result.contract_role
    assert_equal "0x79ee54f7", result.selector
    assert_equal "getRewards(address recipient)", result.selector_name
    assert_equal true, result.verified_selector
    assert_in_delta BigDecimal("25.4760923611"), result.amount, BigDecimal("0.0000000001")
    assert result.expected_delta_percent.abs < 5
  end

  test "mismatch against expected AERO is diagnostic by default" do
    position = create_mellow_position
    stub_ui_parity_rpc(RAW_RESULT)

    result = MellowUiParityRewards.new(position: position, rpc_url: RPC_URL, expected_aero: "1").read

    assert_equal "estimated", result.status
    assert_equal "high", result.confidence
    assert result.expected_delta_percent.abs > 5
  end

  test "strict expected AERO mismatch is unverified and excluded" do
    position = create_mellow_position
    stub_ui_parity_rpc(RAW_RESULT)

    with_env("STRICT_EXPECTED_AERO" => "true") do
      result = MellowUiParityRewards.new(position: position, rpc_url: RPC_URL, expected_aero: "1").read

      assert_equal "unverified_mismatch", result.status
      assert_equal "low", result.confidence
      assert_match "does not match", result.stop_reason
    end
  end

  test "zero result remains unverified mismatch" do
    position = create_mellow_position
    stub_ui_parity_rpc("0x#{"0".rjust(64, "0")}")

    result = MellowUiParityRewards.new(position: position, rpc_url: RPC_URL, expected_aero: "25.25").read

    assert_equal "unverified_mismatch", result.status
    assert_equal "low", result.confidence
  end

  test "encodes submitted wallet argument" do
    position = create_mellow_position
    service = MellowUiParityRewards.new(position: position, rpc_url: RPC_URL)

    assert_equal "0x79ee54f7000000000000000000000000e8a204e487a026c353cb1438c8d43aaf1e47d644", service.call_data(WALLET)
  end

  test "eth_call payload includes from submitted wallet" do
    position = create_mellow_position
    stub_ui_parity_rpc(RAW_RESULT)

    MellowUiParityRewards.new(position: position, rpc_url: RPC_URL, expected_aero: "25.25").read

    assert_requested :post, RPC_URL do |request|
      call = JSON.parse(request.body).fetch("params").first
      assert_equal WALLET.downcase, call.fetch("from")
      assert_equal MellowUiParityRewards::CONTRACT_ADDRESS, call.fetch("to")
      assert_equal "0x79ee54f7000000000000000000000000e8a204e487a026c353cb1438c8d43aaf1e47d644", call.fetch("data")
    end
  end

  private

  def stub_ui_parity_rpc(result)
    stub_request(:post, RPC_URL).to_return(
      status: 200,
      body: { jsonrpc: "2.0", id: 1, result: result }.to_json,
      headers: { "Content-Type" => "application/json" }
    )
  end

  def with_env(values)
    old_values = values.keys.to_h { |key| [ key, ENV[key] ] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old_values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def create_mellow_position
    Position.create!(
      user: users(:one),
      wallet: Wallet.find_or_create_by!(user: users(:one), network: networks(:base), address: WALLET),
      dex: Dex.find_or_create_by!(name: "aerodrome_slipstream"),
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:71261528",
      pool_address: "0x90757bd1595ca6e6a011e900e7a22d1a991856a5",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: BigDecimal("0.61"),
      asset1_amount: BigDecimal("1386"),
      asset0_price_usd: BigDecimal("2100"),
      asset1_price_usd: BigDecimal("1"),
      active: true,
      mellow_metadata: JSON.generate(
        "strategy_token_id" => "71261528",
        "submitted_wallet" => WALLET,
        "share_token" => MellowUiParityRewards::CONTRACT_ADDRESS,
        "user_share_percent" => "0.156",
        "user_weth_exposure" => "1.56",
        "strategy_total_weth" => "1000",
        "hedge_ready" => true,
        "last_probe_confidence" => "high"
      )
    )
  end
end
