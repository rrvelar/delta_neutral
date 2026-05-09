require "eth"
require "net/http"

class AerodromeRewardsService
  class Error < StandardError; end
  class ConfigError < Error; end
  class RpcError < Error; end
  class DecodeError < Error; end

  def self.selector(signature)
    "0x#{Eth::Util.keccak256(signature).unpack1("H*")[0, 8]}"
  end

  ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"

  RewardData = Data.define(
    :status,
    :pool_address,
    :gauge_address,
    :account_address,
    :token_id,
    :staked,
    :reward_token_address,
    :claimable_aero_raw,
    :claimable_aero,
    :claimable_aero_usd,
    :warnings,
    :blockers
  )

  SELECTORS = {
    gauges: selector("gauges(address)"),
    earned: selector("earned(address,uint256)"),
    reward_token: selector("rewardToken()"),
    decimals: selector("decimals()"),
    staked_contains: selector("stakedContains(address,uint256)")
  }.freeze

  def initialize(rpc_url: nil, voter_address: nil, aero_token_address: nil)
    @rpc_url = presence_or_env(rpc_url, "BASE_RPC_URL")
    @voter_address = normalize_address(presence_or_env(voter_address, "AERODROME_VOTER_ADDRESS"))
    @aero_token_address = aero_token_address.presence && normalize_address(aero_token_address)
  end

  def reward_state(pool_address:, account_address:, token_id:)
    normalized_pool = normalize_address(pool_address)
    normalized_account = normalize_address(account_address)
    gauge = gauge_for_pool(normalized_pool)
    return no_gauge(normalized_pool, normalized_account, token_id) if gauge == ZERO_ADDRESS

    reward_token = reward_token(gauge)
    staked = staked_contains(gauge, normalized_account, token_id)
    unless staked
      return RewardData.new(
        status: "not_staked",
        pool_address: normalized_pool,
        gauge_address: gauge,
        account_address: normalized_account,
        token_id: token_id.to_s,
        staked: false,
        reward_token_address: reward_token,
        claimable_aero_raw: 0,
        claimable_aero: BigDecimal("0"),
        claimable_aero_usd: nil,
        warnings: [ "position NFT is not staked in discovered CL gauge for wallet" ],
        blockers: []
      )
    end

    raw = earned(gauge, normalized_account, token_id)
    decimals = reward_decimals(reward_token)
    RewardData.new(
      status: "detected",
      pool_address: normalized_pool,
      gauge_address: gauge,
      account_address: normalized_account,
      token_id: token_id.to_s,
      staked: true,
      reward_token_address: reward_token,
      claimable_aero_raw: raw,
      claimable_aero: decimal_amount(raw, decimals),
      claimable_aero_usd: nil,
      warnings: aero_token_warnings(reward_token),
      blockers: []
    )
  rescue RpcError => e
    RewardData.new(
      status: "unavailable",
      pool_address: pool_address.to_s,
      gauge_address: nil,
      account_address: account_address.to_s,
      token_id: token_id.to_s,
      staked: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: [ "reward read unavailable: #{e.message}" ],
      blockers: []
    )
  end

  def gauge_for_pool(pool_address)
    data = SELECTORS.fetch(:gauges) + address_word(pool_address)
    decode_address(single_word_call(@voter_address, data))
  end

  def staked_contains(gauge_address, account_address, token_id)
    data = SELECTORS.fetch(:staked_contains) + address_word(account_address) + uint256_word(token_id)
    bool_from_word(single_word_call(gauge_address, data))
  rescue RpcError => e
    raise RpcError, "CLGauge stakedContains unsupported or failed: #{e.message}"
  end

  def earned(gauge_address, account_address, token_id)
    data = SELECTORS.fetch(:earned) + address_word(account_address) + uint256_word(token_id)
    uint_from_word(single_word_call(gauge_address, data))
  rescue RpcError => e
    raise RpcError, "CLGauge earned unsupported or failed: #{e.message}"
  end

  def reward_token(gauge_address)
    decode_address(single_word_call(gauge_address, SELECTORS.fetch(:reward_token)))
  rescue RpcError
    @aero_token_address || raise
  end

  def reward_decimals(token_address)
    uint_from_word(single_word_call(token_address, SELECTORS.fetch(:decimals)))
  end

  private

  def no_gauge(pool_address, account_address, token_id)
    RewardData.new(
      status: "not_configured",
      pool_address: pool_address,
      gauge_address: nil,
      account_address: account_address,
      token_id: token_id.to_s,
      staked: nil,
      reward_token_address: nil,
      claimable_aero_raw: nil,
      claimable_aero: nil,
      claimable_aero_usd: nil,
      warnings: [ "no CL gauge discovered for pool" ],
      blockers: []
    )
  end

  def aero_token_warnings(reward_token)
    return [] if @aero_token_address.blank? || reward_token == @aero_token_address

    [ "discovered reward token differs from configured AERODROME_AERO_TOKEN_ADDRESS" ]
  end

  def presence_or_env(value, env_key)
    value.presence || ENV[env_key].presence || raise(ConfigError, "Missing required Aerodrome rewards config: #{env_key}")
  end

  def eth_call(to, data)
    response = Net::HTTP.post(
      URI(@rpc_url),
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
    raise RpcError, "Aerodrome rewards RPC request failed: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise RpcError, "Aerodrome rewards RPC error: #{parsed.dig('error', 'message')}" if parsed["error"]

    result = parsed["result"]
    raise DecodeError, "Aerodrome rewards RPC response missing result" unless result.is_a?(String)
    raise DecodeError, "Aerodrome rewards RPC response result is not hex" unless result.match?(/\A0x[0-9a-fA-F]*\z/)

    result
  rescue JSON::ParserError => e
    raise DecodeError, "Aerodrome rewards RPC response is not valid JSON: #{e.message}"
  end

  def single_word_call(to, data)
    body = eth_call(to, data).delete_prefix("0x")
    raise DecodeError, "Aerodrome rewards RPC response expected 1 ABI word, got #{body.length / 64}" unless body.length == 64

    body
  end

  def normalize_address(address)
    value = address.to_s.downcase
    raise DecodeError, "Invalid EVM address: #{address.inspect}" unless value.match?(/\A0x[0-9a-f]{40}\z/)

    value
  end

  def address_word(address)
    normalize_address(address).delete_prefix("0x").rjust(64, "0")
  end

  def uint256_word(value)
    Integer(value).to_s(16).rjust(64, "0")
  end

  def uint_from_word(word)
    word.to_i(16)
  end

  def decode_address(word)
    normalize_address("0x#{word[-40, 40]}")
  end

  def bool_from_word(word)
    uint_from_word(word).positive?
  end

  def decimal_amount(raw, decimals)
    BigDecimal(raw.to_s) / (BigDecimal("10")**Integer(decimals))
  end
end
