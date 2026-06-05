class ActiveVenueAutoPolicy
  Result = Data.define(:ok, :settings, :errors, :payload)

  def initialize(position:, updated_by: nil)
    @position = position
    @updated_by = updated_by
  end

  def enable_current!(reason: "active production venue auto policy")
    enable_venue!(venue: position.hedge&.execution_venue, reason: reason)
  end

  def enable_venue!(venue:, reason: "active production venue auto policy")
    venue = HedgeVenues.normalize(venue)
    return result(false, [], [ "selected venue must be ethereal, nado, or extended" ]) unless OperationalSettings.auto_key_for(venue)

    applied = []
    ActiveRecord::Base.transaction do
      OperationalSettings::AUTO_KEYS_BY_VENUE.each do |venue_key, key|
        applied << OperationalSettings.set!(
          key: key,
          enabled: venue_key == venue,
          updated_by: updated_by,
          reason: reason
        )
      end
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, applied.select(&:ok).map(&:setting), errors, venue: venue)
  end

  def disable_all!(reason: "active production venue auto paused during migration")
    applied = []
    ActiveRecord::Base.transaction do
      OperationalSettings::AUTO_KEYS_BY_VENUE.values.each do |key|
        applied << OperationalSettings.set!(
          key: key,
          enabled: false,
          updated_by: updated_by,
          reason: reason
        )
      end
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, applied.select(&:ok).map(&:setting), errors)
  end

  def self.active_auto_venue(env: ENV)
    enabled = OperationalSettings::AUTO_KEYS_BY_VENUE.keys.select do |venue|
      OperationalSettings.enabled?(OperationalSettings.auto_key_for(venue), env: env)
    end
    enabled.one? ? enabled.first : nil
  end

  private

  attr_reader :position, :updated_by

  def result(ok, settings, errors, extra = {})
    Result.new(
      ok,
      settings,
      errors,
      {
        position_id: position.id,
        active_auto_venue: self.class.active_auto_venue,
        auto_states: OperationalSettings::AUTO_KEYS_BY_VENUE.to_h do |venue, key|
          [ venue, OperationalSettings.enabled?(key) ]
        end,
        orders_submitted: 0,
        orders_placed: 0,
        signatures_created: 0,
        cancels_submitted: 0
      }.merge(extra)
    )
  end
end
