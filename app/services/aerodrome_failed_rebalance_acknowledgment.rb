class AerodromeFailedRebalanceAcknowledgment
  BANNER = "AERODROME FAILED REBALANCE ACKNOWLEDGMENT"
  CONFIRMATION = "I_CONFIRM_MAINNET_ETH_POSITION_IS_NIL_AND_FAILURE_REVIEWED"
  MARKER = "[operator_acknowledged_no_open_position]"
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(hyperliquid_service: nil)
    @hyperliquid_service = hyperliquid_service
    @errors = []
  end

  def report
    rebalance = find_rebalance
    return blocked unless rebalance && eligible_rebalance?(rebalance) && eth_position_nil?

    acknowledge!(rebalance)
    base_report("success", rebalance)
  end

  private

  def find_rebalance
    unless ENV["AERODROME_ACK_FAILED_REBALANCE_ID"].present?
      @errors << "AERODROME_ACK_FAILED_REBALANCE_ID must be set"
      return nil
    end

    unless ENV["AERODROME_ACK_FAILED_REBALANCE_CONFIRM"].to_s == CONFIRMATION
      @errors << "AERODROME_ACK_FAILED_REBALANCE_CONFIRM must equal #{CONFIRMATION}"
      return nil
    end

    ShortRebalance.find_by(id: ENV["AERODROME_ACK_FAILED_REBALANCE_ID"]).tap do |rebalance|
      @errors << "ShortRebalance not found" unless rebalance
    end
  end

  def eligible_rebalance?(rebalance)
    add_error("asset must be WETH or ETH") unless HEDGEABLE_SYMBOLS.include?(rebalance.asset.to_s.upcase)
    add_error("status must be failed") unless rebalance.status == ShortRebalance::STATUS_FAILED
    add_error("old_short_size must be 0") unless decimal(rebalance.old_short_size).zero?
    add_error("new_short_size must be 0") unless decimal(rebalance.new_short_size).zero?
    add_error("message must be present") unless rebalance.message.present?
    @errors.empty?
  end

  def eth_position_nil?
    position = hyperliquid.get_position("ETH")
    current_short = position ? decimal(position.fetch(:size)).abs : BigDecimal("0")
    add_error("mainnet ETH position must be nil before acknowledgment") unless current_short.zero?
    current_short.zero?
  rescue => e
    add_error("mainnet ETH readback failed: #{e.class}: #{e.message}")
    false
  end

  def acknowledge!(rebalance)
    return if rebalance.message.include?(MARKER)

    rebalance.update!(message: "#{rebalance.message}\n#{MARKER}")
  end

  def blocked
    base_report("blocked", nil)
  end

  def base_report(status, rebalance)
    {
      safety_banner: BANNER,
      status: status,
      database_write: status == "success",
      orders_enabled: false,
      hyperliquid_execution: false,
      rebalance_id: rebalance&.id,
      asset: rebalance&.asset,
      old_short_size: rebalance&.old_short_size&.to_s("F"),
      new_short_size: rebalance&.new_short_size&.to_s("F"),
      acknowledgment_marker: MARKER,
      errors: @errors
    }
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def add_error(message)
    @errors << message
  end

  def decimal(value)
    BigDecimal((value || 0).to_s)
  end
end
