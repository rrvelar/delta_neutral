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
    total_amounts: "0x0c6ffc29",
    total_assets: "0x01e1d114",
    underlying_tvl: "0x079c3b88",
    tvl: "0xe5328e06",
    get_tvl: "0xd075dd42",
    vault: "0xfbfa77cf",
    strategy: "0x4a1d70a1",
    pool: "0x16f0115b"
  }.freeze
  CURRENT_TOTAL_AMOUNT_METHODS = {
    get_total_amounts: "getTotalAmounts()",
    total_amounts: "totalAmounts()",
    underlying_tvl: "underlyingTvl()",
    tvl: "tvl()",
    get_tvl: "getTvl()"
  }.freeze

  def initialize(tx_hash:, network: "base", wallet_address: nil, rpc_url: nil, receipt: nil, eth_call_results: {}, slipstream_service: nil)
    @tx_hash = tx_hash.to_s.strip
    @network = network.to_s.presence || "base"
    @submitted_wallet = wallet_address.to_s.strip.presence
    @rpc_url = rpc_url
    @receipt = receipt
    @eth_call_results = eth_call_results
    @slipstream_service = slipstream_service
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
    routers = detected_contracts(erc20_transfers, nft_transfers, user_wallet)
    share_tokens = candidate_share_tokens(erc20_transfers, user_wallet, intermediate, routers)
    strategy_reads = strategy_contract_reads(intermediate + detected_contracts(erc20_transfers, nft_transfers, user_wallet))
    strategy_nft = strategy_nft_exposure(nft_transfers, classification)
    exposure = pro_rata_exposure(share_tokens, strategy_nft)
    deposits = user_deposit_amounts(erc20_transfers, user_wallet)
    blockers = []
    contract_held_share = share_tokens.any? { |token| token[:ownership_directly_attributable_to_user] == false && token[:contract_holders].present? }
    if classification == "autopilot_shared_strategy" && exposure[:user_weth_exposure].nil?
      blockers << if exposure[:current_share_token_total_amounts_unavailable]
        "current share-token total WETH/USDC unavailable"
      elsif strategy_nft[:strategy_total_weth].nil?
        "Cannot hedge: current shared strategy WETH exposure is unavailable."
      else
        "Cannot hedge: user pro-rata WETH exposure is unknown."
      end
    elsif erc20_transfers.none? { |transfer| transfer[:symbol] == "WETH" }
      blockers << "Cannot hedge: user WETH deposit amount unavailable."
    end
    if classification == "autopilot_shared_strategy" && contract_held_share
      blockers << "Shares appear held by contract #{share_tokens.flat_map { |token| token[:contract_holders] }.first}; user ownership mapping still unknown."
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
      router_or_manager_contracts: routers,
      intermediate_contracts: intermediate,
      pool_or_gauge_contracts: pools,
      pool_address: pools.first,
      strategy_token_ids: nft_transfers.map { |transfer| transfer[:token_id] }.uniq,
      user_deposit_amounts: deposits,
      candidate_share_tokens: share_tokens,
      strategy_contract_reads: strategy_reads,
      strategy_nft_exposure: strategy_nft,
      pro_rata_exposure: exposure,
      strategy_token_id: exposure[:strategy_token_id] || strategy_nft[:strategy_token_id],
      strategy_pool_address: exposure[:strategy_pool_address] || strategy_nft[:strategy_pool_address],
      strategy_total_weth: exposure[:strategy_total_weth] || strategy_nft[:strategy_total_weth],
      strategy_total_usdc: exposure[:strategy_total_usdc] || strategy_nft[:strategy_total_usdc],
      strategy_total_value_usd: exposure[:strategy_total_value_usd] || strategy_nft[:strategy_total_value_usd],
      user_share_balance: exposure[:user_share_balance],
      total_shares: exposure[:total_shares],
      user_share_percent: exposure[:user_share_percent],
      user_weth_exposure: exposure[:user_weth_exposure],
      user_usdc_exposure: exposure[:user_usdc_exposure],
      user_total_value_usd: exposure[:user_total_value_usd],
      exposure_confidence: exposure[:exposure_confidence] || exposure[:confidence],
      erc20_transfers: erc20_transfers,
      slipstream_nft_transfers: nft_transfers,
      blockers: blockers,
      warnings: warnings(classification, deposits, exposure)
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
      strategy_nft_exposure: blank_strategy_nft_exposure,
      pro_rata_exposure: blank_pro_rata_exposure,
      strategy_token_id: nil,
      strategy_pool_address: nil,
      strategy_total_weth: nil,
      strategy_total_usdc: nil,
      strategy_total_value_usd: nil,
      user_share_balance: nil,
      total_shares: nil,
      user_share_percent: nil,
      user_weth_exposure: nil,
      user_usdc_exposure: nil,
      user_total_value_usd: nil,
      exposure_confidence: "unavailable",
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

  def candidate_share_tokens(transfers, user_wallet, intermediate_contracts, router_contracts)
    candidate_addresses = transfers
      .reject { |transfer| transfer[:known_token] }
      .select { |transfer| candidate_share_transfer?(transfer, user_wallet, intermediate_contracts, router_contracts) }
      .map { |transfer| transfer[:token_address] }
      .uniq

    candidate_addresses.map do |token_address|
      token_transfers = transfers.select { |transfer| same_address?(transfer[:token_address], token_address) }
      sample = token_transfers.first
      total_supply = read_total_supply(token_address, sample[:decimals])
      holders = candidate_share_holders(token_address, sample[:decimals], total_supply, token_transfers, user_wallet, intermediate_contracts, router_contracts)
      submitted_holder = holders.find { |holder| same_address?(holder[:address], user_wallet) } if user_wallet
      contract_holders = holders
        .select { |holder| holder[:balance].present? && BigDecimal(holder[:balance]).positive? }
        .reject { |holder| user_wallet && same_address?(holder[:address], user_wallet) }
        .select { |holder| holder[:why_candidate].include?("intermediate_contract") || holder[:why_candidate].include?("router_contract") }
      {
        token_address: token_address,
        symbol: read_symbol(token_address) || sample[:symbol],
        name: read_name(token_address),
        decimals: sample[:decimals],
        transfer_amount: token_transfers.sum { |transfer| BigDecimal(transfer[:amount]) }.to_s("F"),
        transfer_from: token_transfers.first[:from],
        transfer_to: token_transfers.first[:to],
        transfers: candidate_share_token_transfers(token_transfers, user_wallet, intermediate_contracts, router_contracts),
        user_balance: submitted_holder&.dig(:balance),
        total_supply: total_supply&.to_s("F"),
        candidate_share_holders: holders,
        contract_holders: contract_holders.map { |holder| holder[:address] },
        ownership_directly_attributable_to_user: submitted_holder.present? && BigDecimal(submitted_holder[:balance].presence || "0").positive?,
        looks_like_share_token: holders.any? { |holder| holder[:balance].present? } && total_supply.present?
      }
    end
  end

  def candidate_share_transfer?(transfer, user_wallet, intermediate_contracts, router_contracts)
    return true if same_address?(transfer[:from], ZERO_ADDRESS)
    return true if user_wallet && (same_address?(transfer[:to], user_wallet) || same_address?(transfer[:from], user_wallet))

    related_addresses = intermediate_contracts + router_contracts
    related_addresses.any? { |address| same_address?(transfer[:to], address) || same_address?(transfer[:from], address) }
  end

  def candidate_share_token_transfers(transfers, user_wallet, intermediate_contracts, router_contracts)
    transfers.map do |transfer|
      {
        from: transfer[:from],
        to: transfer[:to],
        amount: transfer[:amount],
        mint: same_address?(transfer[:from], ZERO_ADDRESS),
        involves_submitted_wallet: user_wallet && (same_address?(transfer[:from], user_wallet) || same_address?(transfer[:to], user_wallet)),
        involves_router_or_manager: router_contracts.any? { |address| same_address?(transfer[:from], address) || same_address?(transfer[:to], address) },
        involves_intermediate: intermediate_contracts.any? { |address| same_address?(transfer[:from], address) || same_address?(transfer[:to], address) }
      }
    end
  end

  def candidate_share_holders(token_address, decimals, total_supply, transfers, user_wallet, intermediate_contracts, router_contracts)
    holder_reasons = {}
    add_holder_reason(holder_reasons, user_wallet, "submitted_wallet") if user_wallet
    transfers.each { |transfer| add_holder_reason(holder_reasons, transfer[:to], "transfer_recipient") }
    intermediate_contracts.each { |address| add_holder_reason(holder_reasons, address, "intermediate_contract") }
    router_contracts.each { |address| add_holder_reason(holder_reasons, address, "router_contract") }

    holder_reasons.filter_map do |address, reasons|
      next if same_address?(address, ZERO_ADDRESS)

      balance = read_balance_of(token_address, address, decimals)
      balance_string = balance&.to_s("F")
      {
        address: address,
        why_candidate: reasons.sort,
        balance: balance_string,
        share_percentage: share_percentage(balance, total_supply)
      }
    end
  end

  def add_holder_reason(holder_reasons, address, reason)
    return if address.blank?

    holder_reasons[normalize_address(address)] ||= []
    holder_reasons[normalize_address(address)] << reason
  end

  def share_percentage(balance, total_supply)
    return nil unless balance && total_supply&.positive?

    ((balance / total_supply) * 100).to_s("F")
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
        total_amounts: read_two_uints(address, :total_amounts),
        underlying_tvl: read_two_uints(address, :underlying_tvl),
        tvl: read_two_uints(address, :tvl),
        get_tvl: read_two_uints(address, :get_tvl),
        total_assets: read_uint(address, :total_assets)&.to_s
      }
    end
  end

  def strategy_nft_exposure(nft_transfers, classification)
    token_id = strategy_token_id(nft_transfers, classification)
    return blank_strategy_nft_exposure unless token_id
    return blank_strategy_nft_exposure.merge(strategy_token_id: token_id, error: "Slipstream strategy NFT read skipped for injected receipt") if @receipt && @slipstream_service.nil?

    position_data = slipstream_service.fetch_position(token_id)
    amounts = strategy_token_amounts(position_data)
    {
      strategy_token_id: token_id,
      strategy_pool_address: position_data.pool_address,
      strategy_total_weth: amounts[:weth]&.to_s("F"),
      strategy_total_usdc: amounts[:usdc]&.to_s("F"),
      strategy_total_value_usd: position_data.total_value_usd&.to_s("F"),
      token0_symbol: position_data.token0_symbol,
      token1_symbol: position_data.token1_symbol,
      token0_address: position_data.token0_address,
      token1_address: position_data.token1_address,
      source: "AerodromeSlipstreamService.fetch_position",
      confidence: amounts[:weth].present? ? "high" : "unavailable",
      error: nil
    }
  rescue => e
    blank_strategy_nft_exposure.merge(strategy_token_id: token_id, error: "#{e.class}: #{e.message}")
  end

  def strategy_token_id(nft_transfers, classification)
    return nil unless classification == "autopilot_shared_strategy"

    nft_transfers.group_by { |transfer| transfer[:token_id] }.find do |_token_id, transfers|
      transfers.any? { |transfer| gauge_like?(transfer[:from]) && intermediate_like?(transfer[:to]) } &&
        transfers.any? { |transfer| intermediate_like?(transfer[:from]) && gauge_like?(transfer[:to]) }
    end&.first
  end

  def strategy_token_amounts(position_data)
    amount0 = AerodromeSlipstreamMath.decimal_amount(position_data.amount0_raw, position_data.token0_decimals) if position_data.amount0_raw
    amount1 = AerodromeSlipstreamMath.decimal_amount(position_data.amount1_raw, position_data.token1_decimals) if position_data.amount1_raw
    {
      weth: weth_token?(position_data.token0_address, position_data.token0_symbol) ? amount0 : (weth_token?(position_data.token1_address, position_data.token1_symbol) ? amount1 : nil),
      usdc: usdc_token?(position_data.token0_address, position_data.token0_symbol) ? amount0 : (usdc_token?(position_data.token1_address, position_data.token1_symbol) ? amount1 : nil)
    }
  end

  def pro_rata_exposure(share_tokens, strategy_nft)
    share = share_tokens.find do |token|
      token[:ownership_directly_attributable_to_user] &&
        token[:user_balance].present? &&
        token[:total_supply].present?
    end
    return blank_pro_rata_exposure(strategy_nft) unless share

    user_shares = BigDecimal(share[:user_balance])
    total_shares = BigDecimal(share[:total_supply])
    return blank_pro_rata_exposure(strategy_nft) unless user_shares.positive? && total_shares.positive?

    share_fraction = user_shares / total_shares
    source = strategy_nft[:strategy_total_weth].present? ? strategy_nft : current_share_token_exposure(share, strategy_nft)
    unless source[:strategy_total_weth].present?
      return blank_pro_rata_exposure(strategy_nft).merge(
        share_token: share[:token_address],
        user_share_balance: user_shares.to_s("F"),
        total_shares: total_shares.to_s("F"),
        user_share_percent: (share_fraction * 100).to_s("F"),
        current_share_token_total_amounts_unavailable: true,
        current_share_token_total_amounts_attempts: source[:current_share_token_total_amounts_attempts] || [],
        confidence: "unavailable",
        exposure_confidence: "unavailable"
      )
    end

    strategy_weth = BigDecimal(source[:strategy_total_weth])
    strategy_usdc = BigDecimal(source[:strategy_total_usdc].presence || "0")
    strategy_value = BigDecimal(source[:strategy_total_value_usd].presence || "0")
    fallback_source = source[:exposure_source] == "current_share_token_fallback"
    {
      strategy_token_id: source[:strategy_token_id],
      stale_strategy_token_id: source[:stale_strategy_token_id],
      strategy_pool_address: source[:strategy_pool_address],
      strategy_token0: source[:token0_address],
      strategy_token1: source[:token1_address],
      strategy_total_weth: source[:strategy_total_weth],
      strategy_total_usdc: source[:strategy_total_usdc],
      strategy_total_value_usd: source[:strategy_total_value_usd],
      user_share_balance: user_shares.to_s("F"),
      total_shares: total_shares.to_s("F"),
      share_fraction: share_fraction.to_s("F"),
      user_share_percent: (share_fraction * 100).to_s("F"),
      user_weth_exposure: (strategy_weth * share_fraction).to_s("F"),
      user_usdc_exposure: (strategy_usdc * share_fraction).to_s("F"),
      user_total_value_usd: strategy_value.positive? ? (strategy_value * share_fraction).to_s("F") : nil,
      confidence: source[:confidence],
      share_token: share[:token_address],
      exposure_confidence: source[:confidence],
      source: fallback_source ? source[:source] : "shared strategy Slipstream NFT",
      exposure_source: source[:exposure_source] || "shared_strategy_nft",
      current_share_token_total_amounts_attempts: source[:current_share_token_total_amounts_attempts] || []
    }
  rescue
    blank_pro_rata_exposure(strategy_nft).merge(confidence: "low", exposure_confidence: "low")
  end

  def current_share_token_exposure(share, strategy_nft)
    token_address = share[:token_address]
    strategy_address = read_address_method(token_address, :strategy)
    vault_address = read_address_method(token_address, :vault)
    token0 = read_address_method(token_address, :token0) || strategy_nft[:token0_address]
    token1 = read_address_method(token_address, :token1) || strategy_nft[:token1_address]
    pool = read_address_method(token_address, :pool) || strategy_nft[:strategy_pool_address]
    attempts = []

    [ token_address, strategy_address, vault_address ].compact.uniq.each do |read_address|
      CURRENT_TOTAL_AMOUNT_METHODS.each_key do |method|
        raw_amounts = read_two_uints_with_attempt(read_address, method, attempts)
        next unless raw_amounts

        amounts = token_amounts_from_raw(raw_amounts, token0, token1)
        next unless amounts[:weth].present?

        return {
          strategy_token_id: strategy_nft[:strategy_token_id],
          stale_strategy_token_id: strategy_nft[:strategy_token_id],
          strategy_pool_address: pool,
          strategy_total_weth: amounts[:weth].to_s("F"),
          strategy_total_usdc: amounts[:usdc]&.to_s("F"),
          strategy_total_value_usd: nil,
          token0_address: token0,
          token1_address: token1,
          source: "current share-token total amounts",
          exposure_source: "current_share_token_fallback",
          confidence: "share_token_current_fallback",
          current_share_token_total_amounts_attempts: attempts
        }
      end
    end

    { current_share_token_total_amounts_attempts: attempts }
  end

  def read_two_uints_with_attempt(address, selector_key, attempts)
    result = eth_call(address, SELECTORS.fetch(selector_key))
    attempts << {
      address: normalize_address(address),
      method: CURRENT_TOTAL_AMOUNT_METHODS.fetch(selector_key),
      selector: SELECTORS.fetch(selector_key),
      status: result&.match?(/\A0x[0-9a-fA-F]{128}\z/) ? "ok" : "unavailable"
    }
    return nil unless result&.match?(/\A0x[0-9a-fA-F]{128}\z/)

    body = result.delete_prefix("0x")
    { amount0: body[0, 64].to_i(16).to_s, amount1: body[64, 64].to_i(16).to_s }
  rescue => e
    attempts << {
      address: normalize_address(address),
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
      weth: weth_token?(token0, nil) ? amount0 : (weth_token?(token1, nil) ? amount1 : nil),
      usdc: usdc_token?(token0, nil) ? amount0 : (usdc_token?(token1, nil) ? amount1 : nil)
    }
  end

  def decimal_token_amount(raw_amount, address)
    decimals = usdc_token?(address, nil) ? 6 : 18
    BigDecimal(raw_amount) / BigDecimal(10**decimals)
  end

  def blank_strategy_nft_exposure
    {
      strategy_token_id: nil,
      strategy_pool_address: nil,
      strategy_total_weth: nil,
      strategy_total_usdc: nil,
      strategy_total_value_usd: nil,
      token0_symbol: nil,
      token1_symbol: nil,
      token0_address: nil,
      token1_address: nil,
      source: nil,
      confidence: "unavailable",
      error: nil
    }
  end

  def blank_pro_rata_exposure(strategy_nft = nil)
    strategy_nft ||= blank_strategy_nft_exposure
    {
      strategy_token_id: strategy_nft[:strategy_token_id],
      strategy_pool_address: strategy_nft[:strategy_pool_address],
      strategy_total_weth: strategy_nft[:strategy_total_weth],
      strategy_total_usdc: strategy_nft[:strategy_total_usdc],
      strategy_total_value_usd: strategy_nft[:strategy_total_value_usd],
      user_share_balance: nil,
      total_shares: nil,
      user_share_percent: nil,
      user_weth_exposure: nil,
      user_usdc_exposure: nil,
      user_total_value_usd: nil,
      confidence: "unavailable",
      exposure_confidence: "unavailable",
      exposure_source: nil,
      stale_strategy_token_id: nil,
      share_fraction: nil,
      current_share_token_total_amounts_unavailable: false,
      current_share_token_total_amounts_attempts: []
    }
  end

  def warnings(classification, deposits, exposure)
    base = [
      deposit_weth_warning(deposits, exposure)
    ].compact
    return [ "Deposit amounts are transaction inputs, not current hedge exposure.", *base ] unless classification == "autopilot_shared_strategy"

    [
      "Deposit amounts are transaction inputs, not current hedge exposure.",
      "Shared strategy NFT exposure requires user shares, total shares, and current strategy WETH before hedging.",
      *base
    ]
  end

  def deposit_weth_warning(deposits, exposure)
    return nil unless deposits["WETH"].present? && exposure[:user_weth_exposure].present?

    deposit_weth = BigDecimal(deposits.fetch("WETH"))
    user_weth = BigDecimal(exposure.fetch(:user_weth_exposure))
    return nil unless deposit_weth.positive?

    relative_difference = (deposit_weth - user_weth).abs / deposit_weth
    return nil unless relative_difference > BigDecimal("0.05")

    "User pro-rata WETH exposure differs materially from transaction WETH input; deposit WETH is historical input, not current exposure."
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

  def weth_token?(address, symbol)
    same_address?(address, WETH_ADDRESS) || symbol.to_s.casecmp?("WETH")
  end

  def usdc_token?(address, symbol)
    same_address?(address, USDC_ADDRESS) || symbol.to_s.casecmp?("USDC")
  end

  def slipstream_service
    @slipstream_service ||= AerodromeSlipstreamService.new
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
