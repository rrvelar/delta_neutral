# File-backed record of Extended order-submit health (2026-07-17: submits
# returned HTTP 503 / Net::ReadTimeout while position reads stayed healthy, so
# venue read health is NOT evidence that submits work). Written by the Extended
# API client on every order submit; read by status/dashboard warnings. Never
# raises into the trading path.
module ExtendedSubmitHealth
  DEFAULT_WINDOW_SECONDS = 24 * 3600

  class << self
    attr_writer :path

    def path
      @path ||= Rails.root.join("storage/extended_submit_health.json")
    end

    def record_failure!(error:, http_status: nil, now: Time.current)
      state = snapshot
      write(
        state.merge(
          "last_failure_at" => now.utc.iso8601,
          "last_error" => error.to_s,
          "last_http_status" => http_status,
          "consecutive_failures" => state.fetch("consecutive_failures", 0).to_i + 1
        )
      )
    rescue StandardError
      nil
    end

    def record_success!(now: Time.current)
      state = snapshot
      write(
        state.merge(
          "last_success_at" => now.utc.iso8601,
          "consecutive_failures" => 0
        )
      )
    rescue StandardError
      nil
    end

    # A failure is "recent" when it happened inside the window and no submit has
    # succeeded since.
    def recently_failed?(window_seconds: DEFAULT_WINDOW_SECONDS, now: Time.current)
      state = snapshot
      failed_at = parse_time(state["last_failure_at"])
      return false unless failed_at
      return false if now.utc - failed_at > window_seconds

      succeeded_at = parse_time(state["last_success_at"])
      succeeded_at.nil? || succeeded_at < failed_at
    rescue StandardError
      false
    end

    def snapshot
      return {} unless File.exist?(path)

      JSON.parse(File.read(path))
    rescue StandardError
      {}
    end

    private

    def write(state)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(state))
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)&.utc
    rescue ArgumentError, TypeError
      nil
    end
  end
end
