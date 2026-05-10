class AerodromeLiveObservationSummary
  BANNER = "AERODROME LIVE OBSERVATION SUMMARY — READ ONLY"

  def initialize(log_dir: Rails.root.join("storage", "aerodrome_live_observation"), log_path: nil)
    @log_dir = Pathname(log_dir)
    @log_path = log_path && Pathname(log_path)
    @warnings = []
    @blockers = []
  end

  def report
    path = selected_log_path
    unless path&.exist?
      @warnings << "No Aerodrome live observation JSONL log found"
      return base_report(path, [], nil).merge(status: status)
    end

    events = read_events(path)
    final = events.reverse.find { |event| event["type"] == "final" }
    report = base_report(path, events, final)
    evaluate_final(final, report)
    report.merge(status: status, blockers: @blockers, warnings: @warnings, next_steps: next_steps)
  rescue JSON::ParserError => e
    @blockers << "Observation log JSON parse failed: #{e.message}"
    base_report(path, [], nil).merge(status: status)
  end

  private

  def selected_log_path
    return @log_path if @log_path
    return nil unless @log_dir.exist?

    @log_dir.children.select { |path| path.extname == ".jsonl" }.max_by { |path| [ path.mtime, path.to_s ] }
  end

  def read_events(path)
    path.readlines(chomp: true).reject(&:blank?).map { |line| JSON.parse(line) }
  end

  def base_report(path, events, final)
    iterations = events.select { |event| event["type"] == "iteration" }
    timestamps = iterations.filter_map { |event| parse_time(event["timestamp"]) }
    {
      safety_banner: BANNER,
      database_write: false,
      orders_enabled: false,
      hyperliquid_execution: false,
      log_path: path&.to_s,
      duration_seconds: duration_seconds(timestamps),
      iterations: iterations.size,
      first_timestamp: timestamps.first&.iso8601,
      last_timestamp: timestamps.last&.iso8601,
      max_observed_eth_short: max_observed_eth_short(events).to_s("F"),
      rebalances_count: iterations.sum { |event| Array(event["new_short_rebalances"]).size },
      errors_count: events.sum { |event| Array(event["errors"]).size },
      final_close_status: final&.dig("final_close", "status"),
      final_position: final&.fetch("final_position", nil),
      final_position_confirmed: final&.fetch("final_position_confirmed", nil),
      manual_action_required: final&.fetch("manual_action_required", nil),
      blockers: @blockers,
      warnings: @warnings,
      next_steps: next_steps
    }
  end

  def evaluate_final(final, report)
    unless final
      @warnings << "Observation log has no final event"
      return
    end

    @blockers << "Observation final manual_action_required=true" if report.fetch(:manual_action_required) == true
    @blockers << "Observation final position is not nil" if report.fetch(:final_position).present?
    @blockers << "Observation final close did not report success" unless report.fetch(:final_close_status) == "success"
  end

  def max_observed_eth_short(events)
    positions = events.filter_map do |event|
      event["actual_eth_position"] || event["final_position"]
    end
    positions.map { |position| short_size(position) }.max || BigDecimal("0")
  end

  def short_size(position)
    return BigDecimal("0") unless position

    size = BigDecimal(position.fetch("size").to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue KeyError, ArgumentError
    BigDecimal("0")
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def duration_seconds(timestamps)
    return nil if timestamps.size < 2

    (timestamps.last - timestamps.first).to_i
  end

  def status
    return "BLOCKED" if @blockers.any?
    return "WARN" if @warnings.any?

    "PASS"
  end

  def next_steps
    return [ "Resolve blockers and verify final mainnet ETH position before any further live run." ] if @blockers.any?
    return [ "Review warnings before relying on observation summary." ] if @warnings.any?

    [ "Observation summary is read-only evidence only. It is not live-operation approval." ]
  end
end
