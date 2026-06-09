class ActiveVenueOneShotRebalance
  VENUES = %w[extended ethereal nado].freeze
  SUCCESS_STATUSES = %w[success submitted_and_confirmed rebalance_confirmed_late no_op dry_run].freeze
  PENDING_RECHECK_STATUSES = %w[submitted_pending_readback submitted_but_readback_pending submitted_but_not_confirmed].freeze
  PENDING_RECHECK_FINAL_STATUSES = %w[REBALANCE_REQUIRES_RECHECK SUBMITTED_BUT_NOT_CONFIRMED].freeze
  REBALANCE_TRIGGER_BLOCKER_PATTERN = /outside tolerance|out_of_burn_in_tolerance|max allowed drift|drift_ratio/i

  def initialize(position:, live: false, env: ENV, preflight_factory: nil, rebalancer: nil, now: -> { Time.current },
                 max_attempts: 2, only_if_outside_tolerance: true, recheck_attempts: 4,
                 recheck_interval_seconds: 5, sleeper: ->(seconds) { sleep(seconds) })
    @position = position
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @env = env
    @preflight_factory = preflight_factory
    @rebalancer = rebalancer || HedgeVenueAutoRebalanceOnce.new(env: env)
    @now = now
    @max_attempts = max_attempts.to_i
    @only_if_outside_tolerance = ActiveModel::Type::Boolean.new.cast(only_if_outside_tolerance)
    @recheck_attempts = recheck_attempts.to_i
    @recheck_interval_seconds = recheck_interval_seconds.to_i
    @sleeper = sleeper
  end

  def run(reason:)
    position.reload
    preflight = direct_preflight("active_rebalance_#{reason}")
    venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    base = base_payload(reason: reason, venue: venue, preflight: preflight)
    blockers = active_venue_blockers(preflight: preflight, venue: venue)
    return blocked_payload(base, blockers: blockers, preflight: preflight) if blockers.any?
    return base.merge(needed: false, reason: "inside_tolerance", final_inside_tolerance: true) if inside_tolerance?(preflight) && only_if_outside_tolerance

    result = run_one_shot(venue)
    receipt = result.receipt || {}
    recheck = recheck_pending_readback(result: result, reason: reason, venue: venue)
    postflight = recheck[:postflight] || (live? ? direct_preflight("active_rebalance_#{reason}_after") : preflight)
    final_blockers = final_blockers(result: result, postflight: postflight, recheck: recheck)
    status_reason = final_blockers.any? ? "blocked" : execution_reason(result)
    base.merge(
      needed: true,
      reason: status_reason,
      rebalance_status: result.status,
      rebalance_final_status: receipt[:final_status],
      recheck_attempts: recheck[:attempts],
      recheck_final_inside_tolerance: recheck[:final_inside_tolerance],
      blockers: final_blockers,
      warnings: Array(result.warnings),
      orders_submitted: receipt.fetch(:orders_submitted, receipt.fetch(:orders_placed, 0)).to_i,
      orders_placed: receipt.fetch(:orders_placed, receipt.fetch(:orders_submitted, 0)).to_i,
      signatures_created: receipt.fetch(:signatures_created, 0).to_i,
      final_inside_tolerance: live? ? inside_tolerance?(postflight) : nil,
      rebalance_receipt: compact_receipt(receipt)
    )
  end

  private

  attr_reader :position, :env, :preflight_factory, :rebalancer, :now, :max_attempts, :only_if_outside_tolerance,
    :recheck_attempts, :recheck_interval_seconds, :sleeper

  def live?
    @live
  end

  def direct_preflight(stage)
    if preflight_factory
      return preflight_factory.call(position: position, stage: stage)
    end

    MigrationRandomExecutionPreflight.new(
      position: position,
      env: env,
      live: live?
    ).report
  end

  def base_payload(reason:, venue:, preflight:)
    {
      checked: true,
      checked_at: now.call.utc.iso8601,
      venue: venue,
      trigger: reason,
      needed: false,
      reason: "inside_tolerance",
      target_short_eth: decimal_string(preflight.dig(:target, :target_short_eth)),
      current_short_eth: decimal_string(preflight.dig(:venues, venue, :short_eth)),
      drift_eth: decimal_string(preflight[:drift_eth]),
      tolerance_eth: decimal_string(preflight[:tolerance_abs_eth]),
      inside_tolerance: inside_tolerance?(preflight),
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      final_inside_tolerance: inside_tolerance?(preflight),
      blockers: []
    }
  end

  def active_venue_blockers(preflight:, venue:)
    blockers = Array(preflight[:blockers]).reject { |blocker| blocker.to_s.match?(REBALANCE_TRIGGER_BLOCKER_PATTERN) }
    blockers << "active production venue is unavailable" unless VENUES.include?(venue)
    blockers << "active venue #{venue} readback unknown" if venue.present? && preflight.dig(:venues, venue, :short_eth).nil?
    blockers << "active venue open orders are not zero" unless open_orders_zero?(preflight)
    blockers << "active venue exposure is not isolated to #{venue}" unless isolated_active_exposure?(preflight, venue)
    blockers << "migration lock is already active for this position" if MigrationExecutionLock.locked?(position)
    blockers << "rebalance_max_attempts_per_cycle must be positive" unless max_attempts.positive?
    blockers.uniq
  end

  def blocked_payload(base, blockers:, preflight:)
    base.merge(
      needed: !inside_tolerance?(preflight),
      reason: "blocked",
      blockers: blockers,
      final_inside_tolerance: inside_tolerance?(preflight)
    )
  end

  def final_blockers(result:, postflight:, recheck:)
    blockers = Array(result.blockers)
    status_success = SUCCESS_STATUSES.include?(result.status.to_s) || recheck[:confirmed] == true
    blockers << "active venue one-shot rebalance status is #{result.status}" unless status_success
    manual_action = result.receipt&.fetch(:manual_action_required, false) == true
    blockers << "active venue one-shot rebalance requires manual action" if manual_action && recheck[:confirmed] != true
    if live?
      blockers << "active venue one-shot rebalance final readback is outside tolerance" unless inside_tolerance?(postflight)
      blockers << "active venue one-shot rebalance final open orders are not zero" unless open_orders_zero?(postflight)
    end
    blockers.uniq
  end

  def recheck_pending_readback(result:, reason:, venue:)
    return { attempts: [], confirmed: false, final_inside_tolerance: nil, postflight: nil } unless pending_recheck?(result)
    return { attempts: [], confirmed: false, final_inside_tolerance: nil, postflight: nil } unless live?

    attempts = []
    postflight = nil
    recheck_attempts.times do |index|
      sleeper.call(recheck_interval_seconds) if index.positive? && recheck_interval_seconds.positive?
      postflight = direct_preflight("active_rebalance_#{reason}_recheck_#{index + 1}")
      attempt = {
        attempt: index + 1,
        production_venue: postflight[:production_venue],
        inside_tolerance: inside_tolerance?(postflight),
        open_orders_zero: open_orders_zero?(postflight),
        active_venue_isolated: isolated_active_exposure?(postflight, venue),
        production_venue_finalized: HedgeVenues.normalize(postflight[:production_venue]) == venue,
        blockers: Array(postflight[:blockers])
      }
      attempts << attempt
      break if recheck_confirmed?(attempt)
    end

    confirmed = attempts.any? { |attempt| recheck_confirmed?(attempt) }
    { attempts: attempts, confirmed: confirmed, final_inside_tolerance: inside_tolerance?(postflight), postflight: postflight }
  end

  def pending_recheck?(result)
    PENDING_RECHECK_STATUSES.include?(result.status.to_s) ||
      PENDING_RECHECK_FINAL_STATUSES.include?(result.receipt&.fetch(:final_status, nil).to_s)
  end

  def recheck_confirmed?(attempt)
    attempt[:production_venue_finalized] &&
      attempt[:inside_tolerance] &&
      attempt[:open_orders_zero] &&
      attempt[:active_venue_isolated] &&
      attempt[:blockers].empty?
  end

  def run_one_shot(venue)
    enable_scoped_live_gates(venue) if live?
    rebalancer.run(
      position: position,
      dry_run: !live?,
      live: live?,
      confirmation: confirmation_for(venue),
      one_shot: true
    )
  end

  def enable_scoped_live_gates(venue)
    return unless venue == "nado"

    OperationalSettings.set!(key: "AERODROME_NADO_HEDGE_LIVE_ENABLED", enabled: true, reason: "active venue one-shot rebalance")
  end

  def confirmation_for(venue)
    case venue
    when "extended" then ExtendedAutoRebalanceOnce::CONFIRMATION
    when "ethereal" then HedgeVenueAutoRebalanceAdapters::Ethereal::CONFIRMATION
    when "nado" then env["AERODROME_NADO_HEDGE_CONFIRMATION"].to_s
    end
  end

  def execution_reason(result)
    return "success_after_recheck" if pending_recheck?(result)

    result.status.to_s == "no_op" ? "inside_tolerance" : "executed"
  end

  def isolated_active_exposure?(preflight, venue)
    active = active_short_venues(preflight)
    active.one? && active.first == venue
  end

  def active_short_venues(preflight)
    Array(preflight[:active_short_venues]).presence ||
      VENUES.select { |venue| decimal(preflight.dig(:venues, venue, :short_eth)).positive? }
  end

  def open_orders_zero?(preflight)
    VENUES.all? { |venue| preflight.dig(:venues, venue, :open_orders_status) == "zero" }
  end

  def inside_tolerance?(preflight)
    preflight[:inside_tolerance] == true || preflight[:burn_in_inside_tolerance] == true
  end

  def compact_receipt(receipt)
    receipt.slice(
      :venue,
      :action,
      :source,
      :planned_auto_action,
      :target_short_eth,
      :current_short_eth,
      :drift_eth,
      :tolerance_eth,
      :requested_size_eth,
      :final_status,
      :orders_submitted,
      :orders_placed,
      :signatures_created
    )
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def decimal_string(value)
    decimal(value).to_s("F")
  end
end
