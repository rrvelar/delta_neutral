class PositionHedgeAccountingSnapshot < ApplicationRecord
  belongs_to :position

  def unavailable_components_list
    return [] if unavailable_components.blank?

    parsed = JSON.parse(unavailable_components)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError, TypeError
    []
  end

  def source_errors_hash
    return {} if source_errors.blank?

    JSON.parse(source_errors)
  rescue JSON::ParserError, TypeError
    {}
  end

  def stale_now?
    refreshed_at.blank? || refreshed_at < 15.minutes.ago || refresh_status != "ok"
  end
end
