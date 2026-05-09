class AerodromeTestnetEmergencyClose
  BANNER = "TESTNET EMERGENCY CLOSE"
  DEFAULT_ATTEMPTS = 5
  DEFAULT_SLEEP_SECONDS = 10

  def initialize(hyperliquid_service: nil, sleeper: ->(seconds) { sleep(seconds) })
    @hyperliquid_service = hyperliquid_service
    @sleeper = sleeper
    @attempts = []
    @errors = []
  end

  def report
    return refused("HYPERLIQUID_TESTNET must be true") unless hyperliquid_testnet?
    return refused("AERODROME_LIVE_APPROVED must be false") if aerodrome_live_approved?
    return refused("No Aerodrome hedge/position found") unless aerodrome_hedge

    before = eth_position
    before_size = short_size(before)
    return base_report(status: "noop", before_position: serialize_position(before), after_position: serialize_position(before)) if before_size.zero?

    after = attempt_close(before_size)
    status = short_size(after).zero? ? "success" : "failed"
    base_report(status: status, before_position: serialize_position(before), after_position: serialize_position(after))
  end

  private

  def attempt_close(initial_size)
    unset = Object.new
    after = unset
    attempts_count.times do |index|
      attempt_number = index + 1
      begin
        hyperliquid.close_short(asset: "ETH", size: initial_size)
        @attempts << { attempt: attempt_number, status: "submitted", size: initial_size.to_s("F") }
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

  def base_report(status:, before_position:, after_position:)
    {
      safety_banner: BANNER,
      status: status,
      hyperliquid_testnet: hyperliquid_testnet?,
      live_approved: aerodrome_live_approved?,
      attempts: @attempts,
      before_position: before_position,
      after_position: after_position,
      errors: @errors,
      database_write: false,
      touched_asset: "ETH"
    }
  end

  def refused(reason)
    @errors << reason
    base_report(status: "failed", before_position: nil, after_position: nil)
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

    BigDecimal(position.fetch(:size).to_s).abs
  end

  def serialize_position(position)
    return nil unless position

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end

  def attempts_count
    integer_env("AERODROME_CLOSE_RETRY_ATTEMPTS", DEFAULT_ATTEMPTS)
  end

  def sleep_seconds
    integer_env("AERODROME_CLOSE_RETRY_SLEEP_SECONDS", DEFAULT_SLEEP_SECONDS)
  end

  def integer_env(key, default)
    Integer(ENV.fetch(key, default.to_s))
  rescue ArgumentError
    default
  end

  def hyperliquid_testnet?
    ActiveModel::Type::Boolean.new.cast(ENV["HYPERLIQUID_TESTNET"]) == true
  end

  def aerodrome_live_approved?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch("AERODROME_LIVE_APPROVED", "false"))
  end
end
