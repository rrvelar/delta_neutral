# Presentation layer for the /positions/:id "Production Control Center".
#
# These helpers turn the raw {MigrationRandomProductionDashboard} report hash
# (passed straight through from the controller) into a small, operator-friendly
# view model: one status banner, one recommended action, venue cards and a
# route/hold progress summary. They are pure (no DB / network) so they stay
# cheap to render and easy to unit test. Nothing here submits orders, signs,
# cancels, or mutates production state — it is display only.
module OperatorDashboardHelper
  # Tailwind classes for the four operator tones. Kept in one place so banners,
  # cards and pills stay visually consistent.
  OPERATOR_TONE_CLASSES = {
    green: "border-green-800 bg-green-950/40 text-green-100",
    amber: "border-yellow-800 bg-yellow-950/30 text-yellow-100",
    red: "border-red-800 bg-red-950/40 text-red-100",
    blue: "border-blue-800 bg-blue-950/40 text-blue-100",
    neutral: "border-gray-700 bg-gray-950 text-gray-300"
  }.freeze

  ACTIVE_SHORT_THRESHOLD_ETH = BigDecimal("0.001")

  def operator_tone_classes(tone)
    OPERATOR_TONE_CLASSES.fetch(tone.to_sym, OPERATOR_TONE_CLASSES[:neutral])
  end

  # The single source of truth for "what state are we in and what should the
  # operator do". Returns a hash the view renders directly. The keys mirror the
  # ten operator questions in the dashboard brief.
  def operator_state(random_production, position)
    random_production ||= {}
    status = operator_runner_status(random_production)
    inside_tolerance = random_production[:inside_tolerance]
    open_orders_zero = random_production[:open_orders_zero]
    market_safe = random_production[:current_direct_market_safe]
    blockers = operator_blockers(random_production)
    venue_name = HedgeVenues.label(HedgeVenues.normalize(random_production[:current_production_venue].presence || position&.hedge&.execution_venue))
    active_count = operator_active_venue_count(random_production)

    case status
    when "unsafe_multiple_exposure"
      operator_blocked(status, "Blocked — multiple exposure",
        "More than one venue is holding a hedge right now. The market is not delta-neutral.",
        "Do not start 24/7 production. Reduce to exactly one active hedge venue first, using supervised manual controls.")
    when "unsafe_unknown_exposure"
      operator_blocked(status, "Blocked — unknown venue readback",
        "A venue exposure could not be confirmed, so total hedge size is unknown.",
        "Do not start 24/7 production. Refresh read-only data and confirm every venue readback before starting.")
    when "active_venue_mismatch"
      operator_blocked(status, "Blocked — active venue mismatch",
        "The active hedge venue differs from the configured production venue.",
        "Use supervised adopt/sync to reconcile the active venue before starting 24/7 production.")
    when "orphan_process_running"
      operator_blocked(status, "Blocked — duplicate runner process",
        "A duplicate or orphaned runner process appears to be running.",
        "Do not start another runner. Investigate and stop the orphan process before starting 24/7 production.")
    when "unsafe_gates_left_enabled"
      operator_blocked(status, "Blocked — live gates enabled without runner",
        "Live migration gates are enabled but no runner holds the lock.",
        "Do not start 24/7 until gates and lock are reconciled. Review emergency/developer diagnostics.")
    when "stale lock", "stale_lock", "stale_heartbeat"
      {
        tone: :amber, key: status, allow_start: false,
        title: "Attention — stale runner lock",
        detail: "The runner lock or heartbeat is stale: the process may have exited without cleaning up.",
        action_title: "Confirm the runner is really stopped",
        action_body: "Clear the stale lock and confirm direct status is safe before starting 24/7 production again."
      }
    when "running"
      if inside_tolerance == true && open_orders_zero == true && blockers.blank?
        {
          tone: :green, key: status, allow_start: false,
          title: "Running normally — no action needed",
          detail: "24/7 random rotation is running. Hedge is on #{venue_name}, inside tolerance, with zero open orders.",
          action_title: "No action needed",
          action_body: "Bot is running and market is safe. Do not press Start again."
        }
      else
        reason = blockers.first.presence ||
          (open_orders_zero == false ? "Open orders are nonzero." : nil) ||
          (inside_tolerance == false ? "Hedge is outside tolerance." : "Live readback not fully confirmed yet.")
        {
          tone: :amber, key: status, allow_start: false,
          title: "Running — operator attention",
          detail: "24/7 random rotation is running on #{venue_name}, but something needs a look: #{reason}",
          action_title: "Review before intervening",
          action_body: "The runner is still active. Do not press Start. #{reason} Check the venue cards and diagnostics below."
        }
      end
    else
      operator_stopped_state(random_production, venue_name, blockers, inside_tolerance, active_count, market_safe)
    end
  end

  # Compact metric pills for the top of the control center — the answers to the
  # operator's "is it safe at a glance" questions.
  def operator_active_venue_count(random_production)
    shorts = (random_production || {})[:direct_venue_shorts] || {}
    HedgeVenues::SUPPORTED_KEYS.count do |venue|
      value = shorts[venue] || shorts[venue.to_sym]
      operator_decimal_known?(value) && operator_decimal(value) > ACTIVE_SHORT_THRESHOLD_ETH
    end
  end

  # One card per supported venue. Driven by the runner's direct readbacks
  # (authoritative truth) and enriched with snapshot readback freshness and the
  # carried-forward diagnostic. Never renders the literal "Unavailable".
  def operator_venue_cards(random_production, venue_states)
    random_production ||= {}
    venue_states ||= {}
    shorts = random_production[:direct_venue_shorts] || {}
    open_orders = random_production[:direct_open_orders] || {}
    production_venue = HedgeVenues.normalize(random_production[:current_production_venue].presence)

    HedgeVenues::SUPPORTED_KEYS.map do |venue|
      short = shorts[venue] || shorts[venue.to_sym]
      short_known = operator_decimal_known?(short)
      active = short_known && operator_decimal(short) > ACTIVE_SHORT_THRESHOLD_ETH
      state = venue_states[venue.to_sym] || venue_states[venue] || {}
      oo = open_orders.dig(venue, :status) || open_orders.dig(venue, "status") ||
        open_orders.dig(venue.to_sym, :status) || open_orders.dig(venue.to_sym, "status")
      carried = state[:carried_forward_exposure] == true

      {
        venue: venue,
        name: HedgeVenues.label(venue),
        production: venue == production_venue,
        status_label: active ? "Active hedge" : (short_known ? "Flat" : "Unknown"),
        tone: active ? :green : (short_known ? :neutral : :amber),
        short_text: short_known ? "#{format_venue_eth_amount(short)} ETH" : "Unknown — not read back yet",
        open_orders_text: operator_open_orders_text(oo),
        readback_text: operator_readback_text(state, carried),
        carried_forward: carried,
        carried_forward_text: carried && state[:carried_forward_short_eth_display].present? ?
          "#{state[:carried_forward_short_eth_display]} ETH" : nil
      }
    end
  end

  # Route + hold-check progress for the current cycle. Approximate by design:
  # the brief asks for a safe estimate when exact telemetry is missing.
  def operator_hold_progress(random_production)
    random_production ||= {}
    event = operator_current_event(random_production)
    current = [
      event["hold_rebalance_checks_count"],
      event["hold_rebalance_checks"]&.size,
      random_production[:hold_check_count]
    ].compact.first.to_i
    total = operator_hold_checks_per_cycle
    percent = total.positive? ? [ [ (current * 100.0 / total).round, 0 ].max, 100 ].min : 0
    { current: current, total: total, percent: percent, label: "#{current} / ~#{total} checks" }
  end

  def operator_route_progress(random_production)
    random_production ||= {}
    event = operator_current_event(random_production)
    route = operator_event_stale?(random_production) ? nil : (random_production[:last_route].presence || event["route"].presence)
    finalized = event["production_venue_finalized"] == true || event["status"].to_s == "success"
    from, to = route.to_s.split("->", 2)
    {
      route: route,
      from_name: from.present? ? HedgeVenues.label(from) : nil,
      to_name: to.present? ? HedgeVenues.label(to) : nil,
      source_closed: finalized,
      target_opened: finalized,
      production_venue_finalized: finalized
    }
  end

  def operator_next_migration_eta_text(random_production)
    at = operator_parse_time((random_production || {})[:next_rotation_at])
    return "ETA not available yet — waiting for runner start/cycle timing." unless at

    "in about #{distance_of_time_in_words(Time.current, at)} (#{l(at, format: :short)})"
  end

  # Freshness of the authoritative status payload. Drives the "last refreshed /
  # data source / age / health" line and the stale-data yellow warning.
  def operator_status_freshness(random_production)
    random_production ||= {}
    at = operator_parse_time(random_production[:status_updated_at])
    age = at ? (Time.current - at).to_i : nil
    stale = age.nil? || age > MigrationRandomProductionRunner::HEARTBEAT_STALE_AFTER_SECONDS
    {
      source: random_production[:status_source] || "runner status file (read-only)",
      updated_at: at,
      updated_at_text: at ? "#{l(at, format: :short)}" : "not written yet",
      age_seconds: age,
      age_text: age ? "#{operator_duration_words(age)} ago" : "unknown age",
      stale: stale,
      tone: stale ? :amber : :green
    }
  end

  # The historical (previous-cycle) blocker, shown only as a collapsed, clearly
  # stale diagnostic. Returns nil when there is nothing historical to show.
  def operator_historical_blocker(random_production)
    random_production ||= {}
    blocker = random_production[:historical_blocker].presence || random_production[:latest_blocker].presence
    return nil if blocker.blank?
    # Don't repeat a blocker that is also a current authoritative blocker.
    return nil if operator_blockers(random_production).include?(blocker.to_s)

    {
      text: blocker.to_s,
      stale: random_production[:latest_event_stale] != false,
      cycle: (random_production[:latest_event] || {})["cycle"],
      label: "Previous stopped run / last recorded event"
    }
  end

  # Authoritative current active short for the production venue (direct readback).
  # Never falls back to the stale heartbeat combined/target short.
  def operator_active_short_eth(random_production, venue = nil)
    random_production ||= {}
    venue ||= HedgeVenues.normalize(random_production[:current_production_venue].presence)
    shorts = random_production[:direct_venue_shorts] || {}
    value = shorts[venue] || shorts[venue.to_s] || shorts[venue.to_sym]
    operator_decimal_known?(value) ? value : nil
  end

  # True when the latest JSONL event is a previous-run/previous-cycle snapshot
  # and must not be presented as the current route/cycle.
  def operator_event_stale?(random_production)
    rp = random_production || {}
    return rp[:latest_event_stale] if rp.key?(:latest_event_stale)

    rp[:latest_event].blank?
  end

  # Single coherent view-model consumed by the JSON refresh endpoint and by the
  # control-center partial. Pure: built entirely from the passed-in report.
  def operator_view_model(random_production, position)
    rp = random_production || {}
    state = operator_state(rp, position)
    freshness = operator_status_freshness(rp)
    venue = HedgeVenues.normalize(rp[:current_production_venue].presence || position&.hedge&.execution_venue)
    {
      status: operator_runner_status(rp),
      running: operator_runner_status(rp) == "running",
      market_safe: rp[:current_direct_market_safe],
      production_venue: venue,
      production_venue_name: HedgeVenues.label(venue),
      active_venue_count: operator_active_venue_count(rp),
      active_short_eth: operator_active_short_eth(rp, venue),
      target_short_eth: rp[:target_short_eth],
      combined_short_eth: rp[:combined_short_eth],
      drift_eth: rp[:drift_eth],
      tolerance_eth: rp[:tolerance_eth],
      inside_tolerance: rp[:inside_tolerance],
      open_orders_zero: rp[:open_orders_zero],
      current_blockers: operator_blockers(rp),
      historical_blocker: operator_historical_blocker(rp),
      latest_event_stale: operator_event_stale?(rp),
      banner_tone: state[:tone],
      banner_title: state[:title],
      banner_detail: state[:detail],
      action_title: state[:action_title],
      action_body: state[:action_body],
      allow_start: state[:allow_start],
      freshness: freshness
    }
  end

  private

  # The latest event only when it represents the CURRENT run; otherwise an empty
  # hash so callers render "waiting for first cycle event" instead of stale data.
  def operator_current_event(random_production)
    return {} if operator_event_stale?(random_production)

    (random_production || {})[:latest_event] || {}
  end

  def operator_duration_words(seconds)
    return "#{seconds}s" if seconds < 60
    return "#{seconds / 60}m #{seconds % 60}s" if seconds < 3600

    "#{seconds / 3600}h #{(seconds % 3600) / 60}m"
  end

  def operator_runner_status(random_production)
    return "stale lock" if random_production[:lock_stale]

    random_production[:status].to_s.presence || "unknown"
  end

  # Authoritative current blockers only. The runner writes these into the live
  # status payload every cycle. We deliberately do NOT fall back to the JSONL
  # latest_event blocker here: a historical/stale blocker must never drive the
  # current recommended action. See {operator_historical_blocker} for that.
  def operator_blockers(random_production)
    blockers = Array(random_production[:current_blockers])
    return blockers if blockers.present?

    # Back-compat for callers/tests that only set :direct_preflight_blockers.
    Array(random_production[:direct_preflight_blockers]).map { |b| b.to_s.strip }.reject(&:blank?)
  end

  def operator_blocked(key, title, detail, action_body)
    {
      tone: :red, key: key, allow_start: false,
      title: title, detail: detail,
      action_title: "Do not start the runner", action_body: action_body
    }
  end

  def operator_stopped_state(random_production, venue_name, blockers, inside_tolerance, active_count, market_safe)
    if blockers.present?
      return {
        tone: :red, key: "stopped", allow_start: false,
        title: "Action required — review blockers",
        detail: "The runner is stopped and at least one current blocker is present.",
        action_title: "Resolve blockers before starting",
        action_body: "Do not start 24/7 production yet: #{blockers.first}"
      }
    end

    # When the authoritative direct readback says the market is safe, the
    # stopped runner is always safe-to-start — never red. We only fall through
    # to the hedge-missing / confirm paths when safety is NOT confirmed.
    unless market_safe == true
      target = operator_decimal(random_production[:target_short_eth])
      if active_count.zero? && operator_decimal_known?(random_production[:target_short_eth]) && target > ACTIVE_SHORT_THRESHOLD_ETH
        return {
          tone: :red, key: "hedge_missing", allow_start: false,
          title: "Action required — hedge missing",
          detail: "No venue is holding the hedge, but the position needs a #{format_venue_eth_amount(random_production[:target_short_eth])} ETH short.",
          action_title: "Restore the hedge",
          action_body: "Open the hedge on the production venue (supervised) before starting 24/7 production."
        }
      end
    end

    if market_safe == true || (active_count <= 1 && inside_tolerance != false)
      {
        tone: :blue, key: "stopped_safe", allow_start: true,
        title: "Stopped but hedge is safe",
        detail: "24/7 random rotation is stopped. Market is currently safe on #{venue_name}.",
        action_title: "Safe to start when ready",
        action_body: "Runner is stopped, but hedge is safe. You may start 24/7 production if no blockers are present."
      }
    else
      {
        tone: :amber, key: "stopped_attention", allow_start: false,
        title: "Stopped — confirm hedge before starting",
        detail: "24/7 random rotation is stopped and the hedge state needs confirmation on #{venue_name}.",
        action_title: "Confirm before starting",
        action_body: "Refresh read-only data and confirm exactly one hedge inside tolerance before starting 24/7 production."
      }
    end
  end

  def operator_open_orders_text(status)
    case status.to_s
    when "zero" then "0"
    when "" then "Unknown — not read back yet"
    else status.to_s.humanize
    end
  end

  def operator_readback_text(state, carried)
    return "Failed — carried forward" if carried

    case state[:source_status].to_s
    when "ok" then "Fresh"
    when "stale" then "Stale"
    when "error" then "Failed"
    else "Unknown"
    end
  end

  def operator_hold_checks_per_cycle
    interval = MigrationRandomProductionRunner::DEFAULT_INTERVAL_SECONDS.to_i
    hold = MigrationRandomProductionRunner::DEFAULT_REBALANCE_HOLD_INTERVAL_SECONDS.to_i
    hold.positive? ? interval / hold : 0
  end

  def operator_decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end

  def operator_decimal_known?(value)
    return false if value.nil? || value.to_s.strip.empty?

    BigDecimal(value.to_s)
    true
  rescue ArgumentError, TypeError
    false
  end

  def operator_parse_time(value)
    return nil if value.blank?

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
