# Operator-controlled venue quarantine (2026-07-17: Extended submit endpoint
# returned HTTP 503 / Net::ReadTimeout during live legs). While a venue is
# quarantined:
#   - autonomous/random production must not OPEN new exposure on it (route
#     selection skips routes targeting it);
#   - the production runner refuses to start unless the enabled route subset
#     excludes the venue as a target and it is not the current production venue;
#   - recovery and migrate-out paths (which only CLOSE or move exposure off the
#     venue) are deliberately unaffected.
module HedgeVenueQuarantine
  KEYS = { "extended" => "EXTENDED_VENUE_QUARANTINED" }.freeze

  def self.quarantined?(venue, env: ENV)
    key = KEYS[HedgeVenues.normalize(venue)]
    return false unless key

    OperationalSettings.enabled?(key, env: env)
  end

  def self.quarantined_venues(env: ENV)
    KEYS.keys.select { |venue| quarantined?(venue, env: env) }
  end
end
