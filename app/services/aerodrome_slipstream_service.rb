require "eth"
require "net/http"

# Read-only JSON-RPC client for Aerodrome Slipstream positions on Base.
#
# This service never signs transactions, never requires private keys, and does
# not place approvals, transfers, swaps, or hedges.
class AerodromeSlipstreamService
  class Error < StandardError; end
  class ConfigError < Error; end
  class RpcError < Error; end
  class DecodeError < Error; end
  class ZeroPoolError < Error; end

  def self.selector(signature)
    "0x#{Eth::Util.keccak256(signature).unpack1("H*")[0, 8]}"
  end
  private_class_method :selector

  ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
  PARTIAL_AMOUNT_MATH_DEFERRED = "amount0/amount1 liquidity math deferred pending verified Slipstream formula"

  PositionData = Data.define(
    :token_id,
    :owner_address,
    :position_manager_address,
    :factory_address,
    :pool_address,
    :token0_address,
    :token1_address,
    :token0_decimals,
    :token1_decimals,
    :token0_symbol,
    :token1_symbol,
    :tick_spacing,
    :tick_lower,
    :tick_upper,
    :liquidity,
    :sqrt_price_x96,
    :current_tick,
    :tokens_owed0_raw,
    :tokens_owed1_raw,
    :amount0_raw,
    :amount1_raw,
    :partial_data_reason,
    :verification_status
  )

  TokenData = Data.define(:address, :decimals, :symbol, :name)
  PoolData = Data.define(:address, :sqrt_price_x96, :current_tick)
  RawPosition = Data.define(
    :nonce,
    :operator,
    :token0_address,
    :token1_address,
    :tick_spacing,
    :tick_lower,
    :tick_upper,
    :liquidity,
    :fee_growth_inside0_last_x128,
    :fee_growth_inside1_last_x128,
    :tokens_owed0_raw,
    :tokens_owed1_raw
  )

  SELECTORS = {
    owner_of: selector("ownerOf(uint256)"),
    positions: selector("positions(uint256)"),
    factory: selector("factory()"),
    weth9: selector("WETH9()"),
    get_pool: selector("getPool(address,address,int24)"),
    slot0: selector("slot0()"),
    decimals: selector("decimals()"),
    symbol: selector("symbol()"),
    name: selector("name()")
  }.freeze

  def initialize(rpc_url: nil, position_manager_address: nil, factory_address: nil)
    @rpc_url = presence_or_env(rpc_url, "BASE_RPC_URL")
    @position_manager_address = normalize_address(presence_or_env(position_manager_address, "AERODROME_SLIPSTREAM_POSITION_MANAGER"))
    @factory_address = normalize_address(presence_or_env(factory_address, "AERODROME_SLIPSTREAM_FACTORY"))
  end

  def fetch_position(token_id)
    owner = owner_of(token_id)
    raw_position = position(token_id)
    pool = pool_for(raw_position.token0_address, raw_position.token1_address, raw_position.tick_spacing)
    pool_data = pool_data(pool)
    token0 = token_data(raw_position.token0_address)
    token1 = token_data(raw_position.token1_address)

    PositionData.new(
      token_id: token_id.to_s,
      owner_address: owner,
      position_manager_address: @position_manager_address,
      factory_address: @factory_address,
      pool_address: pool,
      token0_address: raw_position.token0_address,
      token1_address: raw_position.token1_address,
      token0_decimals: token0.decimals,
      token1_decimals: token1.decimals,
      token0_symbol: token0.symbol,
      token1_symbol: token1.symbol,
      tick_spacing: raw_position.tick_spacing,
      tick_lower: raw_position.tick_lower,
      tick_upper: raw_position.tick_upper,
      liquidity: raw_position.liquidity,
      sqrt_price_x96: pool_data.sqrt_price_x96,
      current_tick: pool_data.current_tick,
      tokens_owed0_raw: raw_position.tokens_owed0_raw,
      tokens_owed1_raw: raw_position.tokens_owed1_raw,
      amount0_raw: nil,
      amount1_raw: nil,
      partial_data_reason: PARTIAL_AMOUNT_MATH_DEFERRED,
      verification_status: "partial"
    )
  end

  def owner_of(token_id)
    data = SELECTORS.fetch(:owner_of) + uint256_word(token_id)
    decode_address(single_word_call(@position_manager_address, data))
  end

  def position(token_id)
    data = SELECTORS.fetch(:positions) + uint256_word(token_id)
    words = call_words(@position_manager_address, data, expected_words: 12)

    RawPosition.new(
      nonce: uint_from_word(words[0]),
      operator: decode_address(words[1]),
      token0_address: decode_address(words[2]),
      token1_address: decode_address(words[3]),
      tick_spacing: int_from_word(words[4]),
      tick_lower: int_from_word(words[5]),
      tick_upper: int_from_word(words[6]),
      liquidity: uint_from_word(words[7]),
      fee_growth_inside0_last_x128: uint_from_word(words[8]),
      fee_growth_inside1_last_x128: uint_from_word(words[9]),
      tokens_owed0_raw: uint_from_word(words[10]),
      tokens_owed1_raw: uint_from_word(words[11])
    )
  end

  def position_manager_factory
    decode_address(single_word_call(@position_manager_address, SELECTORS.fetch(:factory)))
  end

  def position_manager_weth9
    decode_address(single_word_call(@position_manager_address, SELECTORS.fetch(:weth9)))
  end

  def pool_for(token0_address, token1_address, tick_spacing)
    data = SELECTORS.fetch(:get_pool) +
      address_word(token0_address) +
      address_word(token1_address) +
      int_word(tick_spacing)
    pool_address = decode_address(single_word_call(@factory_address, data))
    raise ZeroPoolError, "Aerodrome Slipstream factory returned zero pool address" if pool_address == ZERO_ADDRESS

    pool_address
  end

  def pool_data(pool_address)
    words = call_words(pool_address, SELECTORS.fetch(:slot0), expected_words: 6)

    PoolData.new(
      address: normalize_address(pool_address),
      sqrt_price_x96: uint_from_word(words[0]),
      current_tick: int_from_word(words[1])
    )
  end

  def token_data(token_address)
    address = normalize_address(token_address)

    TokenData.new(
      address: address,
      decimals: uint_from_word(single_word_call(address, SELECTORS.fetch(:decimals))),
      symbol: read_optional_string(address, SELECTORS.fetch(:symbol)),
      name: read_optional_string(address, SELECTORS.fetch(:name))
    )
  end

  private

  def presence_or_env(value, env_key)
    value.presence || ENV[env_key].presence || raise(ConfigError, "Missing required Aerodrome config: #{env_key}")
  end

  def eth_call(to, data)
    uri = URI(@rpc_url)
    response = Net::HTTP.post(
      uri,
      {
        jsonrpc: "2.0",
        method: "eth_call",
        params: [
          { to: normalize_address(to), data: data },
          "latest"
        ],
        id: 1
      }.to_json,
      "Content-Type" => "application/json"
    )

    raise RpcError, "Aerodrome RPC request failed: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise RpcError, "Aerodrome RPC error: #{parsed.dig("error", "message")}" if parsed["error"]

    result = parsed["result"]
    raise DecodeError, "Aerodrome RPC response missing result" unless result.is_a?(String) && result.start_with?("0x")

    result
  rescue JSON::ParserError => e
    raise DecodeError, "Aerodrome RPC response is not valid JSON: #{e.message}"
  end

  def single_word_call(to, data)
    words = call_words(to, data, expected_words: 1)
    words.first
  end

  def call_words(to, data, expected_words:)
    words = eth_call(to, data).delete_prefix("0x").scan(/.{64}/)
    unless words.size == expected_words && words.all? { |word| word.length == 64 }
      raise DecodeError, "Aerodrome RPC response expected #{expected_words} ABI word(s), got #{words.size}"
    end

    words
  end

  def read_optional_string(address, selector)
    decode_string(eth_call(address, selector))
  rescue Error
    short_address(address)
  end

  def decode_string(hex)
    body = hex.delete_prefix("0x")

    if body.length == 64
      return [ body ].pack("H*").delete("\u0000")
    end

    words = body.scan(/.{64}/)
    raise DecodeError, "Aerodrome string response is malformed" if words.size < 2

    offset = uint_from_word(words[0])
    raise DecodeError, "Aerodrome string response has unsupported offset #{offset}" unless offset == 32

    length = uint_from_word(words[1])
    data = body[128, length * 2]
    raise DecodeError, "Aerodrome string response has truncated data" unless data&.length == length * 2

    [ data ].pack("H*").force_encoding("UTF-8")
  end

  def normalize_address(address)
    value = address.to_s.downcase
    raise DecodeError, "Invalid EVM address: #{address.inspect}" unless value.match?(/\A0x[0-9a-f]{40}\z/)

    value
  end

  def decode_address(word)
    normalize_address("0x#{word[-40, 40]}")
  end

  def address_word(address)
    normalize_address(address).delete_prefix("0x").rjust(64, "0")
  end

  def uint256_word(value)
    uint_from_integer(value).to_s(16).rjust(64, "0")
  end

  def int_word(value)
    integer = Integer(value)
    encoded = integer.negative? ? (2**256) + integer : integer
    encoded.to_s(16).rjust(64, "0")
  end

  def uint_from_word(word)
    uint_from_integer(word.to_i(16))
  end

  def uint_from_integer(value)
    integer = Integer(value)
    raise DecodeError, "Expected unsigned integer, got #{value}" if integer.negative?

    integer
  end

  def int_from_word(word)
    integer = word.to_i(16)
    integer >= 2**255 ? integer - (2**256) : integer
  end

  def short_address(address)
    normalized = normalize_address(address)
    "#{normalized[0, 6]}...#{normalized[-4, 4]}"
  end
end
