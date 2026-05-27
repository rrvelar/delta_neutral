class PositionRewardsFeesSnapshot < ApplicationRecord
  belongs_to :position

  def warnings_list
    parse_json_array(warnings)
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

  private

  def parse_json_array(value)
    return [] if value.blank?

    parsed = JSON.parse(value)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError, TypeError
    []
  end
end
