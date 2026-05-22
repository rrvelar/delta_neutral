require "net/http"
require "uri"

class AerodromeAutopilotTransactionProbe
  TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  SLIPSTREAM_POSITION_MANAGER = "0x827922686190790b37229fd06084350e74485b72"
  WETH_ADDRESS = "0x4200000000000000000000000000000000000006"
  USDC_ADDRESS = "0x833589fcd6edb6e08f4c7c32d4f71b54bdA02913"
  AERO_ADDRESS = "0x940181a94A35A4569E4529A3CDfB74e38FD98631"
  ZEROISH_INTERMEDIATE_PREFIX = "0x0000000c"
  ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
  SELECTORS = {
    total_supply: "0x18160ddd",
    balance_of: "0x70a08231",
    symbol: "0x95d89b41",
    name: "0x06fdde03",
    decimals: "0x313ce567",
    token0: "0x0dfe1681",
    token1: "0xd21220a7",
    get_total_amounts: "0x1f2c4092",
    total_assets: "0x01e1d114",
    vault: "0xfbfa77cf",
    strategy: "0x4a1d70a1",
    pool: "0x16f0115b"
  }.freeze

  def initialize(tx_hash:, network: "base", wallet_address: nil, rpc_url: nil, receipt: nil, eth_call_results: {})
    @tx_hash = tx_hash.to_s.strip
    @network = network.to_s.presence || "base"
    @submitted_wallet = wallet_address.to_s.strip.presence
    @rpc_url = rpc_url
    @receipt = receipt
    @eth_call_results = eth_call_results
  end

  def report
    return blank_report(blockers: [ "transaction hash is required" ]) if @tx_hash.blank?

    receipt = @receipt || fetch_receipt
    erc20_transfers = parse_erc20_transfers(receipt)
    nft_transfers = parse_slipstream_transfers(receipt)
    classification = classify(nft_transfers)
    depositor = detected_depositor_wallet(erc20_transfers)
    user_wallet = @submitted_wallet || depositor
    intermediate = intermediate_contracts(nft_transfers)
    pools = pool_contracts(erc20_transfers, user_wallet)
    share_tokens = candidate_share_tokens(erc20_transfers, user_wallet)
    strategy_reads = strategy_contract_reads(intermediate + detected_contracts(erc20_transfers, nft_transfers, user_wallet))
    exposure = pro_rata_exposure(share_tokens, strategy_reads)
    blockers = []
    if classification == "autopilot_shared_strategy" && exposure[:user_weth_exposure].nil?
      blockers << "Cannot hedge: user pro-rata WETH exposure is unknown."
    elsif erc20_transfers.none? { |transfer| transfer[:symbol] == "WETH" }
      blockers << "Cannot hedge: user WETH deposit amount unavailable."
    end

    {
      database_write: false,
      external_api: @receipt.nil?,
      network: @network,
      tx_hash: @tx_hash,
      classification: classification,
      hedgeable: blockers.empty? && (classification == "direct_lp_nft" || exposure[:user_weth_exposure].present?),
      submitted_wallet: @submitted_wallet,
      detected_depositor_wallet: depositor,
      router_or_manager_contracts: detected_contracts(erc20_transfers, nft_transfers, user_wallet),
      intermediate_contracts: intermediate,
      pool_or_gauge_contracts: pools,
      pool_address: pools.first,
      strategy_token_ids: nft_transfers.map { |transfer| transfer[:token_id] }.uniq,
      user_deposit_amounts: user_deposit_amounts(erc20_transfers, user_wallet),
      candidate_share_tokens: share_tokens,
      strategy_contract_reads: strategy_reads,
      pro_rata_exposure: exposure,
      erc20_transfers: erc20_transfers,
      slipstream_nft_transfers: nft_transfers,
      blockers: blockers,
      warnings: warnings(classification)
    }
  rescue => e
    blank_report(blockers: [ "Aerodrome Autopilot transaction probe failed: #{e.class}: #{e.message}" ])
  end

  private

  def blank_report(blockers:)
    {
      database_write: false,
      external_api: @receipt.nil?,
      network: @network,
      tx_hash: @tx_hash,
      classification: "unknown",
      hedgeable: false,
      submitted_wallet: @submitted_wallet,
      detected_depositor_wallet: nil,
      router_or_manager_contracts: [],
      intermediate_contracts: [],
      pool_or_gauge_contracts: [],
      pool_address: nil,
      strategy_token_ids: [],
      user_deposit_amounts: {},
      candidate_share_tokens: [],
      strategy_contract_reads: [],
      pro_rata_exposure: { user_weth_exposure: nil, user_usdc_exposure: nil, confidence: "unavailable" },
      erc20_transfers: [],
      slipstream_nft_transfers: [],
      blockers: blockers,
      warnings: []
    }
  end

  def fetch_receipt
    raise "BASE_RPC_URL is not configured" if rpc_url.blank?

    uri = URI(rpc_url)
    response = Net::HTTP.post(
      uri,
      { jsonrpc: "2.0", method: "eth_getTransactionReceipt", params: [ @tx_hash ], id: 1 }.to_json,
      "Content-Type" => "application/json"
    )
    raise "Base RPC request failed: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise "Base RPC error: #{parsed.dig('error', 'message')}" if parsed["error"]
    raise "transaction receipt not found" unless parsed["result"]

    parsed["result"]
  end

  def rpc_url
    @rpc_url || ENV["BASE_RPC_URL"].presence
  end

  def parse_erc20_transfers(receipt)
    logs(receipt).filter_map do |log|
      next unless log.dig("topics", 0).to_s.downcase == TRANSFER_TOPIC
      next unless log.fetch("topics", []).size == 3

      symbol = token_symbol(log["address"]) || "UNKNOWN"

      decimals = token_decimals(symbol)
      amount = BigDecimal(log["data"].to_s.delete_prefix("0x").to_i(16)) / BigDecimal(10**decimals)
      {
        symbol: symbol,
        token_address: normalize_address(log["address"]),
        from: topic_address(log.dig("topics", 1)),
        to: topic_address(log.dig("topics", 2)),
        amount: amount.to_s("F"),
        raw_amount: log["data"].to_s.delete_prefix("0x").to_i(16).to_s,
        decimals: decimals,
        known_token: symbol != "UNKNOWN"
      }
    end
  end

  def parse_slipstream_transfers(receipt)
    logs(receipt).filter_map do |log|
      next unless same_address?(log["address"], SLIPSTREAM_POSITION_MANAGER)
      next unless log.dig("topics", 0).to_s.downcase == TRANSFER_TOPIC
      next unless log.fetch("topics", []).size == 4

      {
        contract: normalize_address(log["address"]),
        from: topic_address(log.dig("topics", 1)),
        to: topic_address(log.dig("topics", 2)),
        token_id: log.dig("topics", 3).to_s.delete_prefix("0x").to_i(16).to_s
      }
    end
  end

  def classify(nft_transfers)
    return "unknown" if nft_transfers.empty?

    moved_back_to_gauge = nft_transfers.group_by { |transfer| transfer[:token_id] }.any? do |_token_id, transfers|
      transfers.any? { |transfer| gauge_like?(transfer[:from]) && intermediate_like?(transfer[:to]) } &&
        transfers.any? { |transfer| intermediate_like?(transfer[:from]) && gauge_like?(transfer[:to]) }
    end
    return "autopilot_shared_strategy" if moved_back_to_gauge

    "direct_lp_nft"
  end

  def detected_depositor_wallet(transfers)
    known_deposits = transfers.select { |transfer| %w[WETH USDC AERO].include?(transfer[:symbol]) }
    outgoing = known_deposits.group_by { |transfer| transfer[:from] }
    outgoing.max_by { |_address, grouped| grouped.sum { |transfer| BigDecimal(transfer[:amount]) } }&.first
  end

  def detected_contracts(erc20_transfers, nft_transfers, user_wallet = detected_depositor_wallet(erc20_transfers))
    addresses = erc20_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] } + nft_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] }
    addresses.compact.uniq.reject { |address| same_address?(address, user_wallet) || intermediate_like?(address) || same_address?(address, ZERO_ADDRESS) }
  end

  def intermediate_contracts(nft_transfers)
    nft_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] }.uniq.select { |address| intermediate_like?(address) }
  end

  def pool_contracts(transfers, user_wallet)
    transfers
      .select { |transfer| %w[WETH USDC].include?(transfer[:symbol]) }
      .map { |transfer| transfer[:to] }
      .reject { |address| same_address?(address, user_wallet) }
      .tally
      .sort_by { |_address, count| -count }
      .map(&:first)
  end

  def user_deposit_amounts(transfers, user_wallet)
    return {} unless user_wallet

    transfers.select { |transfer| same_address?(transfer[:from], user_wallet) && %w[WETH USDC AERO].include?(transfer[:symbol]) }.each_with_object({}) do |transfer, amounts|
      amounts[transfer[:symbol]] ||= BigDecimal("0")
      amounts[transfer[:symbol]] += BigDecimal(transfer[:amount])
    end.transform_values { |amount| amount.to_s("F") }
  end

  def candidate_share_tokens(transfers, user_wallet)
    return [] unless user_wallet

    transfers.select do |transfer|
      !transfer[:known_token] &&
        (same_address?(transfer[:to], user_wallet) || same_address?(transfer[:from], ZERO_ADDRESS))
    end.map do |transfer|
      token_address = transfer[:token_address]
      user_balance = read_balance_of(token_address, user_wallet, transfer[:decimals])
      total_supply = read_total_supply(token_address, transfer[:decimals])
      {
        token_address: token_address,
        symbol: read_symbol(token_address) || transfer[:symbol],
        name: read_name(token_address),
        decimals: transfer[:decimals],
        transfer_amount: transfer[:amount],
        transfer_from: transfer[:from],
        transfer_to: transfer[:to],
        user_balance: user_balance&.to_s("F"),
        total_supply: total_supply&.to_s("F"),
        looks_like_share_token: user_balance.present? && total_supply.present?
      }
    end
  end

  def strategy_contract_reads(addresses)
    addresses.uniq.map do |address|
      total_supply = read_total_supply(address, 18)
      {
        address: address,
        total_supply: total_supply&.to_s("F"),
        token0: read_address_method(address, :token0),
        token1: read_address_method(address, :token1),
        vault: read_address_method(address, :vault),
        strategy: read_address_method(address, :strategy),
        pool: read_address_method(address, :pool),
        get_total_amounts: read_two_uints(address, :get_total_amounts),
        total_assets: read_uint(address, :total_assets)&.to_s
      }
    end
  end

  def pro_rata_exposure(share_tokens, strategy_reads)
    share = share_tokens.find { |token| token[:user_balance].present? && token[:total_supply].present? }
    amounts_source = strategy_reads.find { |read| read[:get_total_amounts].present? }
    return { user_weth_exposure: nil, user_usdc_exposure: nil, confidence: "unavailable" } unless share && amounts_source

    user_shares = BigDecimal(share[:user_balance])
    total_shares = BigDecimal(share[:total_supply])
    amounts = amounts_source[:get_total_amounts]
    weth_amount = BigDecimal(amounts.fetch(:amount0)) / BigDecimal(10**18)
    usdc_amount = BigDecimal(amounts.fetch(:amount1)) / BigDecimal(10**6)
    {
      user_weth_exposure: (weth_amount * user_shares / total_shares).to_s("F"),
      user_usdc_exposure: (usdc_amount * user_shares / total_shares).to_s("F"),
      confidence: "high",
      share_token: share[:token_address],
      strategy_contract: amounts_source[:address]
    }
  rescue
    { user_weth_exposure: nil, user_usdc_exposure: nil, confidence: "low" }
  end

  def warnings(classification)
    return [ "Deposit amounts are transaction inputs, not current hedge exposure." ] unless classification == "autopilot_shared_strategy"

    [
      "Deposit amounts are transaction inputs, not current hedge exposure.",
      "Shared strategy NFT exposure requires user shares, total shares, and current strategy WETH before hedging."
    ]
  end

  def logs(receipt)
    receipt.fetch("logs", [])
  end

  def token_symbol(address)
    return "WETH" if same_address?(address, WETH_ADDRESS)
    return "USDC" if same_address?(address, USDC_ADDRESS)

    "AERO" if same_address?(address, AERO_ADDRESS)
  end

  def token_decimals(symbol)
    symbol == "USDC" ? 6 : 18
  end

  def read_balance_of(address, user_wallet, decimals)
    raw = read_uint_call(address, SELECTORS.fetch(:balance_of) + address_word(user_wallet))
    raw && BigDecimal(raw) / BigDecimal(10**decimals)
  end

  def read_total_supply(address, decimals)
    raw = read_uint(address, :total_supply)
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

  def read_two_uints(address, selector_key)
    result = eth_call(address, SELECTORS.fetch(selector_key))
    return nil unless result&.match?(/\A0x[0-9a-fA-F]{128}\z/)

    body = result.delete_prefix("0x")
    { amount0: body[0, 64].to_i(16).to_s, amount1: body[64, 64].to_i(16).to_s }
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

  def read_symbol(address)
    read_string_method(address, :symbol)
  end

  def read_name(address)
    read_string_method(address, :name)
  end

  def read_string_method(address, selector_key)
    decode_string(eth_call(address, SELECTORS.fetch(selector_key)))
  rescue
    nil
  end

  def eth_call(address, data)
    key = [ normalize_address(address), data.downcase ]
    return @eth_call_results[key] if @eth_call_results.key?(key)
    return nil if @receipt

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

  def address_word(address)
    normalize_address(address).delete_prefix("0x").rjust(64, "0")
  end

  def decode_string(result)
    return nil unless result&.start_with?("0x")

    body = result.delete_prefix("0x")
    if body.length == 64
      return [ body ].pack("H*").delete("\u0000")
    end
    offset = body[0, 64].to_i(16) * 2
    length = body[offset, 64].to_i(16) * 2
    [ body[offset + 64, length] ].pack("H*")
  end

  def topic_address(topic)
    "0x#{topic.to_s.delete_prefix('0x')[-40, 40]}".downcase
  end

  def normalize_address(address)
    address.to_s.downcase
  end

  def same_address?(a, b)
    normalize_address(a) == normalize_address(b)
  end

  def intermediate_like?(address)
    normalize_address(address).start_with?(ZEROISH_INTERMEDIATE_PREFIX)
  end

  def gauge_like?(address)
    !intermediate_like?(address)
  end
end
