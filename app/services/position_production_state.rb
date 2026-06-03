class PositionProductionState
  ARCHIVE_CONFIRMATION = "I_UNDERSTAND_THIS_ARCHIVES_DUPLICATE_POSITIONS".freeze
  EXPOSURE_EPSILON = BigDecimal("0.001")

  def initialize(position)
    @position = position
  end

  def activate!
    ActiveRecord::Base.transaction do
      Rails.logger.info("PositionProductionState activate position_id=#{position.id} user_id=#{position.user_id} old_active=#{position.active?} reason=explicit_operator_activation")
      sibling_scope.update_all(active: false, updated_at: Time.current)
      position.update!(active: true)
      hedge = ensure_hedge
      hedge.update!(
        active: true,
        execution_venue: supported_execution_venue(hedge.execution_venue)
      )
    end
    position
  end

  def archive!
    blockers = archive_blockers
    return [ false, blockers ] if blockers.present?

    ActiveRecord::Base.transaction do
      Rails.logger.info("PositionProductionState archive position_id=#{position.id} user_id=#{position.user_id} old_active=#{position.active?} reason=explicit_operator_archive")
      position.update!(active: false)
      position.hedge&.update!(active: false)
    end
    [ true, [] ]
  end

  def archive_blockers
    blockers = []
    blockers << "active hedge exposure exists; archive is blocked until venue shorts are flat" if active_hedge_exposure?
    blockers << "pending ShortRebalance exists" if pending_rebalance?
    blockers << "pending migration may exist; refresh/read route readiness before archiving" if pending_migration?
    blockers << "active auto loop must be disabled before archiving" if active_auto_loop?
    blockers.uniq
  end

  def active_hedge_exposure?
    snapshot = position.position_dashboard_snapshot
    return false unless snapshot

    %w[extended ethereal nado].any? do |venue|
      decimal(snapshot.public_send("#{venue}_short_eth")) > EXPOSURE_EPSILON
    end
  end

  def pending_rebalance?
    position.hedge&.short_rebalances&.where(status: ShortRebalance::STATUS_PENDING)&.exists? || false
  end

  def pending_migration?
    false
  end

  def active_auto_loop?
    venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    case venue
    when "nado"
      bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED")
    when "ethereal"
      bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED")
    when "extended"
      bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")
    else
      false
    end
  end

  def self.duplicates(scope = Position.all)
    scope
      .where.not(external_id: [ nil, "" ])
      .includes(:hedge)
      .group_by { |position| duplicate_key(position) }
      .values
      .select { |positions| positions.size > 1 }
      .map { |positions| duplicate_group(positions) }
  end

  def self.archive_duplicates!(scope = Position.all)
    duplicates(scope).flat_map do |group|
      group.fetch(:duplicates).filter_map do |position|
        next if position.active?

        state = new(position)
        ok, blockers = state.archive!
        { id: position.id, archived: ok, blockers: blockers }
      end
    end
  end

  def self.duplicate_key(position)
    [
      position.user_id,
      position.wallet_id,
      position.external_id.to_s,
      position.pool_address.to_s.downcase
    ]
  end

  def self.duplicate_group(positions)
    ordered = positions.sort_by { |position| [ position.active? ? 1 : 0, position.updated_at || Time.zone.at(0), position.id ] }
    canonical = ordered.last
    {
      key: duplicate_key(canonical),
      canonical: canonical,
      duplicates: ordered - [ canonical ]
    }
  end

  private

  attr_reader :position

  def sibling_scope
    Position.where(user_id: position.user_id).where.not(id: position.id)
  end

  def ensure_hedge
    position.hedge || position.create_hedge!(
      target: BigDecimal("1.0"),
      tolerance: BigDecimal("0.03"),
      active: true,
      execution_venue: RiskSettings.default_hedge_venue
    )
  end

  def supported_execution_venue(value)
    HedgeVenues.supported?(value) ? HedgeVenues.normalize(value) : RiskSettings.default_hedge_venue
  end

  def bool_env(key)
    return OperationalSettings.enabled?(key) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(ENV[key])
  end

  def decimal(value)
    BigDecimal(value.to_s)
  rescue ArgumentError, TypeError
    BigDecimal("0")
  end
end
