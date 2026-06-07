module HedgeVenueAutoRebalanceAdapters
  class Nado
    def initialize(env: ENV, readiness: HedgeVenueAutoAdapters::Nado.new(env: env), service: NadoHedgeExecutionService.new(env: env), now: -> { Time.current })
      @env = env
      @readiness = readiness
      @service = service
      @now = now
    end

    def run(position:, dry_run:, live:, confirmation:, max_slippage:, one_shot: true)
      report = @readiness.readiness(position: position, mode: one_shot ? :manual_one_shot : :continuous_auto)
      blockers = Array(report[:blockers])
      blockers << "submitted confirmation must equal #{nado_confirmation_phrase}" if live && one_shot && (nado_confirmation_phrase.blank? || confirmation.to_s != nado_confirmation_phrase)
      preview = order_preview(position: position, report: report, max_slippage: max_slippage)
      blockers.concat(Array(preview&.fetch(:blockers, [])))
      return result(status: dry_run || !live ? "dry_run" : "blocked_before_submit", report: report, blockers: blockers, dry_run: dry_run || !live, one_shot: one_shot, preview: preview) if dry_run || !live || blockers.any? || report[:planned_auto_action] == "no_op"

      execution = @service.rebalance_short(
        position: position,
        delta_eth: BigDecimal(report.fetch(:drift_eth).to_s),
        current_position: @service.read_position,
        confirmation: confirmation,
        max_slippage: max_slippage,
        require_confirmation: one_shot
      )
      execution = @service.reconcile_pending_result(
        execution,
        expected_short: report[:expected_after_short_eth],
        target_short: report[:target_short_eth],
        tolerance_eth: report[:tolerance_eth]
      )
      result(status: execution.status, report: report, blockers: execution.blockers, dry_run: false, one_shot: one_shot, preview: preview, execution: execution.receipt)
    end

    private

    attr_reader :env

    def order_preview(position:, report:, max_slippage:)
      return nil unless report[:planned_auto_action].to_s.in?(%w[increase_short decrease_short])

      @service.build_order_preview(
        position: position,
        action: "rebalance",
        size_eth: BigDecimal(report.fetch(:drift_eth).to_s),
        max_slippage: max_slippage,
        current_position: @service.read_position
      )
    end

    def result(status:, report:, blockers:, dry_run:, one_shot:, preview:, execution: nil)
      receipt = {
        venue: "nado",
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
        order_preview: sanitize_preview(preview),
        blockers: blockers.uniq,
        warnings: report[:warnings],
        exchange_order_id: execution&.fetch(:exchange_order_id, nil),
        execution_timing: execution&.fetch(:execution_timing, nil),
        submit_latency_seconds: execution&.fetch(:submit_latency_seconds, nil),
        readback_latency_seconds: execution&.fetch(:readback_latency_seconds, nil),
        total_action_latency_seconds: execution&.fetch(:total_action_latency_seconds, nil),
        slow_step: execution&.fetch(:slow_step, nil),
        readback_confirmed: readback_confirmed?(execution, status),
        execution_receipt: execution,
        final_status: final_status_for(status, execution),
        lifecycle_state: lifecycle_state_for(status, execution),
        manual_action_required: manual_action_required?(status, execution),
        orders_submitted: submitted_count(execution, status),
        orders_placed: submitted_count(execution, status),
        signatures_created: signature_count(execution, status)
      }.compact
      HedgeVenueAutoRebalanceOnce::Result.new(status, receipt[:blockers], receipt[:warnings], receipt)
    end

    def sanitize_preview(preview)
      return nil unless preview

      preview.slice(:ok, :summary, :timing, :blockers, :warnings)
    end

    def submitted_count(execution, status)
      return 0 unless execution

      explicit = execution[:orders_placed] || execution[:orders_submitted]
      return explicit.to_i unless explicit.nil?
      return 1 if execution[:exchange_order_id].present?

      status.to_s.start_with?("submitted") || status.to_s.start_with?("rebalance_confirmed") ? 1 : 0
    end

    def signature_count(execution, status)
      return 0 unless execution

      explicit = execution[:signatures_created]
      return explicit.to_i unless explicit.nil?
      return 1 if execution[:exchange_order_id].present?

      status.to_s.start_with?("submitted") || status.to_s.start_with?("rebalance_confirmed") ? 1 : 0
    end

    def nado_confirmation_phrase
      env["AERODROME_NADO_HEDGE_CONFIRMATION"].to_s
    end

    def source_for(dry_run:, one_shot:)
      return "dry_run" if dry_run

      one_shot ? "manual_one_shot" : "continuous_auto"
    end

    def readback_confirmed?(execution, status)
      return false unless execution
      return true if execution[:readback_confirmed] == true

      execution.dig(:post_submit_readback).present? && status.to_s.in?(%w[submitted_and_confirmed rebalance_confirmed_late])
    end

    def final_status_for(status, execution)
      execution_status = execution&.fetch(:final_status, nil).presence
      return "REBALANCE_CONFIRMED" if execution_status == "submitted_and_confirmed"
      return "REBALANCE_REQUIRES_RECHECK" if execution_status.to_s.start_with?("submitted_but")

      execution_status || status
    end

    def lifecycle_state_for(status, execution)
      execution&.fetch(:lifecycle_state, nil).presence ||
        case status.to_s
        when "submitted_and_confirmed"
          "REBALANCE_CONFIRMED"
        when "rebalance_confirmed_late"
          "CONFIRMED_LATE_BY_RECONCILIATION"
        when "submitted_pending_readback", "submitted_but_readback_pending", "submitted_but_not_confirmed"
          "SUBMITTED_PENDING_READBACK"
        when "blocked_before_submit"
          "REJECTED_OR_NOT_SUBMITTED"
        else
          status.to_s.upcase
        end
    end

    def manual_action_required?(status, execution)
      return execution[:manual_action_required] if execution&.key?(:manual_action_required)

      status.to_s.in?(%w[submitted_pending_readback submitted_but_readback_pending submitted_but_not_confirmed failed_before_submit blocked_before_submit])
    end
  end
end
