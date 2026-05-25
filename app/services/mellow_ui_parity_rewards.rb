require "eth"
require "net/http"

class MellowUiParityRewards
  class Error < StandardError; end
  class ConfigError < Error; end
  class RpcError < Error; end
  class DecodeError < Error; end

  CONTRACT_ADDRESS = "0xcd975e6a5f55137755487f0918b8ca74acce7925"
  CONTRACT_ROLE = "LpWrapper minimal proxy / Mellow share token"
  SELECTOR = "0x79ee54f7"
  SELECTOR_NAME = "getRewards(address recipient)"
  DECIMALS = 18

  Result = Data.define(
    :status,
    :source,
    :confidence,
    :contract_address,
    :contract_role,
    :selector,
    :selector_name,
    :verified_selector,
    :wallet_address,
    :call_from,
    :call_to,
    :wallet_arg,
    :raw_result,
    :raw_amount,
    :decimals,
    :amount,
    :expected_aero,
    :expected_delta,
    :expected_delta_percent,
    :warnings,
    :stop_reason
  )

  def initialize(position:, rpc_url: ENV["BASE_RPC_URL"].presence, contract_address: nil, expected_aero: ENV["EXPECTED_AERO"].presence)
    @position = position
    @rpc_url = rpc_url
    @warnings = []
    @contract_address = normalize_address(contract_address.presence || metadata_contract_address || CONTRACT_ADDRESS)
    @expected_aero = parse_decimal(expected_aero)
  end

  def read
    return unavailable("BASE_RPC_URL is not configured") if @rpc_url.blank?

    wallet = submitted_wallet
    return unavailable("Mellow submitted wallet is unavailable for UI-parity reward read") if wallet.blank?

    normalized_wallet = normalize_address(wallet)
    raw_result = eth_call(from: normalized_wallet, to: @contract_address, data: call_data(normalized_wallet))
    raw_amount = uint_from_result(raw_result)
    amount = decimal_amount(raw_amount, DECIMALS)
    status, confidence, stop_reason = classify(amount)

    Result.new(
      status: status,
      source: "mellow_ui_parity_eth_call",
      confidence: confidence,
      contract_address: @contract_address,
      contract_role: contract_role,
      selector: SELECTOR,
      selector_name: SELECTOR_NAME,
      verified_selector: verified_selector?,
      wallet_address: normalized_wallet,
      call_from: normalized_wallet,
      call_to: @contract_address,
      wallet_arg: normalized_wallet,
      raw_result: raw_result,
      raw_amount: raw_amount,
      decimals: DECIMALS,
      amount: amount,
      expected_aero: @expected_aero,
      expected_delta: expected_delta(amount),
      expected_delta_percent: expected_delta_percent(amount),
      warnings: @warnings,
      stop_reason: stop_reason
    )
  rescue Error => e
    unavailable(e.message)
  end

  def call_data(wallet)
    SELECTOR + address_word(wallet)
  end

  private

  def metadata_contract_address
    @position.mellow_metadata_hash["share_token"].presence
  end

  def contract_role
    if same_address?(@contract_address, @position.mellow_metadata_hash["share_token"])
      "Mellow share token / LpWrapper minimal proxy"
    else
      CONTRACT_ROLE
    end
  end

  def submitted_wallet
    @position.mellow_metadata_hash["submitted_wallet"].presence || @position.wallet.address
  end

  def classify(amount)
    return [ "unavailable", "low", "Mellow UI-parity reward read returned no amount." ] unless amount

    if expected_delta_percent(amount)&.abs&.> BigDecimal("5")
      return [ "unverified_mismatch", "low", "Unverified — does not match Mellow UI reference." ]
    end

    return [ "verified_zero", "high", nil ] if amount.zero?
    return [ "estimated", "high", nil ] if verified_selector?
    return [ "unverified_match", "medium", "Unverified UI-parity match; selector is not verified." ] if @expected_aero

    [ "unverified_mismatch", "low", "Mellow UI-parity selector is not verified." ]
  end

  def expected_delta(amount)
    return nil unless @expected_aero && amount

    amount - @expected_aero
  end

  def expected_delta_percent(amount)
    return nil unless @expected_aero&.positive?
    delta = expected_delta(amount)
    return nil unless delta

    (delta / @expected_aero) * 100
  end

  def verified_selector?
    true
  end

  def eth_call(from:, to:, data:)
    response = Net::HTTP.post(
      URI(@rpc_url),
      {
        jsonrpc: "2.0",
        method: "eth_call",
        params: [ { from: normalize_address(from), to: normalize_address(to), data: data }, "latest" ],
        id: 1
      }.to_json,
      "Content-Type" => "application/json"
    )
    raise RpcError, "Mellow UI-parity RPC request failed: HTTP #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

    parsed = JSON.parse(response.body)
    raise RpcError, "Mellow UI-parity RPC error: #{parsed.dig('error', 'message')}" if parsed["error"]

    result = parsed["result"]
    raise DecodeError, "Mellow UI-parity RPC response missing result" unless result.is_a?(String)
    raise DecodeError, "Mellow UI-parity RPC response result is not hex" unless result.match?(/\A0x[0-9a-fA-F]*\z/)

    result
  rescue JSON::ParserError => e
    raise DecodeError, "Mellow UI-parity RPC response is not valid JSON: #{e.message}"
  end

  def unavailable(reason)
    Result.new(
      status: "unavailable",
      source: "mellow_ui_parity_eth_call",
      confidence: "low",
      contract_address: @contract_address,
      contract_role: contract_role,
      selector: SELECTOR,
      selector_name: SELECTOR_NAME,
      verified_selector: verified_selector?,
      wallet_address: submitted_wallet,
      call_from: submitted_wallet,
      call_to: @contract_address,
      wallet_arg: submitted_wallet,
      raw_result: nil,
      raw_amount: nil,
      decimals: DECIMALS,
      amount: nil,
      expected_aero: @expected_aero,
      expected_delta: nil,
      expected_delta_percent: nil,
      warnings: @warnings,
      stop_reason: reason
    )
  end

  def uint_from_result(result)
    body = result.delete_prefix("0x")
    raise DecodeError, "Mellow UI-parity RPC response expected 1 ABI word, got #{body.length / 64}" unless body.length == 64

    body.to_i(16)
  end

  def decimal_amount(raw, decimals)
    BigDecimal(raw.to_s) / (BigDecimal("10")**Integer(decimals))
  end

  def address_word(address)
    normalize_address(address).delete_prefix("0x").rjust(64, "0")
  end

  def normalize_address(address)
    value = address.to_s.downcase
    raise DecodeError, "Invalid EVM address: #{address.inspect}" unless value.match?(/\A0x[0-9a-f]{40}\z/)

    value
  end

  def same_address?(left, right)
    left.present? && right.present? && left.to_s.downcase == right.to_s.downcase
  end

  def parse_decimal(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    @warnings << "EXPECTED_AERO is not parseable and was ignored."
    nil
  end
end
