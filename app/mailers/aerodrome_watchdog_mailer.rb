class AerodromeWatchdogMailer < ApplicationMailer
  def watchdog_alert(recipient:, alert:)
    @alert = alert

    mail(
      to: recipient,
      subject: "[Aerodrome #{alert.fetch(:severity).upcase}] #{alert.fetch(:title)}",
      body: plain_text_body(alert),
      content_type: "text/plain"
    )
  end

  private

  def plain_text_body(alert)
    [
      alert.fetch(:title),
      "",
      "This alert is read-only. It did not close or open positions.",
      "",
      "Timestamp: #{alert.fetch(:timestamp)}",
      "Git SHA: #{alert.fetch(:git_sha) || "unavailable"}",
      "Severity: #{alert.fetch(:severity)}",
      "Status: #{alert.fetch(:status)}",
      "Summary: #{alert.fetch(:summary)}",
      "",
      "Safe env:",
      formatted_hash(alert.fetch(:safe_env)),
      "",
      "Latest observation:",
      formatted_observation(alert.fetch(:latest_observation_summary)),
      "",
      "Blockers:",
      formatted_list(alert.fetch(:blockers)),
      "",
      "Warnings:",
      formatted_list(alert.fetch(:warnings)),
      "",
      "Recommended actions:",
      formatted_list(alert.fetch(:recommended_actions)),
      "",
      "Body:",
      alert.fetch(:body)
    ].join("\n")
  end

  def formatted_hash(values)
    return "  none" if values.empty?

    values.map { |key, value| "  #{key}=#{value.inspect}" }.join("\n")
  end

  def formatted_observation(values)
    return "  unavailable" if values.empty?

    values.map { |item| "  #{item.fetch(:name)}: #{item.fetch(:status)}#{format_value(item)}" }.join("\n")
  end

  def formatted_list(values)
    return "  none" if values.empty?

    values.map { |value| "  - #{value}" }.join("\n")
  end

  def format_value(item)
    return "" unless item.key?(:value)

    " (#{item.fetch(:value)})"
  end
end
