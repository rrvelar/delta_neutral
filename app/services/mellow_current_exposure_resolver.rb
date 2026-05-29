require "net/http"
require "uri"

class MellowCurrentExposureResolver
  WETH_ADDRESS = AerodromeAutopilotTransactionProbe::WETH_ADDRESS
  USDC_ADDRESS = AerodromeAutopilotTransactionProbe::USDC_ADDRESS
  ZERO_ADDRESS = AerodromeAutopilotTransactionProbe::ZERO_ADDRESS
  SELECTORS = {
    balance_of: "0x70a08231",
    total_supply: "0x18160ddd",
    decimals: "0x313ce567",
    token0: "0x0dfe1681",
    token1: "0xd21220a7",
    pool: "0x16f0115b",
    vault: "0xfbfa77cf",
    strategy: "0x4a1d70a1",
    core: "0xf2f4eb26",
    position_id: "0x71640de3",
    preview_mint: "0xb3d7f6b9",
    get_total_amounts: "0x1f2c4092",
    total_amounts: "0x0c6ffc29",
    total_assets: "0x01e1d114",
    underlying_tvl: "0x079c3b88",
    tvl: "0xe5328e06",
    get_tvl: "0xd075dd42"
  }.freeze
  CURRENT_TOTAL_AMOUNT_METHODS = {
    preview_mint: "previewMint(uint256)",
    get_total_amounts: "getTotalAmounts()",
    total_amounts: "totalAmounts()",
    underlying_tvl: "underlyingTvl()",
    tvl: "tvl()",
    get_tvl: "getTvl()"
  }.freeze

  def initialize(position:, share_token: nil, submitted_wallet: nil, strategy_pool_address: nil, token0: nil, token1: nil, rpc_url: nil, eth_call_results: {})
    @position = position
    @metadata = position.mellow_metadata_hash
    @share_token = normalize_address(share_token.presence || @metadata["share_token"])
    @submitted_wallet = normalize_address(submitted_wallet.presence || @metadata["submitted_wallet"].presence || position.wallet&.address)
    @strategy_pool_address = normalize_address(strategy_pool_address.presence || @metadata["strategy_pool_address"])
    @token0 = normalize_address(token0.presence || @metadata["strategy_token0"])
    @token1 = normalize_address(token1.presence || @metadata["strategy_token1"])
    @rpc_url = rpc_url
    @eth_call_results = eth_call_results
    @injected_eth_call_results = eth_call_results.present?
    @attempted_methods = []
  end

  def resolve
    blockers = missing_input_blockers
    return blocked(blockers) if blockers.present?

    share_decimals = read_uint(@share_token, :decimals)&.to_i || 18
    user_balance_raw = read_uint_call(@share_token, SELECTORS.fetch(:balance_of) + address_word(@submitted_wallet))
    total_supply_raw = read_uint(@share_token, :total_supply)
    return blocked([ "share token user balance unavailable" ]) if user_balance_raw.blank?
    return blocked([ "share token total supply unavailable" ]) if total_supply_raw.blank?

    user_balance = decimal_amount(user_balance_raw, share_decimals)
    total_supply = decimal_amount(total_supply_raw, share_decimals)
    return blocked([ "share token user balance is zero" ]) unless user_balance.positive?
    return blocked([ "share token total supply is zero" ]) unless total_supply.positive?

    token0 = read_address_method(@share_token, :token0) || @token0
    token1 = read_address_method(@share_token, :token1) || @token1
    pool = read_address_method(@share_token, :pool) || @strategy_pool_address
    contract_addresses = discovered_contract_addresses
    user_amounts = read_user_amounts(contract_addresses, user_balance_raw, token0, token1)
    total_amounts = read_total_amounts(contract_addresses, total_supply_raw, token0, token1)
    return blocked([ "current share-token total WETH/USDC unavailable" ], user_balance: user_balance, total_supply: total_supply, token0: token0, token1: token1, pool: pool) unless user_amounts || total_amounts

    share_fraction = user_balance / total_supply
    strategy_weth = total_amounts&.fetch(:weth, nil)
    strategy_usdc = total_amounts&.fetch(:usdc, nil)
    user_weth = user_amounts&.fetch(:weth, nil) || strategy_weth * share_fraction
    user_usdc = user_amounts&.fetch(:usdc, nil) || (strategy_usdc ? strategy_usdc * share_fraction : nil)
    strategy_weth ||= user_weth / share_fraction
    strategy_usdc ||= user_usdc / share_fraction

    {
      status: "ok",
      exposure_source: "current_share_token_resolver",
      share_token: @share_token,
      submitted_wallet: @submitted_wallet,
      user_share_balance: user_balance.to_s("F"),
      total_supply: total_supply.to_s("F"),
      total_shares: total_supply.to_s("F"),
      share_fraction: share_fraction.to_s("F"),
      user_share_percent: (share_fraction * 100).to_s("F"),
      strategy_total_weth: strategy_weth&.to_s("F"),
      strategy_total_usdc: strategy_usdc&.to_s("F"),
      user_weth_exposure: user_weth&.to_s("F"),
      user_usdc_exposure: user_usdc&.to_s("F"),
      user_total_value_usd: user_total_value_usd(user_weth, user_usdc)&.to_s("F"),
      strategy_pool_address: pool,
      strategy_token0: token0,
      strategy_token1: token1,
      stale_strategy_token_id: stale_strategy_token_id,
      successful_contract: successful_attempt&.dig(:contract),
      successful_method: successful_attempt&.dig(:method),
      attempted_methods: @attempted_methods,
      diagnostics: diagnostics(contract_addresses, token0, token1, pool),
      blockers: [],
      warnings: warnings,
      orders_submitted: 0,
      signatures_created: 0
    }
  rescue => e
    blocked([ "Mellow current exposure resolver failed: #{e.class}: #{e.message}" ])
  end

  private

  def missing_input_blockers
    blockers = []
    blockers << "share token is required" if @share_token.blank?
    blockers << "submitted wallet is required" if @submitted_wallet.blank?
    blockers
  end

  def read_user_amounts(addresses, user_balance_raw, token0, token1)
    addresses.each do |address|
      amounts = read_preview_mint(address, user_balance_raw, token0, token1)
      return amounts if amounts&.dig(:weth).present?
    end
    nil
  end

  def read_total_amounts(addresses, total_supply_raw, token0, token1)
    addresses.each do |address|
      preview = read_preview_mint(address, total_supply_raw, token0, token1)
      return preview if preview&.dig(:weth).present?

      CURRENT_TOTAL_AMOUNT_METHODS.each_key do |method|
        next if method == :preview_mint

        raw = read_two_uints_with_attempt(address, method)
        next unless raw

        amounts = token_amounts_from_raw(raw, token0, token1)
        return amounts if amounts[:weth].present?
      end
    end
    nil
  end

  def read_preview_mint(address, raw_amount, token0, token1)
    raw = read_two_uints_with_attempt(address, :preview_mint, encoded_arg: uint_word(raw_amount))
    return nil unless raw

    token_amounts_from_raw(raw, token0, token1)
  end

  def discovered_contract_addresses
    addresses = [ @share_token ]
    [ :strategy, :vault, :core ].each do |selector|
      address = read_address_method(@share_token, selector)
      addresses << address if useful_address?(address)
    end
    addresses.compact.uniq
  end

  def read_two_uints_with_attempt(address, selector_key, encoded_arg: "")
    selector = SELECTORS.fetch(selector_key)
    result = eth_call(address, selector + encoded_arg)
    ok = result&.match?(/\A0x[0-9a-fA-F]{128}\z/)
    @attempted_methods << {
      contract: normalize_address(address),
      method: CURRENT_TOTAL_AMOUNT_METHODS.fetch(selector_key),
      selector: selector,
      status: ok ? "ok" : "unavailable"
    }
    return nil unless ok

    body = result.delete_prefix("0x")
    { amount0: body[0, 64].to_i(16).to_s, amount1: body[64, 64].to_i(16).to_s }
  rescue => e
    @attempted_methods << {
      contract: normalize_address(address),
      method: CURRENT_TOTAL_AMOUNT_METHODS.fetch(selector_key),
      selector: SELECTORS.fetch(selector_key),
      status: "error",
      error: "#{e.class}: #{e.message}"
    }
    nil
  end

  def token_amounts_from_raw(raw_amounts, token0, token1)
    amount0 = decimal_token_amount(raw_amounts[:amount0], token0)
    amount1 = decimal_token_amount(raw_amounts[:amount1], token1)
    {
      weth: weth_token?(token0) ? amount0 : (weth_token?(token1) ? amount1 : nil),
      usdc: usdc_token?(token0) ? amount0 : (usdc_token?(token1) ? amount1 : nil)
    }
  end

  def user_total_value_usd(user_weth, user_usdc)
    price = @position.asset0_price_usd || @metadata["weth_price_usd"]
    return nil unless user_weth && user_usdc && price.present?

    (user_weth * BigDecimal(price.to_s)) + user_usdc
  rescue ArgumentError
    nil
  end

  def diagnostics(contract_addresses, token0, token1, pool)
    {
      verified_source_hint: "BaseScan verified LpWrapper exposes previewMint(uint256), positionId(), pool(), token0(), token1()",
      contracts_checked: contract_addresses,
      token0: token0,
      token1: token1,
      pool: pool,
      attempted_methods_count: @attempted_methods.size
    }
  end

  def warnings
    [ "Exposure is derived from current share-token accounting; historical deposit amounts are not used." ]
  end

  def blocked(blockers, user_balance: nil, total_supply: nil, token0: nil, token1: nil, pool: nil)
    {
      status: "blocked",
      exposure_source: "current_share_token_resolver",
      share_token: @share_token,
      submitted_wallet: @submitted_wallet,
      user_share_balance: user_balance&.to_s("F"),
      total_supply: total_supply&.to_s("F"),
      total_shares: total_supply&.to_s("F"),
      share_fraction: user_balance && total_supply&.positive? ? (user_balance / total_supply).to_s("F") : nil,
      user_share_percent: user_balance && total_supply&.positive? ? ((user_balance / total_supply) * 100).to_s("F") : nil,
      strategy_pool_address: pool || @strategy_pool_address,
      strategy_token0: token0 || @token0,
      strategy_token1: token1 || @token1,
      stale_strategy_token_id: stale_strategy_token_id,
      attempted_methods: @attempted_methods,
      diagnostics: { attempted_methods_count: @attempted_methods.size },
      blockers: blockers,
      warnings: warnings,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def successful_attempt
    @attempted_methods.find { |attempt| attempt[:status] == "ok" }
  end

  def stale_strategy_token_id
    @metadata["strategy_token_id"].presence || @position.external_id.to_s.delete_prefix("mellow:")
  end

  def read_balance_of(address, user_wallet, decimals)
    raw = read_uint_call(address, SELECTORS.fetch(:balance_of) + address_word(user_wallet))
    raw && BigDecimal(raw) / BigDecimal(10**decimals)
  end

  def read_uint(address, selector_key)
    read_uint_call(address, SELECTORS.fetch(selector_key))
  end

  def read_uint_call(address, data)
    result = eth_call(address, data)
    return nil unless result&.match?(/\A0x[0-9a-fA-F]{64}\z/)

    result.delete_prefix("0x").to_i(16).to_s
  rescue
    nil
  end

  def read_address_method(address, selector_key)
    result = eth_call(address, SELECTORS.fetch(selector_key))
    return nil unless result&.match?(/\A0x[0-9a-fA-F]{64}\z/)

    topic_address(result)
  rescue
    nil
  end

  def eth_call(address, data)
    key = [ normalize_address(address), data.downcase ]
    return @eth_call_results[key] if @eth_call_results.key?(key)
    return nil if @injected_eth_call_results

    raise "BASE_RPC_URL is not configured" if rpc_url.blank?

    uri = URI(rpc_url)
    response = Net::HTTP.post(
      uri,
      { jsonrpc: "2.0", method: "eth_call", params: [ { to: normalize_address(address), data: data }, "latest" ], id: 1 }.to_json,
      "Content-Type" => "application/json"
    )
    return nil unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    parsed["result"]
  rescue
    nil
  end

  def rpc_url
    @rpc_url || ENV["BASE_RPC_URL"].presence
  end

  def useful_address?(address)
    address.present? && !same_address?(address, ZERO_ADDRESS)
  end

  def decimal_token_amount(raw_amount, address)
    decimals = usdc_token?(address) ? 6 : 18
    BigDecimal(raw_amount) / BigDecimal(10**decimals)
  end

  def decimal_amount(raw_amount, decimals)
    BigDecimal(raw_amount) / BigDecimal(10**decimals)
  end

  def uint_word(value)
    value.to_i.to_s(16).rjust(64, "0")
  end

  def address_word(address)
    normalize_address(address).delete_prefix("0x").rjust(64, "0")
  end

  def topic_address(topic)
    "0x#{topic.to_s.delete_prefix('0x')[-40, 40]}".downcase
  end

  def normalize_address(address)
    address.to_s.downcase.presence
  end

  def same_address?(a, b)
    normalize_address(a) == normalize_address(b)
  end

  def weth_token?(address)
    same_address?(address, WETH_ADDRESS)
  end

  def usdc_token?(address)
    same_address?(address, USDC_ADDRESS)
  end
end
