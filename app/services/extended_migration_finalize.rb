class ExtendedMigrationFinalize
  Result = Data.define(:status, :blockers, :warnings, :receipt)
  CONFIRMATION = "I_UNDERSTAND_THIS_SWITCHES_PRODUCTION_HEDGE_TO_EXTENDED".freeze

  def initialize(env: ENV, extended_venue: HedgeVenues::Extended.new(env: env), nado_venue: HedgeVenues::Nado.new(env: env),
                 ethereal_service: EtherealHedgeExecutionService.new(env: env), now: -> { Time.current })
    @env = env
    @extended_venue = extended_venue
    @nado_venue = nado_venue
    @ethereal_service = ethereal_service
    @now = now
  end

  def run(position:, dry_run: true, confirmation: nil)
    state = read_state(position)
    blockers = readiness_blockers(position: position, state: state, dry_run: dry_run, confirmation: confirmation)
    if dry_run || blockers.any?
      return result(status: dry_run ? "dry_run" : "blocked_before_finalize", position: position, state: state, blockers: blockers, dry_run: dry_run)
    end

    position.hedge.update!(execution_venue: "extended")
    result(status: "success", position: position.reload, state: state, blockers: [], dry_run: false)
  end

  private

  def read_state(position)
    extended_position = @extended_venue.read_position(symbol: "ETH")
    ethereal_position = @ethereal_service.read_position
    nado_position = @nado_venue.read_position(symbol: "ETH")
    {
      target_short: target_short(position),
      tolerance: tolerance(position),
      extended_position: extended_position,
      ethereal_position: ethereal_position,
      nado_position: nado_position,
      extended_short: short_size(extended_position),
      ethereal_short: short_size(ethereal_position),
      nado_short: short_size(nado_position),
      extended_account_state: @extended_venue.account_state
    }
  end

  def readiness_blockers(position:, state:, dry_run:, confirmation:)
    blockers = []
    blockers << "position hedge execution_venue must still be ethereal before finalize" unless position.hedge&.execution_venue == "ethereal"
    blockers << "EXTENDED_MIGRATION_FINALIZE_ENABLED must be true" unless dry_run || bool_env("EXTENDED_MIGRATION_FINALIZE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless dry_run || confirmation == CONFIRMATION
    blockers << "Extended short must be within hedge tolerance of target before finalize" unless matches?(state[:extended_short], state[:target_short], state[:tolerance])
    blockers << "Ethereal short must be flat before finalize" unless state[:ethereal_short].zero?
    blockers << "Nado short must be flat before finalize" unless state[:nado_short].zero?
    blockers << "Extended open_orders_count must be 0 before finalize" unless state.dig(:extended_account_state, :open_orders_count).to_i.zero?
    blockers.concat(Array(state.dig(:extended_account_state, :margin_gate, :blockers)))
    blockers.uniq
  end

  def result(status:, position:, state:, blockers:, dry_run:)
    receipt = {
      venue: "extended",
      action: "migration_finalize",
      dry_run: dry_run,
      position_id: position.id,
      hedge_id: position.hedge&.id,
      timestamp: @now.call.utc.iso8601,
      target_short_eth: decimal_string(state[:target_short]),
      extended_short_eth: decimal_string(state[:extended_short]),
      ethereal_short_eth: decimal_string(state[:ethereal_short]),
      nado_short_eth: decimal_string(state[:nado_short]),
      selected_hedge_venue: position.hedge&.execution_venue,
      final_status: status,
      execution_venue_changed: status == "success",
      orders_placed: 0,
      signatures_created: 0,
      submitted: false,
      blockers: blockers,
      warnings: [ "Finalize only switches the production hedge venue after readback confirms Extended target and Ethereal flat." ]
    }
    Result.new(status, blockers, receipt[:warnings], receipt)
  end

  def matches?(actual, expected, tolerance)
    return false unless actual && expected && tolerance

    (actual - expected).abs <= tolerance
  end

  def target_short(position)
    valuation = PositionValuation.current(position)
    valuation.weth_exposure && position.hedge ? valuation.weth_exposure * position.hedge.target : nil
  end

  def tolerance(position)
    target = target_short(position)
    target && position.hedge ? target * position.hedge.tolerance : nil
  end

  def short_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?

    size = BigDecimal(position.fetch(:size, 0).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, KeyError
    BigDecimal("0")
  end

  def decimal_string(value)
    value&.to_s("F")
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(@env[key])
  end
end
