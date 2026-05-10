class AerodromeApprovedOpenPosition
  BANNER = "AERODROME APPROVED OPEN POSITION — READ ONLY"
  DEFAULT_TOLERANCE_ETH = BigDecimal("0.002")

  def initialize(
    current_position: nil,
    log_dir: Rails.root.join("storage", "aerodrome_production_live"),
    position: nil
  )
    @current_position = current_position
    @log_dir = Pathname(log_dir)
    @position = position
    @blockers = []
    @warnings = []
  end

  def report
    final = final_event
    start = start_event
    approved = approved_final?(final)
    approval_status = approval_status_for(approved, final, start)

    {
      safety_banner: BANNER,
      status: status_for(approval_status),
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      approved: approved,
      approval_status: approval_status,
      log_path: log_path&.to_s,
      approved_log_path: log_path&.to_s,
      approved_final_position: normalize_position(final&.fetch("final_position", nil)),
      current_mainnet_position: normalize_position(@current_position),
      max_short_eth: max_short_eth(start)&.to_s("F"),
      max_short_notional_usd: max_short_notional_usd(start)&.to_s("F"),
      size_tolerance_eth: size_tolerance_eth.to_s("F"),
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps(approval_status)
    }
  end

  private

  def approval_status_for(approved, final, start)
    unless approved
      return "not_approved" if final.nil?

      @blockers << "Latest production live log is not approved open state"
      return "not_approved"
    end

    current_size = short_size(@current_position)
    if current_size.zero?
      @warnings << "Approved open hedge is no longer open"
      return "current_nil"
    end

    if current_size > max_short_eth(start)
      @blockers << "Current ETH short exceeds approved max ETH"
      return "out_of_bounds"
    end

    if current_notional > max_short_notional_usd(start)
      @blockers << "Current ETH notional exceeds approved max notional"
      return "out_of_bounds"
    end

    if (current_size - short_size(final.fetch("final_position"))).abs > size_tolerance_eth
      @blockers << "Current ETH short differs from approved final size beyond tolerance"
      return "mismatch"
    end

    "approved"
  end

  def approved_final?(final)
    return false unless final
    return false unless final["status"] == "success"
    return false unless final["stop_reason"] == "duration complete"
    return false unless final["position_left_open"] == true
    return false unless final["final_position"].present?
    return false unless final["final_position_confirmed"] == true
    return false unless final["manual_action_required"] == false
    return false if Array(final["errors"]).any?
    return false unless final.dig("final_position", "asset").to_s.upcase == "ETH"

    true
  end

  def status_for(approval_status)
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any? || approval_status == "current_nil"

    "PASS"
  end

  def latest_events
    @latest_events ||= begin
      return [] unless log_path

      log_path.readlines(chomp: true).reject(&:blank?).map { |line| JSON.parse(line) }
    rescue JSON::ParserError => e
      @blockers << "Production live log JSON parse failed: #{e.message}"
      []
    end
  end

  def log_path
    @log_path ||= begin
      return nil unless @log_dir.exist?

      @log_dir.children.select { |path| path.extname == ".jsonl" }.max_by { |path| [ path.mtime, path.to_s ] }
    end
  end

  def final_event
    latest_events.reverse.find { |event| %w[finish final].include?(event["type"]) }
  end

  def start_event
    latest_events.find { |event| event["type"] == "start" }
  end

  def max_short_eth(start)
    decimal_from(start&.dig("gates", "max_short_eth")) || decimal_from(ENV["AERODROME_MAX_SHORT_ETH"]) || BigDecimal("0")
  end

  def max_short_notional_usd(start)
    decimal_from(start&.dig("gates", "max_short_notional_usd")) || decimal_from(ENV["AERODROME_MAX_SHORT_NOTIONAL_USD"]) || BigDecimal("0")
  end

  def size_tolerance_eth
    decimal_from(ENV["AERODROME_APPROVED_OPEN_POSITION_SIZE_TOLERANCE_ETH"]) || DEFAULT_TOLERANCE_ETH
  end

  def current_notional
    short_size(@current_position) * eth_price
  end

  def eth_price
    position = @position || active_aerodrome_position
    return BigDecimal("0") unless position

    if %w[ETH WETH].include?(position.asset0.to_s.upcase)
      position.asset0_price_usd || BigDecimal("0")
    elsif %w[ETH WETH].include?(position.asset1.to_s.upcase)
      position.asset1_price_usd || BigDecimal("0")
    else
      BigDecimal("0")
    end
  end

  def active_aerodrome_position
    dex = Dex.find_by(name: "aerodrome_slipstream")
    return nil unless dex

    Position.where(dex: dex, active: true).order(:id).first
  end

  def short_size(position)
    normalized = normalize_position(position)
    return BigDecimal("0") unless normalized

    size = BigDecimal(normalized.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def normalize_position(position)
    return nil unless position

    hash = position.respond_to?(:deep_symbolize_keys) ? position.deep_symbolize_keys : position
    hash.merge(size: BigDecimal(hash.fetch(:size).to_s).to_s("F"))
  rescue KeyError, ArgumentError
    nil
  end

  def decimal_from(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def next_steps(approval_status)
    case approval_status
    when "approved"
      [ "Approved open ETH hedge is within caps. Continue monitoring; this is not approval for a new live run." ]
    when "current_nil"
      [ "Approved open hedge is no longer open. Inspect whether it was manually closed and consider future archive/acknowledgment workflow." ]
    else
      [ "Treat current ETH as unexpected unless a valid approved-open production live log exists. Use manually gated emergency close if needed." ]
    end
  end
end
