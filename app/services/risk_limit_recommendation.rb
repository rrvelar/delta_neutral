class RiskLimitRecommendation
  BUFFER_MULTIPLIER = BigDecimal("1.25")

  Result = Data.define(:ok, :errors, :applied, :recommendation)

  def initialize(position:, venue: nil)
    @position = position
    @venue = HedgeVenues.normalize(venue.presence || position.hedge&.execution_venue || RiskSettings.default_hedge_venue)
  end

  def report
    {
      position_id: position.id,
      venue: venue,
      target_short_eth: target_short_eth&.to_s("F"),
      requested_size_eth: target_short_eth&.to_s("F"),
      estimated_notional_usd: estimated_notional_usd&.to_s("F"),
      runtime_caps: runtime_changes,
      hard_ceilings: hard_changes,
      emergency_close: emergency_close_change,
      required_changes: required_changes,
      hard_ceiling_raise_required: hard_changes.any? { |change| change.fetch(:required) },
      confirmation_required: confirmation_required,
      applyable: required_changes.present?,
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  def apply!(updated_by: nil, reason: nil, confirmation: nil)
    recommendation = report
    required = recommendation.fetch(:required_changes)
    return Result.new(true, [], [], recommendation) if required.empty?

    required_confirmation = recommendation.fetch(:confirmation_required)
    unless confirmation.to_s == required_confirmation
      return Result.new(false, [ "confirmation must equal #{required_confirmation}" ], [], recommendation)
    end

    applied = []
    errors = []
    required.each do |change|
      result = RiskSettings.set!(
        key: change.fetch(:key),
        value: change.fetch(:recommended_value),
        updated_by: updated_by,
        reason: reason.presence || "apply recommended risk limits for position ##{position.id}",
        confirmation: confirmation
      )
      if result.ok
        applied << { key: result.setting.key, value: result.setting.value, audit_id: result.audit.id }
      else
        errors.concat(result.errors)
      end
    end

    Result.new(errors.empty?, errors.uniq, applied, report)
  end

  private

  attr_reader :position, :venue

  def required_changes
    (hard_changes + runtime_changes + [ emergency_close_change ]).compact.select { |change| change.fetch(:required) }
  end

  def hard_changes
    [
      change_for("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH", recommended_eth_cap),
      change_for("AERODROME_PRODUCTION_HARD_MAX_ORDER_SIZE_ETH", recommended_eth_cap),
      change_for("AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH", recommended_eth_cap),
      change_for("AERODROME_PRODUCTION_HARD_MAX_NOTIONAL_USD", recommended_notional_cap),
      change_for("AERODROME_PRODUCTION_HARD_MAX_SHORT_NOTIONAL_USD", recommended_notional_cap)
    ].compact
  end

  def runtime_changes
    [
      change_for("#{venue.upcase}_MAX_SHORT_ETH", recommended_eth_cap),
      change_for("#{venue.upcase}_MAX_ORDER_SIZE_ETH", recommended_eth_cap),
      change_for("#{venue.upcase}_MAX_NOTIONAL_USD", recommended_notional_cap),
      change_for("AERODROME_MAX_SHORT_ETH", recommended_eth_cap),
      change_for("AERODROME_MAX_SHORT_NOTIONAL_USD", recommended_notional_cap)
    ].compact
  end

  def emergency_close_change
    change_for("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH", recommended_eth_cap)
  end

  def change_for(key, recommended)
    return unless recommended&.positive?

    current = RiskSettings.get(key)
    current_value = current.value
    required = current_value.blank? || current_value < recommended
    {
      key: key,
      label: RiskSettings.human_label(key),
      current_value: current.raw_value,
      current_source: current.source,
      recommended_value: recommended.to_s("F"),
      required: required,
      reason: reason_for(key, recommended, current)
    }
  end

  def reason_for(key, recommended, current)
    if key == "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      "Emergency close limit must be at least the maximum hedge size so the bot can close the position in an emergency."
    elsif RiskSettings.hard_key?(key)
      "Production hard ceiling must be at least #{recommended.to_s('F')} #{RiskSettings.unit_for(key)} for position ##{position.id}."
    elsif current.value.blank?
      "Runtime cap is missing for position ##{position.id}."
    else
      "Runtime cap is below position ##{position.id} requirement."
    end
  end

  def confirmation_required
    hard_changes.any? { |change| change.fetch(:required) } ? RiskSettings::HARD_INCREASE_CONFIRMATION : RiskSettings::INCREASE_CONFIRMATION
  end

  def recommended_eth_cap
    return nil unless target_short_eth

    ceil_one_decimal(target_short_eth * BUFFER_MULTIPLIER)
  end

  def recommended_notional_cap
    return nil unless estimated_notional_usd

    ceil_hundreds(estimated_notional_usd * BUFFER_MULTIPLIER)
  end

  def target_short_eth
    @target_short_eth ||= begin
      snapshot_target = position.position_dashboard_snapshot&.target_short_eth
      if snapshot_target.present?
        snapshot_target
      elsif position.asset0_amount && position.hedge&.target
        position.asset0_amount * position.hedge.target
      end
    end
  end

  def estimated_notional_usd
    return nil unless target_short_eth && position.asset0_price_usd

    target_short_eth * position.asset0_price_usd
  end

  def ceil_one_decimal(value)
    (value * 10).ceil / BigDecimal("10")
  end

  def ceil_hundreds(value)
    (value / 100).ceil * BigDecimal("100")
  end
end
