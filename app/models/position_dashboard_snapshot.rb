class PositionDashboardSnapshot < ApplicationRecord
  STALE_AFTER = 10.minutes
  STATUSES = %w[ok partial error unknown].freeze
  VENUE_STATUSES = %w[active flat unknown error].freeze

  belongs_to :position

  validates :refresh_status, inclusion: { in: STATUSES }

  def stale_now?
    stale? || refreshed_at.nil? || refreshed_at < STALE_AFTER.ago
  end

  def source_errors_hash
    return {} if source_errors.blank?

    JSON.parse(source_errors)
  rescue JSON::ParserError
    {}
  end

  def venue_state(venue)
    key = venue.to_s
    {
      venue: key,
      venue_name: HedgeVenues.label(key),
      short_size: public_send("#{key}_short_eth"),
      short_size_eth: decimal_string(public_send("#{key}_short_eth")),
      status: public_send("#{key}_status").presence || "unknown",
      notional_usd: public_send("#{key}_notional_usd"),
      leverage: key == "extended" ? extended_leverage : nil,
      effective_leverage: key == "extended" ? extended_effective_leverage : ethereal_effective_leverage,
      margin_mode: key == "extended" ? extended_margin_mode : nil,
      source_status: public_send("#{key}_source_status").presence || "unknown",
      stale_as_of: key == "extended" && extended_source_status == "stale" ? extended_value_stale_as_of : refreshed_at,
      source: "PositionDashboardSnapshot ##{id}",
      critical_read_status: key == "extended" ? extended_critical_read_status : nil,
      optional_read_status: key == "extended" ? extended_optional_read_status : nil
    }
  end

  def decimal_string(value)
    value&.to_s("F")
  end
end
