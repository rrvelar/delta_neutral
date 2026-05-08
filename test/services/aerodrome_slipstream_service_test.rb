require "test_helper"

class AerodromeSlipstreamServiceTest < ActiveSupport::TestCase
  RPC_URL = "https://base.example.com/rpc"
  POSITION_MANAGER = "0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53"
  FACTORY = "0xf8f2eb4940cfe7d13603dddd87f123820fc061ef"
  OWNER = "0x23cb5f48fa3f4502232f3442637f90e8e3355701"
  TOKEN0 = "0x22af33fe49fd1fa80c7149773dde5890d3c76f3b"
  TOKEN1 = "0x4200000000000000000000000000000000000006"
  POOL = "0x90757bd1595ca6e6a011e900e7a22d1a991856a5"

  setup do
    @service = AerodromeSlipstreamService.new(
      rpc_url: RPC_URL,
      position_manager_address: POSITION_MANAGER,
      factory_address: FACTORY
    )
  end

  test "ownerOf tokenId parsing" do
    stub_rpc(result: "0x#{word(OWNER)}")

    assert_equal OWNER, @service.owner_of(5016)
  end

  test "positions tokenId parsing uses tick spacing field" do
    stub_rpc(result: "0x#{position_words.join}")

    position = @service.position(5016)

    assert_equal TOKEN0, position.token0_address
    assert_equal TOKEN1, position.token1_address
    assert_equal 200, position.tick_spacing
    assert_equal(-151400, position.tick_lower)
    assert_equal(-147400, position.tick_upper)
    assert_equal 4_704_282_665_496_512_241_742, position.liquidity
    assert_equal 7, position.tokens_owed0_raw
    assert_equal 11, position.tokens_owed1_raw
  end

  test "factory and WETH9 parsing from position manager" do
    stub_rpc_results("0x#{word(FACTORY)}", "0x#{word(TOKEN1)}")

    assert_equal FACTORY, @service.position_manager_factory
    assert_equal TOKEN1, @service.position_manager_weth9
  end

  test "factory getPool parsing" do
    stub_rpc(result: "0x#{word(POOL)}")

    assert_equal POOL, @service.pool_for(TOKEN0, TOKEN1, 200)
  end

  test "factory getPool zero address fails clearly" do
    stub_rpc(result: "0x#{word(AerodromeSlipstreamService::ZERO_ADDRESS)}")

    error = assert_raises(AerodromeSlipstreamService::ZeroPoolError) do
      @service.pool_for(TOKEN0, TOKEN1, 200)
    end
    assert_match "zero pool address", error.message
  end

  test "slot0 parsing" do
    stub_rpc(result: "0x#{slot0_words.join}")

    pool = @service.pool_data(POOL)

    assert_equal POOL, pool.address
    assert_equal 32_678_154_748_101_184_656_879_789, pool.sqrt_price_x96
    assert_equal(-155876, pool.current_tick)
  end

  test "ERC20 decimals symbol and name parsing" do
    stub_rpc_results(
      "0x#{uint_word(18)}",
      encoded_string("AERO"),
      encoded_string("Aerodrome")
    )

    token = @service.token_data(TOKEN0)

    assert_equal TOKEN0, token.address
    assert_equal 18, token.decimals
    assert_equal "AERO", token.symbol
    assert_equal "Aerodrome", token.name
  end

  test "symbol and name failures fall back without guessing decimals" do
    stub_rpc_sequence(
      { result: "0x#{uint_word(18)}" },
      { error: { code: -32000, message: "symbol failed" } },
      { error: { code: -32000, message: "name failed" } }
    )

    token = @service.token_data(TOKEN0)

    assert_equal 18, token.decimals
    assert_equal "0x22af...6f3b", token.symbol
    assert_equal "0x22af...6f3b", token.name
  end

  test "malformed RPC response fails clearly" do
    stub_rpc(result: "0x1234")

    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.owner_of(5016)
    end
    assert_match "expected 1 ABI word", error.message
  end

  test "RPC response with non hex result fails clearly" do
    stub_rpc(result: "0xzz")

    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.owner_of(5016)
    end
    assert_match "not hex", error.message
  end

  test "RPC response with trailing partial ABI word fails clearly" do
    stub_rpc(result: "0x#{"0" * 65}")

    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.owner_of(5016)
    end
    assert_match "expected 1 ABI word", error.message
  end

  test "RPC missing result fails clearly" do
    stub_request(:post, RPC_URL)
      .to_return(status: 200, body: { jsonrpc: "2.0", id: 1 }.to_json, headers: { "Content-Type" => "application/json" })

    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.owner_of(5016)
    end
    assert_match "missing result", error.message
  end

  test "JSON-RPC error object fails clearly" do
    stub_rpc_sequence({ error: { code: -32000, message: "execution reverted" } })

    error = assert_raises(AerodromeSlipstreamService::RpcError) do
      @service.owner_of(5016)
    end
    assert_match "execution reverted", error.message
  end

  test "HTTP failure fails clearly" do
    stub_request(:post, RPC_URL).to_return(status: 503, body: "unavailable")

    error = assert_raises(AerodromeSlipstreamService::RpcError) do
      @service.owner_of(5016)
    end
    assert_match "HTTP 503", error.message
  end

  test "invalid JSON response fails clearly" do
    stub_request(:post, RPC_URL).to_return(status: 200, body: "not json")

    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.owner_of(5016)
    end
    assert_match "not valid JSON", error.message
  end

  test "missing config fails clearly" do
    without_env("BASE_RPC_URL", "AERODROME_SLIPSTREAM_POSITION_MANAGER", "AERODROME_SLIPSTREAM_FACTORY") do
      error = assert_raises(AerodromeSlipstreamService::ConfigError) do
        AerodromeSlipstreamService.new
      end
      assert_match "BASE_RPC_URL", error.message
    end
  end

  test "missing position manager config fails clearly" do
    without_env("AERODROME_SLIPSTREAM_POSITION_MANAGER") do
      error = assert_raises(AerodromeSlipstreamService::ConfigError) do
        AerodromeSlipstreamService.new(rpc_url: RPC_URL, factory_address: FACTORY)
      end
      assert_match "AERODROME_SLIPSTREAM_POSITION_MANAGER", error.message
    end
  end

  test "missing factory config fails clearly" do
    without_env("AERODROME_SLIPSTREAM_FACTORY") do
      error = assert_raises(AerodromeSlipstreamService::ConfigError) do
        AerodromeSlipstreamService.new(rpc_url: RPC_URL, position_manager_address: POSITION_MANAGER)
      end
      assert_match "AERODROME_SLIPSTREAM_FACTORY", error.message
    end
  end

  test "malformed RPC URL fails clearly" do
    error = assert_raises(AerodromeSlipstreamService::ConfigError) do
      AerodromeSlipstreamService.new(
        rpc_url: "not a url",
        position_manager_address: POSITION_MANAGER,
        factory_address: FACTORY
      )
    end
    assert_match "Malformed Aerodrome RPC URL", error.message
  end

  test "explicit constructor args override env config" do
    old_values = {
      "BASE_RPC_URL" => ENV["BASE_RPC_URL"],
      "AERODROME_SLIPSTREAM_POSITION_MANAGER" => ENV["AERODROME_SLIPSTREAM_POSITION_MANAGER"],
      "AERODROME_SLIPSTREAM_FACTORY" => ENV["AERODROME_SLIPSTREAM_FACTORY"]
    }
    ENV["BASE_RPC_URL"] = "https://wrong.example.com/rpc"
    ENV["AERODROME_SLIPSTREAM_POSITION_MANAGER"] = "0x0000000000000000000000000000000000000001"
    ENV["AERODROME_SLIPSTREAM_FACTORY"] = "0x0000000000000000000000000000000000000002"
    stub_rpc(result: "0x#{word(OWNER)}")
    service = AerodromeSlipstreamService.new(
      rpc_url: RPC_URL,
      position_manager_address: POSITION_MANAGER,
      factory_address: FACTORY
    )

    assert_equal OWNER, service.owner_of(5016)
    assert_not_requested :post, "https://wrong.example.com/rpc"
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end

  test "int24 values outside range fail before RPC" do
    error = assert_raises(AerodromeSlipstreamService::DecodeError) do
      @service.pool_for(TOKEN0, TOKEN1, 2**23)
    end
    assert_match "int24", error.message
    assert_not_requested :post, RPC_URL
  end

  test "fetch_position returns computed amount math" do
    stub_rpc_results(
      "0x#{word(OWNER)}",
      "0x#{position_words.join}",
      "0x#{word(POOL)}",
      "0x#{slot0_words.join}",
      "0x#{uint_word(18)}",
      encoded_string("AERO"),
      encoded_string("Aerodrome"),
      "0x#{uint_word(18)}",
      encoded_string("WETH"),
      encoded_string("Wrapped Ether")
    )

    position = @service.fetch_position(5016)

    assert_equal "5016", position.token_id
    assert_equal OWNER, position.owner_address
    assert_equal POSITION_MANAGER, position.position_manager_address
    assert_equal FACTORY, position.factory_address
    assert_equal POOL, position.pool_address
    assert_equal 1_652_885_551_720_891_062_632_623, position.amount0_raw
    assert_equal 0, position.amount1_raw
    assert_equal AerodromeSlipstreamService::VERIFIED_AMOUNT_MATH_SOURCE, position.verification_status
  end

  test "fetch_position fails clearly on malformed math input" do
    stub_rpc_results(
      "0x#{word(OWNER)}",
      "0x#{position_words.join}",
      "0x#{word(POOL)}",
      "0x#{slot0_words(sqrt_price_x96: 1).join}",
      "0x#{uint_word(18)}",
      encoded_string("AERO"),
      encoded_string("Aerodrome"),
      "0x#{uint_word(18)}",
      encoded_string("WETH"),
      encoded_string("Wrapped Ether")
    )

    error = assert_raises(AerodromeSlipstreamMath::Error) do
      @service.fetch_position(5016)
    end
    assert_match "sqrt_price_x96", error.message
  end

  test "service does not require private keys or call HyperliquidService" do
    stub_rpc_results(
      "0x#{word(OWNER)}",
      "0x#{position_words.join}",
      "0x#{word(POOL)}",
      "0x#{slot0_words.join}",
      "0x#{uint_word(18)}",
      encoded_string("AERO"),
      encoded_string("Aerodrome"),
      "0x#{uint_word(18)}",
      encoded_string("WETH"),
      encoded_string("Wrapped Ether")
    )

    without_env("HYPERLIQUID_PRIVATE_KEY", "HYPERLIQUID_WALLET_ADDRESS") do
      HyperliquidService.stub(:new, ->(*) { raise "HyperliquidService should not be called" }) do
        assert_equal "5016", @service.fetch_position(5016).token_id
      end
    end
  end

  private

  def stub_rpc(result:)
    stub_rpc_sequence({ result: result })
  end

  def stub_rpc_results(*results)
    stub_rpc_sequence(*results.map { |result| { result: result } })
  end

  def stub_rpc_sequence(*responses)
    stub_request(:post, RPC_URL).to_return(
      *responses.map do |response|
        body = { jsonrpc: "2.0", id: 1 }.merge(response).to_json
        { status: 200, body: body, headers: { "Content-Type" => "application/json" } }
      end
    )
  end

  def position_words(token0_address: TOKEN0, token1_address: TOKEN1, tick_lower: -151400, tick_upper: -147400, liquidity: 4_704_282_665_496_512_241_742)
    [
      uint_word(0),
      word(AerodromeSlipstreamService::ZERO_ADDRESS),
      word(token0_address),
      word(token1_address),
      int_word(200),
      int_word(tick_lower),
      int_word(tick_upper),
      uint_word(liquidity),
      uint_word(0),
      uint_word(0),
      uint_word(7),
      uint_word(11)
    ]
  end

  def slot0_words(sqrt_price_x96: 32_678_154_748_101_184_656_879_789, tick: -155876)
    [
      uint_word(sqrt_price_x96),
      int_word(tick),
      uint_word(0),
      uint_word(1),
      uint_word(1),
      uint_word(1)
    ]
  end

  def encoded_string(value)
    hex = value.unpack1("H*")
    "0x#{uint_word(32)}#{uint_word(value.bytesize)}#{hex.ljust(round_up(hex.length, 64), "0")}"
  end

  def round_up(value, multiple)
    ((value + multiple - 1) / multiple) * multiple
  end

  def word(address)
    address.delete_prefix("0x").downcase.rjust(64, "0")
  end

  def uint_word(value)
    value.to_i.to_s(16).rjust(64, "0")
  end

  def int_word(value)
    integer = value.to_i
    encoded = integer.negative? ? (2**256) + integer : integer
    encoded.to_s(16).rjust(64, "0")
  end

  def without_env(*keys)
    old_values = keys.to_h { |key| [ key, ENV[key] ] }
    keys.each { |key| ENV.delete(key) }
    yield
  ensure
    old_values.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end
