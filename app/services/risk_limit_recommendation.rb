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
    unless confirmation_valid?(confirmation, required_confirmation)
      return Result.new(false, [ "confirmation must equal #{required_confirmation}" ], [], recommendation)
    end

    applied = []
    errors = []
    ActiveRecord::Base.transaction do
      required.each do |change|
        result = RiskSettings.set!(
          key: change.fetch(:key),
          value: change.fetch(:recommended_value),
          updated_by: updated_by,
          reason: reason.presence || "apply recommended risk limits for position ##{position.id}",
          confirmation: confirmation,
          allow_mixed_recommendation_confirmation: true
        )
        if result.ok
          applied << { key: result.setting.key, value: result.setting.value, audit_id: result.audit.id }
        else
          errors.concat(result.errors)
          raise ActiveRecord::Rollback
        end
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
      global_max_short_change,
      change_for("AERODROME_MAX_SHORT_NOTIONAL_USD", recommended_notional_cap)
    ].compact
  end

  def emergency_close_change
    change_for("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH", final_effective_max_short_eth)
  end

  def change_for(key, recommended)
    return unless recommended&.positive?

    current = RiskSettings.get(key)
    required = change_required?(key: key, current: current, recommended: recommended)
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

  def global_max_short_change
    current = RiskSettings.get("AERODROME_MAX_SHORT_ETH")
    recommended = final_global_max_short_eth
    return unless recommended&.positive?

    change_for("AERODROME_MAX_SHORT_ETH", recommended).merge(
      reason: global_max_short_reason(current, recommended)
    )
  end

  def change_required?(key:, current:, recommended:)
    return true if current.value.blank?
    return true if current.value < recommended
    return true if runtime_dependency_invalid?(key, current.value)
    return true if key == "AERODROME_MAX_SHORT_ETH" && current.value > recommended && emergency_close_dependency_blocked?(current.value, recommended)

    false
  end

  def runtime_dependency_invalid?(key, value)
    RiskSettings.hard_ceiling_validation_errors(key, value.to_s).present?
  end

  def emergency_close_dependency_blocked?(current_global_max, recommended)
    emergency = RiskSettings.get("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
    hard_emergency = RiskSettings.get("AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH")
    return true if emergency.value.blank?
    return true if emergency.value < current_global_max && current_global_max > recommended
    return true if hard_emergency.value.present? && current_global_max > hard_emergency.value

    false
  end

  def global_max_short_reason(current, recommended)
    hard = RiskSettings.get("AERODROME_PRODUCTION_HARD_MAX_SHORT_ETH")
    hard_emergency = RiskSettings.get("AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH")
    if current.value.present? && hard.value.present? && current.value > hard.value
      "Current global max short #{current.value.to_s('F')} ETH exceeds production hard max #{hard.value.to_s('F')} ETH and forces emergency close above allowed ceiling. Lowering to #{recommended.to_s('F')} ETH clears the dependency for Position ##{position.id}."
    elsif current.value.present? && hard_emergency.value.present? && current.value > hard_emergency.value
      "Current global max short #{current.value.to_s('F')} ETH exceeds production hard emergency close max #{hard_emergency.value.to_s('F')} ETH. Lowering to #{recommended.to_s('F')} ETH clears the emergency close dependency."
    elsif current.value.present? && current.value > recommended
      "Current global max short #{current.value.to_s('F')} ETH is higher than needed for Position ##{position.id} and causes the emergency close dependency. Lowering to #{recommended.to_s('F')} ETH clears the blocker."
    else
      reason_for("AERODROME_MAX_SHORT_ETH", recommended, current)
    end
  end

  def reason_for(key, recommended, current)
    if key == "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH"
      "Emergency close must be at least the final effective max short cap."
    elsif RiskSettings.hard_key?(key)
      "Production hard ceiling must be at least #{recommended.to_s('F')} #{RiskSettings.unit_for(key)} for position ##{position.id}."
    elsif current.value.blank?
      "Runtime cap is missing for position ##{position.id}."
    else
      "Runtime cap is below position ##{position.id} requirement."
    end
  end

  def confirmation_required
    return RiskSettings::HARD_INCREASE_CONFIRMATION if hard_changes.any? { |change| change.fetch(:required) && increase_change?(change) }

    RiskSettings::INCREASE_CONFIRMATION
  end

  def confirmation_valid?(confirmation, required_confirmation)
    confirmation.to_s == required_confirmation ||
      (required_confirmation == RiskSettings::INCREASE_CONFIRMATION && confirmation.to_s == RiskSettings::HARD_INCREASE_CONFIRMATION)
  end

  def increase_change?(change)
    current = RiskSettings.decimal(change.fetch(:current_value))
    recommended = RiskSettings.decimal(change.fetch(:recommended_value))
    current.nil? || (recommended && recommended > current)
  end

  def recommended_eth_cap
    return nil unless target_short_eth

    ceil_one_decimal(target_short_eth * BUFFER_MULTIPLIER)
  end

  def final_global_max_short_eth
    return nil unless recommended_eth_cap

    current = RiskSettings.get("AERODROME_MAX_SHORT_ETH")
    return recommended_eth_cap if current.value.blank?
    return recommended_eth_cap if runtime_dependency_invalid?("AERODROME_MAX_SHORT_ETH", current.value)
    return recommended_eth_cap if current.value > recommended_eth_cap && emergency_close_dependency_blocked?(current.value, recommended_eth_cap)

    [ current.value, recommended_eth_cap ].max
  end

  def final_effective_max_short_eth
    [ final_global_max_short_eth, recommended_eth_cap ].compact.max
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
