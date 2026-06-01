class MigrationTargetFirstFinalVerifier
  VENUES = %w[extended ethereal nado].freeze
  DEFAULT_ATTEMPTS = 4
  DEFAULT_INTERVAL_SECONDS = 0.25
  FLAT_TOLERANCE_ETH = BigDecimal("0.001")

  def self.evaluate(from:, to:, target_short:, tolerance_eth:, shorts:, open_order_counts: {}, attempt: 1, readback_source: "unknown")
    source_short = decimal(shorts[from])
    target_venue_short = decimal(shorts[to])
    other_venue_shorts = (VENUES - [ from, to ]).index_with { |venue| decimal(shorts[venue]) }
    combined = shorts.values.sum { |value| decimal(value) }
    target = decimal_or_nil(target_short)
    tolerance = [ decimal_or_nil(tolerance_eth) || BigDecimal("0"), FLAT_TOLERANCE_ETH ].max
    source_flat = source_short <= FLAT_TOLERANCE_ETH
    target_confirmed = target && (target_venue_short - target).abs <= tolerance
    third_venue_flat = other_venue_shorts.values.all? { |value| value <= FLAT_TOLERANCE_ETH }
    combined_inside_tolerance = target && (combined - target).abs <= tolerance
    known_open_order_counts = open_order_counts.values.compact
    open_orders_clear = known_open_order_counts.all? { |value| value.to_i.zero? }
    blockers = []
    blockers << "#{HedgeVenues.label(from)} source short is not flat" unless source_flat
    blockers << "#{HedgeVenues.label(to)} target short does not match expected hedge" unless target_confirmed
    blockers << "unexpected third-venue short is present" unless third_venue_flat
    blockers << "combined short is outside hedge tolerance" unless combined_inside_tolerance
    blockers << "open orders must be zero after migration" unless open_orders_clear

    {
      attempt: attempt,
      status: blockers.empty? ? "confirmed" : "recheck",
      readback_source: readback_source,
      source_venue: from,
      target_venue: to,
      source_short_eth: decimal_string(source_short),
      target_venue_short_eth: decimal_string(target_venue_short),
      third_venue_shorts: other_venue_shorts.transform_values { |value| decimal_string(value) },
      combined_short_eth: decimal_string(combined),
      expected_target_short_eth: decimal_string(target),
      tolerance_eth: decimal_string(tolerance),
      source_flat: source_flat,
      target_confirmed: target_confirmed == true,
      third_venue_flat: third_venue_flat,
      combined_inside_tolerance: combined_inside_tolerance == true,
      open_order_counts: open_order_counts,
      open_orders_count: known_open_order_counts.sum(&:to_i),
      open_orders_clear: open_orders_clear,
      blockers: blockers
    }
  end

  def initialize(position:, from:, to:, expected_target_short:, tolerance_eth:, env: ENV, venues: nil,
                 attempts: DEFAULT_ATTEMPTS, interval_seconds: DEFAULT_INTERVAL_SECONDS,
                 sleeper: ->(seconds) { sleep(seconds) }, now: -> { Time.current })
    @position = position
    @from = HedgeVenues.normalize(from)
    @to = HedgeVenues.normalize(to)
    @expected_target_short = expected_target_short
    @tolerance_eth = tolerance_eth
    @env = env
    @venues = venues
    @attempts = [ attempts.to_i, 1 ].max
    @interval_seconds = BigDecimal(interval_seconds.to_s)
    @sleeper = sleeper
    @now = now
  end

  def verify
    attempts_log = []
    attempts.times do |index|
      attempt = build_attempt(index + 1)
      attempts_log << attempt
      break if attempt[:status] == "confirmed"

      sleeper.call(interval_seconds.to_f) if index < attempts - 1 && interval_seconds.positive?
    end
    latest = attempts_log.last
    {
      status: latest[:status] == "confirmed" ? "confirmed" : "recheck_required",
      confirmed: latest[:status] == "confirmed",
      attempts_configured: attempts,
      interval_seconds: interval_seconds.to_s("F"),
      attempts: attempts_log,
      latest_attempt: latest,
      source_flat: latest[:source_flat],
      target_confirmed: latest[:target_confirmed],
      third_venue_flat: latest[:third_venue_flat],
      combined_inside_tolerance: latest[:combined_inside_tolerance],
      open_orders_clear: latest[:open_orders_clear],
      blockers: latest[:blockers],
      warnings: []
    }
  end

  private

  attr_reader :position, :from, :to, :expected_target_short, :tolerance_eth, :env, :attempts, :interval_seconds, :sleeper, :now

  def build_attempt(attempt_number)
    positions = VENUES.index_with { |venue| venue_for(venue).read_position(symbol: "ETH") }
    shorts = positions.transform_values { |payload| short_size(payload) }
    open_counts = VENUES.index_with { |venue| open_orders_count(venue_for(venue)) }
    self.class.evaluate(
      from: from,
      to: to,
      target_short: expected_target_short,
      tolerance_eth: tolerance_eth,
      shorts: shorts,
      open_order_counts: open_counts,
      attempt: attempt_number,
      readback_source: "venue_readback"
    ).merge(timestamp: now.call.utc.iso8601)
  rescue => e
    {
      attempt: attempt_number,
      status: "recheck",
      readback_source: "venue_readback_error",
      blockers: [ "final readback unavailable: #{e.class}: #{e.message}" ],
      source_flat: false,
      target_confirmed: false,
      third_venue_flat: false,
      combined_inside_tolerance: false,
      open_orders_clear: false,
      open_orders_count: nil,
      timestamp: now.call.utc.iso8601
    }
  end

  def venue_for(venue)
    venue_map.fetch(venue)
  end

  def venue_map
    @venue_map ||= begin
      return @venues.transform_keys { |venue| HedgeVenues.normalize(venue) } if @venues

      VENUES.index_with { |venue| HedgeVenues.build(venue, env: env) }
    end
  end

  def open_orders_count(venue)
    state = venue.account_state
    state[:open_orders_count] || state["open_orders_count"]
  rescue
    nil
  end

  def short_size(position_payload)
    self.class.send(:decimal, position_payload&.fetch(:short_size, 0))
  rescue KeyError
    BigDecimal("0")
  end

  def self.decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end
  private_class_method :decimal

  def self.decimal_or_nil(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :decimal_or_nil

  def self.decimal_string(value)
    return nil if value.nil?

    BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError, TypeError
    nil
  end
  private_class_method :decimal_string
end
