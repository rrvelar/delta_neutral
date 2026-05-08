require "net/http"

# Read-only operational report for manually checking Aerodrome Slipstream NFTs.
#
# This command object does not write to the database, does not run jobs, does
# not require private keys, and does not call Hyperliquid.
class AerodromeSlipstreamDryRun
  SAFETY_BANNER = "READ-ONLY DRY RUN — no DB writes, no trades, no hedges."
  BASE_CHAIN_ID_HEX = "0x2105"
  EVM_ADDRESS_PATTERN = /\A0x[0-9a-fA-F]{40}\z/

  def self.normalize_token_ids(raw_token_ids)
    token_ids = Array(raw_token_ids).flat_map { |value| value.to_s.split(",") }.map(&:strip).compact_blank
    unique_token_ids = token_ids.uniq
    duplicate_token_ids = token_ids.tally.select { |_token_id, count| count > 1 }.keys

    {
      token_ids: unique_token_ids,
      notes: duplicate_token_ids.map { |token_id| "Duplicate token id #{token_id} ignored" }
    }
  end

  def initialize(
    token_ids:,
    rpc_url: nil,
    position_manager_address: nil,
    factory_address: nil,
    slipstream_service: nil,
    slipstream_service_class: AerodromeSlipstreamService
  )
    normalized = self.class.normalize_token_ids(token_ids)
    @token_ids = normalized.fetch(:token_ids)
    @notes = normalized.fetch(:notes)
    @rpc_url = rpc_url
    @position_manager_address = position_manager_address
    @factory_address = factory_address
    @slipstream_service = slipstream_service
    @slipstream_service_class = slipstream_service_class
  end

  def report
    results = @token_ids.map { |token_id| report_token(token_id) }

    {
      safety_banner: SAFETY_BANNER,
      database_write: false,
      hedge_enabled: false,
      amount_math_deferred: results.any? { |result| result[:amount0_raw].nil? || result[:amount1_raw].nil? },
      token_count: @token_ids.size,
      notes: @notes,
      results: results
    }
  end

  class ConfigVerification
    def initialize(
      rpc_url: ENV["BASE_RPC_URL"],
      position_manager_address: ENV["AERODROME_SLIPSTREAM_POSITION_MANAGER"],
      factory_address: ENV["AERODROME_SLIPSTREAM_FACTORY"],
      check_rpc: false
    )
      @rpc_url = rpc_url
      @position_manager_address = position_manager_address
      @factory_address = factory_address
      @check_rpc = check_rpc
    end

    def report
      errors = static_errors
      rpc_checks = []
      rpc_checks = run_rpc_checks(errors) if @check_rpc && errors.empty?

      {
        safety_banner: SAFETY_BANNER,
        status: errors.empty? ? "ok" : "error",
        database_write: false,
        hedge_enabled: false,
        check_rpc: @check_rpc,
        config: {
          base_rpc_url_present: @rpc_url.present?,
          position_manager_address: @position_manager_address,
          factory_address: @factory_address
        },
        rpc_checks: rpc_checks,
        errors: errors
      }
    end

    private

    def static_errors
      [].tap do |errors|
        errors << "Missing BASE_RPC_URL" if @rpc_url.blank?
        errors << "Missing AERODROME_SLIPSTREAM_POSITION_MANAGER" if @position_manager_address.blank?
        errors << "Missing AERODROME_SLIPSTREAM_FACTORY" if @factory_address.blank?
        if @position_manager_address.present? && !@position_manager_address.match?(EVM_ADDRESS_PATTERN)
          errors << "Invalid AERODROME_SLIPSTREAM_POSITION_MANAGER address"
        end
        if @factory_address.present? && !@factory_address.match?(EVM_ADDRESS_PATTERN)
          errors << "Invalid AERODROME_SLIPSTREAM_FACTORY address"
        end
      end
    end

    def run_rpc_checks(errors)
      [
        rpc_check("eth_chainId", nil, errors) do
          result = rpc_request("eth_chainId", [])
          errors << "BASE_RPC_URL returned chain id #{result}, expected #{BASE_CHAIN_ID_HEX}" unless result.to_s.downcase == BASE_CHAIN_ID_HEX
          result
        end,
        rpc_check("eth_getCode", @position_manager_address, errors) do
          result = rpc_request("eth_getCode", [ @position_manager_address, "latest" ])
          errors << "Position manager has no code on configured RPC" if blank_code?(result)
          summarize_code(result)
        end,
        rpc_check("eth_getCode", @factory_address, errors) do
          result = rpc_request("eth_getCode", [ @factory_address, "latest" ])
          errors << "Factory has no code on configured RPC" if blank_code?(result)
          summarize_code(result)
        end
      ]
    end

    def rpc_check(method, target, errors)
      { method: method, target: target, status: "ok", result: yield }
    rescue => e
      errors << "#{method} failed for #{target || 'BASE_RPC_URL'}: #{e.message}"
      { method: method, target: target, status: "error", error_class: e.class.name, error_message: e.message }.tap do
        # Keep the message non-secret: no request body or env values are included.
      end
    end

    def rpc_request(method, params)
      uri = URI(@rpc_url)
      response = Net::HTTP.post(
        uri,
        { jsonrpc: "2.0", method: method, params: params, id: 1 }.to_json,
        "Content-Type" => "application/json"
      )
      raise "Aerodrome config RPC request failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body)
      raise "Aerodrome config RPC error: #{parsed.dig("error", "message")}" if parsed["error"]
      raise "Aerodrome config RPC response missing result" unless parsed.key?("result")

      parsed.fetch("result")
    rescue JSON::ParserError => e
      raise "Aerodrome config RPC response is not valid JSON: #{e.message}"
    end

    def blank_code?(result)
      result.blank? || result == "0x"
    end

    def summarize_code(result)
      return result if blank_code?(result)

      "#{result.bytesize} bytes returned"
    end
  end

  private

  def report_token(token_id)
    data = service.fetch_position(token_id)
    {
      token_id: data.token_id,
      status: data.verification_status == "partial" ? "partial" : "ok",
      owner_address: data.owner_address,
      position_manager_address: data.position_manager_address,
      factory_address: data.factory_address,
      pool_address: data.pool_address,
      token0_address: data.token0_address,
      token1_address: data.token1_address,
      token0_symbol: data.token0_symbol,
      token1_symbol: data.token1_symbol,
      token0_decimals: data.token0_decimals,
      token1_decimals: data.token1_decimals,
      tick_spacing: data.tick_spacing,
      tick_lower: data.tick_lower,
      tick_upper: data.tick_upper,
      liquidity: data.liquidity,
      sqrt_price_x96: data.sqrt_price_x96,
      current_tick: data.current_tick,
      tokens_owed0_raw: data.tokens_owed0_raw,
      tokens_owed1_raw: data.tokens_owed1_raw,
      amount0_raw: data.amount0_raw,
      amount1_raw: data.amount1_raw,
      amount0_decimal: decimal_string(data.amount0_raw, data.token0_decimals),
      amount1_decimal: decimal_string(data.amount1_raw, data.token1_decimals),
      partial_data_reason: data.partial_data_reason,
      math_source: data.verification_status == "verified_math" ? AerodromeSlipstreamService::VERIFIED_AMOUNT_MATH_SOURCE : nil,
      verification_status: data.verification_status,
      hedge_enabled: false,
      database_write: false,
      error_class: nil,
      error_message: nil
    }
  rescue => e
    error_report(token_id, e)
  end

  def service
    @slipstream_service ||= @slipstream_service_class.new(
      rpc_url: @rpc_url,
      position_manager_address: @position_manager_address,
      factory_address: @factory_address
    )
  end

  def error_report(token_id, error)
    {
      token_id: token_id,
      status: "error",
      owner_address: nil,
      position_manager_address: @position_manager_address,
      factory_address: @factory_address,
      pool_address: nil,
      token0_address: nil,
      token1_address: nil,
      token0_symbol: nil,
      token1_symbol: nil,
      token0_decimals: nil,
      token1_decimals: nil,
      tick_spacing: nil,
      tick_lower: nil,
      tick_upper: nil,
      liquidity: nil,
      sqrt_price_x96: nil,
      current_tick: nil,
      tokens_owed0_raw: nil,
      tokens_owed1_raw: nil,
      amount0_raw: nil,
      amount1_raw: nil,
      amount0_decimal: nil,
      amount1_decimal: nil,
      partial_data_reason: nil,
      math_source: nil,
      verification_status: "error",
      hedge_enabled: false,
      database_write: false,
      error_class: error.class.name,
      error_message: error.message
    }
  end

  def decimal_string(raw_amount, decimals)
    return nil if raw_amount.nil? || decimals.nil?

    AerodromeSlipstreamMath.decimal_amount(raw_amount, decimals).to_s("F")
  end
end
