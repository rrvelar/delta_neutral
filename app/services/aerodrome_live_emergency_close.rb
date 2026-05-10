class AerodromeLiveEmergencyClose
  BANNER = "AERODROME LIVE EMERGENCY CLOSE"
  CONFIRMATION = "I_UNDERSTAND_THIS_CLOSES_LIVE_ETH_SHORT"
  DEFAULT_ATTEMPTS = 5
  DEFAULT_SLEEP_SECONDS = 10

  def initialize(asset: "ETH", hyperliquid_service: nil, sleeper: ->(seconds) { sleep(seconds) })
    @asset = asset
    @hyperliquid_service = hyperliquid_service
    @sleeper = sleeper
    @attempts = []
    @errors = []
  end

  def report
    gate_errors = gate_errors_for_requested_asset
    return blocked(gate_errors) if gate_errors.any?

    before = eth_position
    before_size = short_size(before)
    return blocked([ "current ETH short exceeds AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" ], before_position: before) if before_size > max_close_eth
    return base_report(status: "noop", before_position: serialize_position(before), after_position: serialize_position(before)) if before_size.zero?

    after = attempt_close(before_size)
    status = short_size(after).zero? ? "success" : "failed"
    base_report(status: status, before_position: serialize_position(before), after_position: serialize_position(after))
  end

  private

  def gate_errors_for_requested_asset
    errors = []
    errors << "asset must be ETH" unless @asset.to_s.upcase == "ETH"
    errors << "HYPERLIQUID_TESTNET must be false" unless hyperliquid_mainnet?
    errors << "AERODROME_LIVE_APPROVED must be true" unless live_approved?
    errors << "AERODROME_HEDGE_PAUSED must be true" unless hedge_paused?
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED must be true" unless emergency_close_enabled?
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM must equal #{CONFIRMATION}" unless confirmation_valid?
    errors << "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH must be configured and positive" unless max_close_eth&.positive?
    errors << "No Aerodrome hedge/position found" unless aerodrome_hedge
    errors
  end

  def attempt_close(initial_size)
    unset = Object.new
    after = unset
    attempts_count.times do |index|
      attempt_number = index + 1
      begin
        result = hyperliquid.close_short(asset: "ETH", size: initial_size)
        if result.nil?
          @attempts << { attempt: attempt_number, status: "error", error: "close_short returned nil", size: initial_size.to_s("F") }
          @errors << "close_short returned nil"
        else
          @attempts << { attempt: attempt_number, status: "submitted", size: initial_size.to_s("F") }
        end
      rescue => e
        @errors << "#{e.class}: #{e.message}"
        @attempts << { attempt: attempt_number, status: "error", error: e.message, size: initial_size.to_s("F") }
      end

      @sleeper.call(sleep_seconds)
      after = eth_position
      break if short_size(after).zero?
    rescue => e
      @errors << "#{e.class}: #{e.message}"
      @attempts << { attempt: attempt_number, status: "readback_error", error: e.message, size: initial_size.to_s("F") }
    end
    after.equal?(unset) ? eth_position : after
  rescue => e
    @errors << "#{e.class}: #{e.message}"
    nil
  end

  def blocked(errors, before_position: nil)
    @errors.concat(errors)
    base_report(status: "blocked", before_position: serialize_position(before_position), after_position: serialize_position(before_position))
  end

  def base_report(status:, before_position:, after_position:)
    {
      safety_banner: BANNER,
      status: status,
      live_order_capable: true,
      gates: gates,
      before_position: before_position,
      after_position: after_position,
      attempts: @attempts,
      errors: @errors,
      database_write: false,
      touched_asset: "ETH"
    }
  end

  def gates
    {
      hyperliquid_testnet: ENV["HYPERLIQUID_TESTNET"],
      live_approved: live_approved?,
      hedge_paused: hedge_paused?,
      emergency_close_enabled: emergency_close_enabled?,
      confirmation_present: ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].present?,
      confirmation_valid: confirmation_valid?,
      max_close_eth: max_close_eth&.to_s("F")
    }
  end

  def eth_position
    hyperliquid.get_position("ETH")
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new
  end

  def aerodrome_hedge
    @aerodrome_hedge ||= Hedge.joins(position: :dex).where(positions: { dexes: { name: "aerodrome_slipstream" } }).first
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def serialize_position(position)
    return nil unless position

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end

  def max_close_eth
    raw = ENV["AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"].presence
    return nil unless raw

    BigDecimal(raw)
  rescue ArgumentError
    nil
  end

  def attempts_count
    integer_env("AERODROME_LIVE_CLOSE_RETRY_ATTEMPTS", DEFAULT_ATTEMPTS)
  end

  def sleep_seconds
    integer_env("AERODROME_LIVE_CLOSE_RETRY_SLEEP_SECONDS", DEFAULT_SLEEP_SECONDS)
  end

  def integer_env(key, default)
    Integer(ENV.fetch(key, default.to_s))
  rescue ArgumentError
    default
  end

  def hyperliquid_mainnet?
    ActiveModel::Type::Boolean.new.cast(ENV["HYPERLIQUID_TESTNET"]) == false
  end

  def live_approved?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_LIVE_APPROVED", "false"))
  end

  def hedge_paused?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_HEDGE_PAUSED", "true"))
  end

  def emergency_close_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED", "false"))
  end

  def confirmation_valid?
    ENV["AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM"].to_s == CONFIRMATION
  end
end
