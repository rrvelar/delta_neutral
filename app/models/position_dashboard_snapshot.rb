class PositionDashboardSnapshot < ApplicationRecord
  DEFAULT_STALE_AFTER_SECONDS = 120
  STATUSES = %w[ok partial error unknown].freeze
  VENUE_STATUSES = %w[active flat unknown error].freeze

  belongs_to :position

  validates :refresh_status, inclusion: { in: STATUSES }

  def stale_now?
    stale_at?(Time.current)
  end

  def stale_at?(time)
    stale? || refreshed_at.nil? || refreshed_at < (time - stale_after_seconds.seconds)
  end

  def source_errors_hash
    return {} if source_errors.blank?

    JSON.parse(source_errors)
  rescue JSON::ParserError
    {}
  end

  def migration_complete_for_proof?
    missing_migration_fields.empty?
  end

  def migration_critical_fields_present?
    migration_complete_for_proof?
  end

  def missing_migration_fields
    missing = []
    missing << "production_venue" if production_venue.blank?
    missing << "target_short_eth" unless positive_decimal?(target_short_eth)
    missing << "combined_short_eth" unless decimal_present?(combined_short_eth)
    missing << "drift_eth" unless decimal_present?(drift_eth)
    missing << "inside_tolerance" if inside_tolerance.nil?
    missing << "extended_short_eth" unless decimal_present?(extended_short_eth)
    missing << "ethereal_short_eth" unless decimal_present?(ethereal_short_eth)
    missing << "nado_short_eth" unless decimal_present?(nado_short_eth)
    missing
  end

  # True when the Extended venue's live readback failed and only a stale, carried-forward
  # value remains. The carried-forward value is diagnostic context, never confirmed exposure.
  def extended_exposure_carried_forward?
    extended_source_status.to_s == "stale" || extended_critical_read_status.to_s == "error_carried_forward"
  end

  def venue_state(venue)
    key = venue.to_s
    carried_forward = key == "extended" && extended_exposure_carried_forward?
    {
      venue: key,
      venue_name: HedgeVenues.label(key),
      short_size: public_send("#{key}_short_eth"),
      short_size_eth: decimal_string(public_send("#{key}_short_eth")),
      status: public_send("#{key}_status").presence || "unknown",
      carried_forward_exposure: carried_forward,
      carried_forward_short_eth: carried_forward ? extended_carried_forward_short_eth : nil,
      carried_forward_short_eth_display: carried_forward ? decimal_string(extended_carried_forward_short_eth) : nil,
      notional_usd: public_send("#{key}_notional_usd"),
      leverage: key == "extended" ? extended_leverage : nil,
      effective_leverage: key == "extended" ? extended_effective_leverage : ethereal_effective_leverage,
      margin_mode: key == "extended" ? extended_margin_mode : nil,
      entry_price: key == "extended" ? extended_entry_price : nil,
      mark_price: key == "extended" ? extended_mark_price : nil,
      unrealized_pnl_usd: key == "extended" ? extended_unrealized_pnl_usd : nil,
      realized_pnl_usd: key == "extended" ? extended_realized_pnl_usd : nil,
      open_orders_count: key == "extended" ? open_orders_count_extended : nil,
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

  def decimal_present?(value)
    return false if value.nil?

    BigDecimal(value.to_s)
    true
  rescue ArgumentError
    false
  end

  def positive_decimal?(value)
    decimal_present?(value) && BigDecimal(value.to_s).positive?
  rescue ArgumentError
    false
  end

  def stale_after_seconds
    ENV.fetch("POSITION_DASHBOARD_SNAPSHOT_STALE_AFTER_SECONDS", DEFAULT_STALE_AFTER_SECONDS).to_i
  rescue ArgumentError
    DEFAULT_STALE_AFTER_SECONDS
  end
end
