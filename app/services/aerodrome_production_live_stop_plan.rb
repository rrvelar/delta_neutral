class AerodromeProductionLiveStopPlan
  BANNER = "AERODROME PRODUCTION LIVE STOP PLAN — READ ONLY"

  def initialize(hyperliquid_service: nil)
    @hyperliquid_service = hyperliquid_service
    @errors = []
  end

  def report
    current_position = current_eth_position
    {
      safety_banner: BANNER,
      status: status,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      current_mainnet_eth_position: current_position,
      emergency_close_persistently_armed: emergency_close_persistently_armed?,
      warnings: warnings,
      stop_steps: stop_steps,
      errors: @errors
    }
  end

  private

  def status
    @errors.any? ? "WARN" : "PASS"
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

  def emergency_close_persistently_armed?
    ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED"]) == true &&
      ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == AerodromeLiveEmergencyClose::CONFIRMATION &&
      ENV["AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"].present?
  end

  def warnings
    [
      "This task is read-only and does not stop or close anything.",
      "Emergency close requires one-off live emergency env gates.",
      ("Persistent emergency close gates appear armed; verify this is intentional." if emergency_close_persistently_armed?)
    ].compact
  end

  def stop_steps
    [
      "Stop the supervised production live process with SIGINT/SIGTERM.",
      "Run FORMAT=json bin/rails aerodrome:production_live_status and verify current mainnet ETH position.",
      "If ETH remains open and should be closed, run the separately gated aerodrome:live_emergency_close with one-off env gates.",
      "Verify mainnet ETH position after close.",
      "Restore persistent safe env defaults."
    ]
  end
end
