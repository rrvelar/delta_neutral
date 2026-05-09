require "eth"
require "net/http"

class AerodromeAeroUsdPrice
  class Error < StandardError; end
  class ConfigError < Error; end
  class RpcError < Error; end
  class DecodeError < Error; end

  PRICE_PRECISION = 50

  Result = Data.define(:price, :source, :warnings)

  def self.selector(signature)
    "0x#{Eth::Util.keccak256(signature).unpack1("H*")[0, 8]}"
  end

  SELECTORS = {
    token0: selector("token0()"),
    token1: selector("token1()"),
    slot0: selector("slot0()"),
    decimals: selector("decimals()")
  }.freeze

  def initialize(
    rpc_url: ENV["BASE_RPC_URL"].presence,
    pool_address: ENV["AERODROME_AERO_USDC_POOL_ADDRESS"].presence,
    aero_token_address: ENV["AERODROME_AERO_TOKEN_ADDRESS"].presence,
    usdc_token_address: ENV["AERODROME_USDC_ADDRESS"].presence,
    manual_price: ENV["AERODROME_AERO_USD_MANUAL_PRICE"].presence,
    valuation_enabled: ENV["AERODROME_AERO_USD_VALUATION_ENABLED"].to_s.downcase == "true"
  )
    @rpc_url = rpc_url
    @pool_address = pool_address
    @aero_token_address = normalize_address_or_nil(aero_token_address)
    @usdc_token_address = normalize_address_or_nil(usdc_token_address)
    @manual_price = manual_price
    @valuation_enabled = valuation_enabled
  end

  def price
    manual = manual_price_result
    return manual if manual
    return unavailable("AERO USD price source is not configured") unless @valuation_enabled
    return unavailable("AERODROME_AERO_USDC_POOL_ADDRESS is not configured") if @pool_address.blank?

    onchain_pool_price
  rescue Error => e
    unavailable(e.message)
  end

  private

  def manual_price_result
    return nil if @manual_price.blank?

    price = BigDecimal(@manual_price.to_s)
    return unavailable("AERODROME_AERO_USD_MANUAL_PRICE must be positive") unless price.positive?

    Result.new(price: price, source: "manual", warnings: [])
  rescue ArgumentError
    unavailable("AERODROME_AERO_USD_MANUAL_PRICE is not parseable")
  end

  def onchain_pool_price
    raise ConfigError, "BASE_RPC_URL is not configured" if @rpc_url.blank?
    raise ConfigError, "AERODROME_AERO_TOKEN_ADDRESS is not configured" if @aero_token_address.blank?
    raise ConfigError, "AERODROME_USDC_ADDRESS is not configured" if @usdc_token_address.blank?

    pool = normalize_address(@pool_address)
    token0 = decode_address(single_word_call(pool, SELECTORS.fetch(:token0)))
    token1 = decode_address(single_word_call(pool, SELECTORS.fetch(:token1)))
    unless [ token0, token1 ].sort == [ @aero_token_address, @usdc_token_address ].sort
      return unavailable("configured pool is not the configured AERO/USDC pair")
    end

    token0_decimals = uint_from_word(single_word_call(token0, SELECTORS.fetch(:decimals)))
    token1_decimals = uint_from_word(single_word_call(token1, SELECTORS.fetch(:decimals)))
    sqrt_price_x96 = uint_from_word(call_words(pool, SELECTORS.fetch(:slot0), expected_words: 6).first)
    token1_per_token0 = token1_per_token0_price(
      sqrt_price_x96: sqrt_price_x96,
      token0_decimals: token0_decimals,
      token1_decimals: token1_decimals
    )

    price =
      if token0 == @aero_token_address
        token1_per_token0
      else
        BigDecimal("1").div(token1_per_token0, PRICE_PRECISION)
      end
    Result.new(price: price, source: "aerodrome_pool", warnings: [])
  end

  def token1_per_token0_price(sqrt_price_x96:, token0_decimals:, token1_decimals:)
    raw_ratio = (BigDecimal(sqrt_price_x96) * BigDecimal(sqrt_price_x96))
      .div(BigDecimal(AerodromeSlipstreamMath::Q96) * BigDecimal(AerodromeSlipstreamMath::Q96), PRICE_PRECISION)

    raw_ratio * (BigDecimal(10)**token0_decimals) / (BigDecimal(10)**token1_decimals)
  end

  def unavailable(reason)
    Result.new(price: nil, source: "unavailable", warnings: [ reason ])
  end

  def eth_call(to, data)
    response = Net::HTTP.post(
      URI(@rpc_url),
      {
        jsonrpc: "2.0",
        method: "eth_call",
        params: [ { to: normalize_address(to), data: data }, "latest" ],
        id: 1
      }.to_json,
      "Content-Type" => "application/json"
    )
    raise RpcError, "AERO price RPC request failed: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise RpcError, "AERO price RPC error: #{parsed.dig('error', 'message')}" if parsed["error"]

    result = parsed["result"]
    raise DecodeError, "AERO price RPC response missing result" unless result.is_a?(String)
    raise DecodeError, "AERO price RPC response result is not hex" unless result.match?(/\A0x[0-9a-fA-F]*\z/)

    result
  rescue JSON::ParserError => e
    raise DecodeError, "AERO price RPC response is not valid JSON: #{e.message}"
  end

  def single_word_call(to, data)
    call_words(to, data, expected_words: 1).first
  end

  def call_words(to, data, expected_words:)
    body = eth_call(to, data).delete_prefix("0x")
    raise DecodeError, "AERO price RPC response expected #{expected_words} ABI word(s), got #{body.length / 64}" unless body.length == expected_words * 64

    body.scan(/.{64}/)
  end

  def normalize_address_or_nil(address)
    return nil if address.blank?

    normalize_address(address)
  rescue DecodeError
    nil
  end

  def normalize_address(address)
    value = address.to_s.downcase
    raise DecodeError, "Invalid EVM address: #{address.inspect}" unless value.match?(/\A0x[0-9a-f]{40}\z/)

    value
  end

  def decode_address(word)
    normalize_address("0x#{word[-40, 40]}")
  end

  def uint_from_word(word)
    word.to_i(16)
  end
end
