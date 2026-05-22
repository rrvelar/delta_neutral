require "net/http"
require "uri"

class AerodromeAutopilotTransactionProbe
  TRANSFER_TOPIC = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"
  SLIPSTREAM_POSITION_MANAGER = "0x827922686190790b37229fd06084350e74485b72"
  WETH_ADDRESS = "0x4200000000000000000000000000000000000006"
  USDC_ADDRESS = "0x833589fcd6edb6e08f4c7c32d4f71b54bdA02913"
  AERO_ADDRESS = "0x940181a94A35A4569E4529A3CDfB74e38FD98631"
  ZEROISH_INTERMEDIATE_PREFIX = "0x0000000c"

  def initialize(tx_hash:, network: "base", rpc_url: nil, receipt: nil)
    @tx_hash = tx_hash.to_s.strip
    @network = network.to_s.presence || "base"
    @rpc_url = rpc_url
    @receipt = receipt
  end

  def report
    return blank_report(blockers: [ "transaction hash is required" ]) if @tx_hash.blank?

    receipt = @receipt || fetch_receipt
    erc20_transfers = parse_erc20_transfers(receipt)
    nft_transfers = parse_slipstream_transfers(receipt)
    classification = classify(nft_transfers)
    blockers = []
    if classification == "autopilot_shared_strategy"
      blockers << "Cannot hedge: transaction appears to use a shared Autopilot strategy NFT; user pro-rata WETH exposure is unknown."
    elsif erc20_transfers.none? { |transfer| transfer[:symbol] == "WETH" }
      blockers << "Cannot hedge: user WETH deposit amount unavailable."
    end

    {
      database_write: false,
      external_api: @receipt.nil?,
      network: @network,
      tx_hash: @tx_hash,
      classification: classification,
      hedgeable: blockers.empty? && classification == "direct_lp_nft",
      user_wallet: detected_user_wallet(erc20_transfers),
      router_or_manager_contracts: detected_contracts(erc20_transfers, nft_transfers),
      intermediate_contracts: intermediate_contracts(nft_transfers),
      pool_address: detected_pool_address(erc20_transfers),
      strategy_token_ids: nft_transfers.map { |transfer| transfer[:token_id] }.uniq,
      user_deposit_amounts: user_deposit_amounts(erc20_transfers),
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
      user_wallet: nil,
      router_or_manager_contracts: [],
      intermediate_contracts: [],
      pool_address: nil,
      strategy_token_ids: [],
      user_deposit_amounts: {},
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

      symbol = token_symbol(log["address"])
      next unless symbol

      amount = BigDecimal(log["data"].to_s.delete_prefix("0x").to_i(16)) / BigDecimal(10**token_decimals(symbol))
      {
        symbol: symbol,
        token_address: normalize_address(log["address"]),
        from: topic_address(log.dig("topics", 1)),
        to: topic_address(log.dig("topics", 2)),
        amount: amount.to_s("F")
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

  def detected_user_wallet(transfers)
    outgoing = transfers.group_by { |transfer| transfer[:from] }
    outgoing.max_by { |_address, grouped| grouped.sum { |transfer| BigDecimal(transfer[:amount]) } }&.first
  end

  def detected_contracts(erc20_transfers, nft_transfers)
    addresses = erc20_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] } + nft_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] }
    addresses.compact.uniq.reject { |address| same_address?(address, detected_user_wallet(erc20_transfers)) || intermediate_like?(address) }
  end

  def intermediate_contracts(nft_transfers)
    nft_transfers.flat_map { |transfer| [ transfer[:from], transfer[:to] ] }.uniq.select { |address| intermediate_like?(address) }
  end

  def detected_pool_address(transfers)
    transfers.map { |transfer| transfer[:to] }.tally.max_by { |_address, count| count }&.first
  end

  def user_deposit_amounts(transfers)
    user = detected_user_wallet(transfers)
    return {} unless user

    transfers.select { |transfer| same_address?(transfer[:from], user) }.each_with_object({}) do |transfer, amounts|
      amounts[transfer[:symbol]] ||= BigDecimal("0")
      amounts[transfer[:symbol]] += BigDecimal(transfer[:amount])
    end.transform_values { |amount| amount.to_s("F") }
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
