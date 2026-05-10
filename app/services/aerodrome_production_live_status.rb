class AerodromeProductionLiveStatus
  BANNER = "AERODROME PRODUCTION LIVE STATUS — READ ONLY"

  def initialize(
    hyperliquid_service: nil,
    log_dir: Rails.root.join("storage", "aerodrome_production_live"),
    lock_path: Rails.root.join("storage", "aerodrome_production_live", "run.lock")
  )
    @hyperliquid_service = hyperliquid_service
    @log_dir = Pathname(log_dir)
    @lock_path = Pathname(lock_path)
    @errors = []
  end

  def report
    current_position = current_eth_position
    approved = AerodromeApprovedOpenPosition.new(current_position: current_position, log_dir: @log_dir).report
    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      lock_exists: @lock_path.exist?,
      latest_log_path: latest_log_path&.to_s,
      latest_event: latest_event,
      latest_final_status: latest_final_event&.fetch("status", nil),
      current_mainnet_eth_position: current_position,
      approved_open_position: approved,
      safe_env: safe_env,
      manual_action_required: latest_final_event&.fetch("manual_action_required", nil),
      errors: @errors
    }
  end

  private

  def status
    return "WARN" if @errors.any? || latest_final_event&.fetch("manual_action_required", nil) == true

    "PASS"
  end

  def latest_event
    events.last
  end

  def latest_final_event
    @latest_final_event ||= events.reverse.find { |event| %w[finish final].include?(event["type"]) }
  end

  def events
    @events ||= begin
      return [] unless latest_log_path

      latest_log_path.readlines(chomp: true).reject(&:blank?).map { |line| JSON.parse(line) }
    rescue JSON::ParserError => e
      @errors << "production live log JSON parse failed: #{e.message}"
      []
    end
  end

  def latest_log_path
    @latest_log_path ||= begin
      return nil unless @log_dir.exist?

      @log_dir.children.select { |path| path.extname == ".jsonl" }.max_by { |path| [ path.mtime, path.to_s ] }
    end
  end

  def current_eth_position
    hyperliquid.get_position("ETH")
  rescue => e
    @errors << "mainnet ETH readback failed: #{e.class}: #{e.message}"
    nil
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def safe_env
    {
      hyperliquid_testnet: ENV["HYPERLIQUID_TESTNET"],
      hedge_enabled: ENV["AERODROME_HEDGE_ENABLED"],
      hedge_paused: ENV["AERODROME_HEDGE_PAUSED"],
      live_approved: ENV["AERODROME_LIVE_APPROVED"]
    }
  end
end
