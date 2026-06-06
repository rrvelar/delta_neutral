class AutoRebalanceControl
  Result = Data.define(:ok, :errors, :settings, :payload)

  def initialize(position:, venue: nil, updated_by: nil)
    @position = position
    @venue = HedgeVenues.normalize(venue.presence || position.hedge&.execution_venue)
    @updated_by = updated_by
  end

  def status
    selected_key = OperationalSettings.auto_key_for(venue)
    states = OperationalSettings::AUTO_KEYS_BY_VENUE.to_h do |venue_key, key|
      setting = OperationalSettings.get(key)
      [ venue_key, { key: key, enabled: setting.enabled, source: setting.source, raw_value: setting.raw_value } ]
    end
    migration_states = OperationalSettings::MIGRATION_KEYS.to_h do |key|
      setting = OperationalSettings.get(key)
      [ key, { enabled: setting.enabled, source: setting.source, raw_value: setting.raw_value } ]
    end
    blockers = enable_blockers
    {
      position_id: position.id,
      active: position.active?,
      hedge_active: position.hedge&.active? || false,
      selected_venue: venue,
      selected_venue_name: HedgeVenues.label(venue),
      selected_auto_key: selected_key,
      selected_auto_enabled: states.dig(venue, :enabled) || false,
      selected_auto_source: states.dig(venue, :source),
      selected_live_enabled: live_enabled?,
      signer_ok: signer_ok?,
      inside_tolerance: inside_tolerance?,
      blockers: blockers,
      enable_confirmation: selected_key ? OperationalSettings.enable_confirmation_for(venue) : nil,
      disable_confirmation: selected_key ? OperationalSettings.disable_confirmation_for(venue) : nil,
      auto_states: states,
      migration_states: migration_states,
      orders_submitted: 0,
      signatures_created: 0,
      cancels_submitted: 0
    }
  end

  def set!(enabled:, confirmation:)
    enabled = ActiveModel::Type::Boolean.new.cast(enabled)
    return result(false, [ "selected venue must be ethereal, nado, or extended" ]) unless OperationalSettings.auto_key_for(venue)

    expected = enabled ? OperationalSettings.enable_confirmation_for(venue) : OperationalSettings.disable_confirmation_for(venue)
    return result(false, [ "confirmation must equal #{expected}" ]) unless confirmation.to_s == expected

    blockers = enabled ? enable_blockers : disable_blockers
    return result(false, blockers) if blockers.present?

    applied = []
    ActiveRecord::Base.transaction do
      OperationalSettings::AUTO_KEYS_BY_VENUE.each do |venue_key, key|
        desired = enabled && venue_key == venue
        applied << OperationalSettings.set!(
          key: key,
          enabled: desired,
          updated_by: updated_by,
          reason: "dashboard #{enabled ? 'enable' : 'disable'} #{HedgeVenues.label(venue)} auto"
        )
      end
      OperationalSettings::MIGRATION_KEYS.each do |key|
        applied << OperationalSettings.set!(
          key: key,
          enabled: false,
          updated_by: updated_by,
          reason: "dashboard keeps migration/random disabled while changing active venue auto"
        )
      end
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, errors, applied.select(&:ok).map(&:setting))
  end

  def enable_current_without_confirmation!(reason: "dashboard random rotation active venue auto")
    ActiveVenueAutoPolicy.new(position: position, updated_by: updated_by).enable_current!(reason: reason)
  end

  def disable_all!(confirmation:)
    return result(false, [ "confirmation must equal #{OperationalSettings::DISABLE_ALL_CONFIRMATION}" ]) unless confirmation.to_s == OperationalSettings::DISABLE_ALL_CONFIRMATION

    applied = []
    ActiveRecord::Base.transaction do
      OperationalSettings::RUNTIME_GATE_KEYS.each do |key|
        applied << OperationalSettings.set!(
          key: key,
          enabled: false,
          updated_by: updated_by,
          reason: "dashboard disable all auto loops"
        )
      end
    end
    errors = applied.flat_map(&:errors).uniq
    result(errors.empty?, errors, applied.select(&:ok).map(&:setting))
  end

  private

  attr_reader :position, :venue, :updated_by

  def result(ok, errors, settings = [])
    Result.new(ok, errors, settings, status.merge(settings: settings.map { |setting| { key: setting.key, value: setting.value } }))
  end

  def enable_blockers
    blockers = []
    blockers << "position must be active production position" unless position.active?
    blockers << "active hedge is required" unless position.hedge&.active?
    blockers << "selected venue must be ethereal, nado, or extended" unless OperationalSettings.auto_key_for(venue)
    blockers << "hedge execution venue must be #{HedgeVenues.label(venue)}" unless HedgeVenues.normalize(position.hedge&.execution_venue) == venue
    blockers << "#{HedgeVenues.label(venue)} live must be enabled before auto can be enabled" unless live_enabled?
    blockers << "signer status must be OK before auto can be enabled" unless signer_ok?
    blockers.concat(other_venue_exposure_blockers)
    blockers << "MIGRATION_AUTO_ENABLED must be false before continuous auto" if OperationalSettings.enabled?("MIGRATION_AUTO_ENABLED")
    blockers << "MIGRATION_RANDOM_ROTATION_LIVE_ENABLED must be false before continuous auto" if OperationalSettings.enabled?("MIGRATION_RANDOM_ROTATION_LIVE_ENABLED")
    blockers.uniq
  end

  def disable_blockers
    []
  end

  def live_enabled?
    HedgeVenues.build(venue).live_enabled?
  end

  def signer_ok?
    status = position.position_dashboard_snapshot&.signer_status.to_s
    status.blank? || status == "ok"
  end

  def inside_tolerance?
    position.position_dashboard_snapshot&.inside_tolerance
  end

  def other_venue_exposure_blockers
    snapshot = position.position_dashboard_snapshot
    return [] unless snapshot

    %w[extended ethereal nado].filter_map do |venue_key|
      next if venue_key == venue
      next unless decimal(snapshot.public_send("#{venue_key}_short_eth")).positive?

      "#{HedgeVenues.label(venue_key)} must be flat before enabling #{HedgeVenues.label(venue)} auto"
    end
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end
end
