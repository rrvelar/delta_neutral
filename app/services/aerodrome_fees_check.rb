class AerodromeFeesCheck
  BANNER = "AERODROME FEES CHECK — READ ONLY"
  DEX_NAME = "aerodrome_slipstream"

  def initialize(fees_service: nil, rewards_service: nil)
    @fees_service = fees_service
    @rewards_service = rewards_service
    @warnings = []
    @blockers = []
  end

  def report
    position = active_aerodrome_position
    fee_data = position ? read_fees(position) : nil
    merge_fee_messages(fee_data)

    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      transactions_enabled: false,
      collect_enabled: false,
      pool_address: position&.pool_address,
      token_id: position&.external_id&.to_s,
      fee_source: fee_data&.fee_source || "unavailable",
      fee0_symbol: fee_data&.fee0_symbol,
      fee0_amount: decimal_string(fee_data&.fee0_amount),
      fee0_usd: decimal_string(fee_data&.fee0_usd),
      fee1_symbol: fee_data&.fee1_symbol,
      fee1_amount: decimal_string(fee_data&.fee1_amount),
      fee1_usd: decimal_string(fee_data&.fee1_usd),
      total_fees_usd: decimal_string(fee_data&.total_fees_usd),
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  private

  def active_aerodrome_position
    dex = Dex.find_by(name: DEX_NAME)
    unless dex
      @blockers << "Aerodrome Slipstream dex record is missing"
      return nil
    end

    position = Position.includes(:wallet).where(dex: dex, active: true).order(:id).first
    @blockers << "No active Aerodrome Slipstream position found" unless position
    position
  end

  def read_fees(position)
    return staked_fee_unavailable(position) if staked_position?(position)

    fees_service.fees_for_position(position)
  rescue AerodromeSlipstreamService::ConfigError, AerodromeSlipstreamService::DecodeError => e
    unavailable(position, "fee read unavailable: #{e.message}")
  rescue AerodromeSlipstreamService::Error => e
    unavailable(position, "fee read unavailable: #{e.message}")
  end

  def staked_position?(position)
    return false if ENV["AERODROME_VOTER_ADDRESS"].blank?

    depositor = ENV["AERODROME_REWARDS_DEPOSITOR_ADDRESS"].presence || position.wallet.address
    gauge = rewards_service.gauge_for_pool(position.pool_address)
    return false if gauge == AerodromeRewardsService::ZERO_ADDRESS

    rewards_service.staked_contains(gauge, depositor, position.external_id)
  rescue AerodromeRewardsService::Error => e
    @warnings << "staking status could not be verified for fee read: #{e.message}"
    false
  end

  def staked_fee_unavailable(position)
    unavailable(
      position,
      "fee read for staked Slipstream NFT is not verified; CL gauge staking receives emissions instead of LP fees"
    )
  end

  def unavailable(position, warning)
    AerodromeFeesService::FeeData.new(
      status: "unavailable",
      fee_source: "unavailable",
      token_id: position.external_id.to_s,
      pool_address: position.pool_address,
      fee0_symbol: nil,
      fee0_amount: nil,
      fee0_usd: nil,
      fee1_symbol: nil,
      fee1_amount: nil,
      fee1_usd: nil,
      total_fees_usd: nil,
      warnings: [ warning ],
      blockers: []
    )
  end

  def fees_service
    @fees_service ||= AerodromeFeesService.new
  end

  def rewards_service
    @rewards_service ||= AerodromeRewardsService.new(
      aero_token_address: ENV["AERODROME_AERO_TOKEN_ADDRESS"].presence
    )
  end

  def merge_fee_messages(fee_data)
    return unless fee_data

    @warnings.concat(fee_data.warnings)
    @blockers.concat(fee_data.blockers)
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def decimal_string(value)
    return nil if value.nil?

    BigDecimal(value.to_s).to_s("F")
  end

  def next_steps
    return [ "Resolve blockers before using LP fee discovery output." ] if @blockers.any?
    return [ "Review warnings. Fee values are not realized PnL and collecting is not implemented." ] if @warnings.any?

    [ "Fee values are read-only estimates until collected. Collecting fees is not implemented." ]
  end
end
