module HedgeVenueAutoAdapters
  class Base
    def initialize(env: ENV, fresh_target_factory: nil, now: -> { Time.current })
      @env = env
      @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
      @now = now
    end

    private

    attr_reader :env, :now

    def base_report(position:, venue:, current_position:, other_positions:, account_state:, live_enabled:, auto_enabled:, extra_blockers: [], warnings: [])
      fresh = @fresh_target_factory.call(position).resolve(refresh_if_stale: true)
      target = decimal_or_nil(fresh[:target_short_eth])
      current = short_size(current_position)
      tolerance = target && position.hedge ? target * BigDecimal(position.hedge.tolerance.to_s) : nil
      drift = target ? target - current : nil
      action = planned_action(drift, tolerance)
      size = action.in?(%w[increase_short decrease_short]) ? drift.abs : nil
      side = action == "increase_short" ? "sell" : (action == "decrease_short" ? "buy" : nil)
      reduce_only = action == "decrease_short" ? true : (action == "increase_short" ? false : nil)
      expected_after = expected_after(current: current, drift: drift, action: action)
      blockers = common_blockers(
        position: position,
        venue: venue,
        fresh_target: fresh,
        target: target,
        account_state: account_state,
        other_positions: other_positions,
        extra_blockers: extra_blockers
      )

      {
        venue: venue,
        action: "auto_readiness",
        timestamp: now.call.utc.iso8601,
        position_id: position.id,
        hedge_id: position.hedge&.id,
        execution_venue: position.hedge&.execution_venue,
        active_auto_venue: venue,
        target_short_eth: decimal_string(target),
        active_target_short_eth: decimal_string(target),
        target_source: fresh[:target_source],
        exposure_source: fresh[:exposure_source],
        exposure_refreshed_at: fresh[:exposure_refreshed_at],
        exposure_stale: fresh[:exposure_stale],
        current_short_eth: decimal_string(current),
        active_current_short_eth: decimal_string(current),
        drift_eth: decimal_string(drift),
        active_drift_eth: decimal_string(drift),
        tolerance_eth: decimal_string(tolerance),
        active_tolerance_eth: decimal_string(tolerance),
        within_tolerance: within_tolerance?(drift, tolerance),
        active_within_tolerance: within_tolerance?(drift, tolerance),
        planned_auto_action: action,
        active_planned_auto_action: action,
        side: side,
        reduce_only: reduce_only,
        requested_size_eth: decimal_string(size),
        expected_after_short_eth: decimal_string(expected_after),
        expected_inside_tolerance: expected_after && target && tolerance ? (target - expected_after).abs <= tolerance : nil,
        active_auto_enabled: auto_enabled,
        active_live_enabled: live_enabled,
        continuous_auto_ready: blockers.empty?,
        active_auto_ready: blockers.empty?,
        auto_can_act: blockers.empty? && action != "no_op",
        blockers: blockers,
        active_auto_blockers: blockers,
        warnings: warnings,
        active_auto_warnings: warnings,
        open_orders_count: account_state[:open_orders_count],
        open_orders_read_attempted: account_state[:open_orders_read_attempted],
        open_orders_read_status: account_state[:open_orders_read_status],
        open_orders_diagnostics: account_state[:open_orders_diagnostics],
        other_venue_shorts: other_positions.transform_values { |position_payload| decimal_string(short_size(position_payload)) },
        orders_submitted: 0,
        signatures_created: 0
      }.compact
    end

    def common_blockers(position:, venue:, fresh_target:, target:, account_state:, other_positions:, extra_blockers:)
      blockers = []
      blockers << "Position hedge execution_venue must be #{venue} for #{HedgeVenues.label(venue)} continuous auto" unless HedgeVenues.normalize(position.hedge&.execution_venue) == venue
      blockers.concat(Array(fresh_target[:blockers]))
      blockers << "fresh Mellow target is required before #{HedgeVenues.label(venue)} auto sizing" unless fresh_target[:status] == "ok" && target
      blockers << "#{HedgeVenues.label(venue)} auto requires open_orders_count=0" if account_state[:open_orders_count].present? && account_state[:open_orders_count].to_i.nonzero?
      blockers.concat(conflicting_venue_blockers(venue, other_positions))
      blockers.concat(migration_gate_blockers(position))
      blockers.concat(extra_blockers)
      blockers.uniq
    end

    def conflicting_venue_blockers(active_venue, other_positions)
      other_positions.filter_map do |venue, position_payload|
        next if venue == active_venue
        next if short_size(position_payload).zero?

        "#{HedgeVenues.label(venue)} must be flat before #{HedgeVenues.label(active_venue)} continuous auto"
      end
    end

    def migration_gate_blockers(position)
      blockers = []
      blockers << "migration is in progress for this position; continuous auto is paused" if MigrationExecutionLock.locked?(position)
      blockers << "MIGRATION_MANUAL_LIVE_CANARY_ENABLED must be false during continuous auto" if bool_env("MIGRATION_MANUAL_LIVE_CANARY_ENABLED")
      blockers << "MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED must be false during continuous auto" if bool_env("MIGRATION_TARGET_FIRST_SOURCE_RECOVERY_ENABLED")
      blockers
    end

    def planned_action(drift, tolerance)
      return "blocked" unless drift && tolerance
      return "no_op" if drift.abs <= tolerance

      drift.positive? ? "increase_short" : "decrease_short"
    end

    def expected_after(current:, drift:, action:)
      return current if action == "no_op" || drift.nil?

      action.in?(%w[increase_short decrease_short]) ? current + drift : nil
    end

    def within_tolerance?(drift, tolerance)
      return nil unless drift && tolerance

      drift.abs <= tolerance
    end

    def short_size(position_payload)
      return BigDecimal("0") unless position_payload.is_a?(Hash)
      return BigDecimal(position_payload[:short_size].to_s) if position_payload[:short_size].present?

      size = BigDecimal(position_payload.fetch(:size, 0).to_s)
      size.negative? ? size.abs : BigDecimal("0")
    rescue ArgumentError, KeyError
      BigDecimal("0")
    end

    def decimal_or_nil(value)
      return nil if value.blank?

      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def decimal_string(value)
      return nil if value.nil?

      BigDecimal(value.to_s).to_s("F")
    rescue ArgumentError, TypeError
      nil
    end

    def bool_env(key)
      OperationalSettings.enabled?(key, env: env)
    end
  end
end
