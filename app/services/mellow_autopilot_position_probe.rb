require "net/http"
require "uri"

class MellowAutopilotPositionProbe
  API_BASE_URL = "https://points.mellow.finance/v1"
  WETH_SYMBOLS = %w[WETH ETH].freeze
  USDC_SYMBOLS = %w[USDC].freeze

  def initialize(wallet_address:, vault_address: nil, network: "base", http_client: nil, api_base_url: API_BASE_URL)
    @wallet_address = wallet_address.to_s.strip
    @vault_address = vault_address.to_s.strip.presence
    @network = network.to_s.presence || "base"
    @http_client = http_client
    @api_base_url = api_base_url
    @warnings = []
  end

  def report
    return blank_report(blockers: [ "wallet address is required" ]) if @wallet_address.blank?

    user_positions = fetch_json("/users/#{encoded_wallet}")
    defi_positions = fetch_json("/defi/users/#{encoded_wallet}")
    positions = normalize_positions(user_positions, defi_positions)
    positions = positions.select { |position| same_address?(position[:vault_address], @vault_address) } if @vault_address
    blockers = []
    blockers << "No Mellow/Autopilot positions detected for wallet." if positions.empty?
    blockers << "Cannot hedge: underlying WETH exposure unavailable." if positions.none? { |position| position[:weth_amount].present? }

    {
      database_write: false,
      external_api: true,
      source: "Mellow official points API",
      network: @network,
      wallet_address: @wallet_address,
      vault_address: @vault_address,
      positions: positions,
      total_positions: positions.size,
      hedge_target_computable: blockers.none? && positions.any? { |position| position[:weth_amount].present? },
      blockers: blockers,
      warnings: @warnings,
      raw: {
        users: user_positions,
        defi_users: defi_positions
      }
    }
  rescue => e
    blank_report(blockers: [ "Mellow Autopilot probe failed: #{e.class}: #{e.message}" ])
  end

  private

  def blank_report(blockers:)
    {
      database_write: false,
      external_api: true,
      source: "Mellow official points API",
      network: @network,
      wallet_address: @wallet_address,
      vault_address: @vault_address,
      positions: [],
      total_positions: 0,
      hedge_target_computable: false,
      blockers: blockers,
      warnings: @warnings,
      raw: {}
    }
  end

  def normalize_positions(user_payload, defi_payload)
    entries = candidate_entries(user_payload) + candidate_entries(defi_payload)
    entries.map { |entry| normalize_position(entry) }.uniq { |position| [ position[:vault_address], position[:vault_identifier], position[:receipt_share_amount] ] }
  end

  def candidate_entries(payload)
    case payload
    when Array
      payload.flat_map { |entry| candidate_entries(entry) }
    when Hash
      nested = %w[positions vaults vault_positions user_vaults autopilot_positions data items result].flat_map do |key|
        value = payload[key]
        value.is_a?(Array) ? value : []
      end
      nested.presence || [ payload ]
    else
      []
    end
  end

  def normalize_position(entry)
    tokens = token_entries(entry)
    weth = amount_for(tokens, WETH_SYMBOLS) || decimal_field(entry, "weth_amount", "wethAmount", "eth_amount", "ethAmount")
    usdc = amount_for(tokens, USDC_SYMBOLS) || decimal_field(entry, "usdc_amount", "usdcAmount")
    @warnings << "Only vault/share balance is available; underlying token exposure is missing." if weth.nil? && share_amount(entry).present?

    {
      vault_identifier: string_field(entry, "vault_id", "vaultId", "id", "identifier"),
      vault_address: address_field(entry, "vault_address", "vaultAddress", "address", "vault"),
      vault_name: string_field(entry, "vault_name", "vaultName", "name", "title"),
      receipt_share_amount: share_amount(entry),
      total_value_usd: decimal_field(entry, "total_value_usd", "totalValueUsd", "value_usd", "valueUsd", "usd_value", "usdValue", "balance_usd", "balanceUsd")&.to_s("F"),
      weth_amount: weth&.to_s("F"),
      usdc_amount: usdc&.to_s("F"),
      underlying_tokens: tokens
    }
  end

  def token_entries(entry)
    arrays = %w[underlying_tokens underlyingTokens underlying tokens assets holdings balances].filter_map do |key|
      value = entry[key]
      value if value.is_a?(Array)
    end
    arrays.flatten.filter_map do |token|
      next unless token.is_a?(Hash)

      symbol = string_field(token, "symbol", "token_symbol", "tokenSymbol", "asset", "coin")
      amount = decimal_field(token, "amount", "balance", "quantity", "underlying_amount", "underlyingAmount")
      value_usd = decimal_field(token, "value_usd", "valueUsd", "usd_value", "usdValue")
      { symbol: symbol, amount: amount&.to_s("F"), value_usd: value_usd&.to_s("F") }
    end
  end

  def amount_for(tokens, symbols)
    token = tokens.find { |entry| symbols.include?(entry[:symbol].to_s.upcase) && entry[:amount].present? }
    token ? BigDecimal(token[:amount]) : nil
  end

  def share_amount(entry)
    decimal_field(entry, "shares", "share_amount", "shareAmount", "receipt_share_amount", "receiptShareAmount", "balance", "amount")&.to_s("F")
  end

  def fetch_json(path)
    uri = URI("#{@api_base_url}#{path}")
    response = @http_client ? @http_client.get(uri) : Net::HTTP.get_response(uri)
    code = response.respond_to?(:code) ? response.code.to_i : 200
    body = response.respond_to?(:body) ? response.body : response.to_s
    raise "HTTP #{code} #{body}" unless code.between?(200, 299)

    JSON.parse(body)
  end

  def encoded_wallet
    URI.encode_www_form_component(@wallet_address)
  end

  def same_address?(a, b)
    a.to_s.downcase == b.to_s.downcase
  end

  def address_field(hash, *keys)
    string_field(hash, *keys)
  end

  def string_field(hash, *keys)
    keys.lazy.map { |key| hash[key] || hash[key.to_sym] }.find(&:present?)&.to_s
  end

  def decimal_field(hash, *keys)
    raw = keys.lazy.map { |key| hash[key] || hash[key.to_sym] }.find(&:present?)
    return nil unless raw

    BigDecimal(raw.to_s)
  rescue ArgumentError
    nil
  end
end
