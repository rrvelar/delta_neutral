module HedgeVenueAutoRebalanceAdapters
  class Ethereal
    CONFIRMATION = HedgeVenueAutoAdapters::Ethereal::CONFIRMATION

    def initialize(env: ENV, readiness: HedgeVenueAutoAdapters::Ethereal.new(env: env), service: EtherealHedgeExecutionService.new(env: env), now: -> { Time.current })
      @env = env
      @readiness = readiness
      @service = service
      @now = now
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:, one_shot: true)
      report = @readiness.readiness(position: position)
      blockers = Array(report[:blockers])
      blockers << "submitted confirmation must equal #{CONFIRMATION}" if live && one_shot && confirmation != CONFIRMATION
      return result(status: dry_run || !live ? "dry_run" : "blocked_before_submit", report: report, blockers: blockers, dry_run: dry_run || !live, one_shot: one_shot) if dry_run || !live || blockers.any? || report[:planned_auto_action] == "no_op"

      execution = @service.rebalance_short(
        position: position,
        delta_eth: BigDecimal(report.fetch(:drift_eth).to_s),
        current_position: @service.read_position,
        confirmation: nil,
        max_slippage: max_slippage,
        require_confirmation: false
      )
      result(status: execution.status, report: report, blockers: execution.blockers, dry_run: false, one_shot: one_shot, execution: execution.receipt)
    end

    private

    def result(status:, report:, blockers:, dry_run:, one_shot:, execution: nil)
      receipt = {
        venue: "ethereal",
        action: "auto_rebalance_once",
        source: source_for(dry_run: dry_run, one_shot: one_shot),
        one_shot: one_shot,
        dry_run: dry_run,
        live: !dry_run,
        timestamp: @now.call.utc.iso8601,
        position_id: report[:position_id],
        planned_auto_action: report[:planned_auto_action],
        current_short_eth: report[:current_short_eth],
        target_short_eth: report[:target_short_eth],
        drift_eth: report[:drift_eth],
        tolerance_eth: report[:tolerance_eth],
        requested_size_eth: report[:requested_size_eth],
        side: report[:side],
        reduce_only: report[:reduce_only],
        expected_after_short_eth: report[:expected_after_short_eth],
        blockers: blockers.uniq,
        warnings: report[:warnings],
        exchange_order_id: execution&.fetch(:exchange_order_id, nil),
        execution_timing: execution&.fetch(:execution_timing, nil),
        submit_latency_seconds: execution&.fetch(:submit_latency_seconds, nil),
        readback_latency_seconds: execution&.fetch(:readback_latency_seconds, nil),
        total_action_latency_seconds: execution&.fetch(:total_action_latency_seconds, nil),
        slow_step: execution&.fetch(:slow_step, nil),
        readback_confirmed: execution&.dig(:post_submit_readback).present? && status == "submitted_and_confirmed",
        execution_receipt: execution,
        final_status: status,
        orders_submitted: execution ? (execution[:orders_placed] || execution[:orders_submitted] || (execution[:submitted] ? 1 : 0)).to_i : 0,
        orders_placed: execution ? (execution[:orders_placed] || execution[:orders_submitted] || (execution[:submitted] ? 1 : 0)).to_i : 0,
        signatures_created: execution ? execution[:signatures_created].to_i : 0
      }.compact
      HedgeVenueAutoRebalanceOnce::Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
    end

    def source_for(dry_run:, one_shot:)
      return "dry_run" if dry_run

      one_shot ? "manual_one_shot" : "continuous_auto"
    end
  end
end
