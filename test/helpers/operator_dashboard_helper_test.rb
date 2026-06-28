require "test_helper"

class OperatorDashboardHelperTest < ActionView::TestCase
  include OperatorDashboardHelper
  include ApplicationHelper

  Hedge = Struct.new(:execution_venue)
  Position = Struct.new(:hedge)

  def nado_position
    Position.new(Hedge.new("nado"))
  end

  def running_safe_status
    {
      status: "running",
      current_production_venue: "nado",
      inside_tolerance: true,
      open_orders_zero: true,
      direct_preflight_blockers: [],
      direct_venue_shorts: { "extended" => "0", "ethereal" => "0", "nado" => "2.12" },
      direct_open_orders: HedgeVenues::SUPPORTED_KEYS.to_h { |v| [ v, { "status" => "zero", "count" => 0 } ] },
      last_route: "extended->nado",
      latest_event: { "route" => "extended->nado", "status" => "success", "hold_rebalance_checks_count" => 13 }
    }
  end

  test "running and safe yields green no-action state" do
    state = operator_state(running_safe_status, nado_position)

    assert_equal :green, state[:tone]
    assert_equal "Running normally — no action needed", state[:title]
    assert_equal "No action needed", state[:action_title]
    assert_match "Do not press Start again", state[:action_body]
    assert_equal false, state[:allow_start]
  end

  test "running but outside tolerance yields amber attention and no start" do
    state = operator_state(running_safe_status.merge(inside_tolerance: false), nado_position)

    assert_equal :amber, state[:tone]
    assert_equal "Running — operator attention", state[:title]
    assert_equal false, state[:allow_start]
    assert_match "outside tolerance", state[:detail]
  end

  test "stopped with single safe hedge allows start" do
    status = running_safe_status.merge(status: "unavailable", target_short_eth: "2.12")
    state = operator_state(status, nado_position)

    assert_equal :blue, state[:tone]
    assert_equal "Stopped but hedge is safe", state[:title]
    assert_equal true, state[:allow_start]
    assert_match "You may start 24/7 production", state[:action_body]
  end

  test "stopped with no hedge but a required target is action required" do
    status = running_safe_status.merge(
      status: "unavailable",
      inside_tolerance: nil,
      target_short_eth: "2.12",
      direct_venue_shorts: { "extended" => "0", "ethereal" => "0", "nado" => "0" }
    )
    state = operator_state(status, nado_position)

    assert_equal :red, state[:tone]
    assert_equal "Action required — hedge missing", state[:title]
    assert_equal false, state[:allow_start]
  end

  test "multiple exposure is a red blocker with no start" do
    state = operator_state(running_safe_status.merge(status: "unsafe_multiple_exposure"), nado_position)

    assert_equal :red, state[:tone]
    assert_equal "Blocked — multiple exposure", state[:title]
    assert_equal false, state[:allow_start]
    assert_match "Do not start 24/7 production", state[:action_body]
  end

  test "active venue mismatch is a clearly explained red blocker" do
    state = operator_state(running_safe_status.merge(status: "active_venue_mismatch"), nado_position)

    assert_equal :red, state[:tone]
    assert_equal "Blocked — active venue mismatch", state[:title]
    assert_match "supervised adopt/sync", state[:action_body]
  end

  test "stale lock surfaces amber attention" do
    state = operator_state(running_safe_status.merge(lock_stale: true, status: "running"), nado_position)

    assert_equal :amber, state[:tone]
    assert_equal "Attention — stale runner lock", state[:title]
  end

  test "venue cards reflect runner truth and never render Unavailable" do
    status = running_safe_status.merge(
      direct_venue_shorts: { "extended" => nil, "ethereal" => "0", "nado" => "2.12" }
    )
    cards = operator_venue_cards(status, {})

    nado = cards.find { |c| c[:venue] == "nado" }
    ethereal = cards.find { |c| c[:venue] == "ethereal" }
    extended = cards.find { |c| c[:venue] == "extended" }

    assert_equal "Active hedge", nado[:status_label]
    assert nado[:production]
    assert_equal :green, nado[:tone]
    assert_equal "Flat", ethereal[:status_label]
    assert_equal "Unknown", extended[:status_label]
    assert_equal :amber, extended[:tone]
    cards.each { |card| refute_match(/Unavailable/, card.values.join(" ")) }
  end

  test "carried-forward extended exposure is a diagnostic only on the card" do
    venue_states = {
      extended: {
        carried_forward_exposure: true,
        carried_forward_short_eth_display: "1.997000",
        source_status: "stale"
      }
    }
    cards = operator_venue_cards(running_safe_status, venue_states)
    extended = cards.find { |c| c[:venue] == "extended" }

    assert extended[:carried_forward]
    assert_equal "1.997000 ETH", extended[:carried_forward_text]
    assert_equal "Failed — carried forward", extended[:readback_text]
  end

  test "hold progress estimates against the per-cycle check budget" do
    progress = operator_hold_progress(running_safe_status)

    assert_equal 13, progress[:current]
    assert_equal 96, progress[:total]
    assert_equal 14, progress[:percent]
    assert_equal "13 / ~96 checks", progress[:label]
  end

  test "route progress reads the latest completed route" do
    route = operator_route_progress(running_safe_status)

    assert_equal "Extended", route[:from_name]
    assert_equal "Nado", route[:to_name]
    assert route[:source_closed]
    assert route[:production_venue_finalized]
  end

  # The exact production bug: authoritative status is safe with no current
  # blockers, but a stale heartbeat / previous-run event carries an old blocker
  # and an old combined short. The dashboard must trust the authoritative status.
  def ethereal_position
    Position.new(Hedge.new("ethereal"))
  end

  def stale_blocker_bug_status(status: "running")
    {
      status: status,
      current_direct_market_safe: true,
      current_blockers: [],
      historical_blocker: "active venue one-shot rebalance status is blocked_before_submit",
      latest_event_stale: true,
      current_production_venue: "ethereal",
      inside_tolerance: true,
      open_orders_zero: true,
      direct_venue_shorts: { "extended" => "0", "ethereal" => "2.4027", "nado" => "0" },
      direct_open_orders: HedgeVenues::SUPPORTED_KEYS.to_h { |v| [ v, { "status" => "zero", "count" => 0 } ] },
      target_short_eth: "2.554154",
      combined_short_eth: "2.5627",
      last_cycle: 18,
      latest_event: { "route" => "nado->ethereal", "cycle" => 18, "blockers" => [ "active venue one-shot rebalance status is blocked_before_submit" ] }
    }
  end

  test "stale historical blocker is ignored when authoritative current blockers are empty" do
    state = operator_state(stale_blocker_bug_status(status: "running"), ethereal_position)

    refute_equal :red, state[:tone]
    refute_match(/Resolve blockers/, state[:action_title].to_s)
    assert_empty operator_blockers(stale_blocker_bug_status)
  end

  test "stopped but safe is blue and start-enabled despite a stale historical blocker" do
    state = operator_state(stale_blocker_bug_status(status: "stopped"), ethereal_position)

    assert_equal :blue, state[:tone]
    assert_equal true, state[:allow_start]
    refute_match(/Resolve blockers/, state[:action_title].to_s)
  end

  test "current unsafe blockers are shown red and block start" do
    status = running_safe_status.merge(
      status: "blocked",
      current_direct_market_safe: false,
      current_blockers: [ "direct preflight open orders are nonzero or unknown" ]
    )
    state = operator_state(status, nado_position)

    assert_equal :red, state[:tone]
    assert_equal false, state[:allow_start]
    assert_match "open orders", state[:action_body]
  end

  test "active short uses the direct current venue short not the stale heartbeat combined" do
    vm = operator_view_model(stale_blocker_bug_status, ethereal_position)

    assert_equal "2.4027", vm[:active_short_eth].to_s
    refute_equal "2.5627", vm[:active_short_eth].to_s
    assert_equal "2.5627", vm[:combined_short_eth].to_s
  end

  test "historical blocker is surfaced separately as a stale diagnostic" do
    historical = operator_historical_blocker(stale_blocker_bug_status)

    assert_equal "active venue one-shot rebalance status is blocked_before_submit", historical[:text]
    assert historical[:stale]
    assert_equal 18, historical[:cycle]
  end

  test "stale latest_event is not shown as the current route" do
    route = operator_route_progress(stale_blocker_bug_status)

    assert_nil route[:route]
    assert_nil route[:from_name]
  end

  test "view-model is internally coherent for the safe-running case" do
    vm = operator_view_model(stale_blocker_bug_status, ethereal_position)

    assert_equal true, vm[:market_safe]
    assert_empty vm[:current_blockers]
    refute_equal :red, vm[:banner_tone]
    assert_equal "2.4027", vm[:active_short_eth].to_s
  end

  test "status freshness flags a stale status file by age" do
    fresh = operator_status_freshness(status_updated_at: Time.current.iso8601)
    stale = operator_status_freshness(status_updated_at: 1.hour.ago.iso8601)
    missing = operator_status_freshness({})

    refute fresh[:stale]
    assert_equal :green, fresh[:tone]
    assert stale[:stale]
    assert_equal :amber, stale[:tone]
    assert missing[:stale]
  end
end
