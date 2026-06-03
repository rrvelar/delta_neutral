class AerodromeDashboardHedgeAction
  CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_HYPERLIQUID_ORDERS"
  NADO_CONFIRMATION = "I_UNDERSTAND_THIS_SUBMITS_LIVE_NADO_ORDERS"
  ETHEREAL_CONFIRMATION = EtherealHedgeExecutionService::CONFIRMATION
  EXTENDED_CONFIRMATION = ExtendedMainnetLifecycleCheck::CONFIRMATION
  ACTIONS = %w[open rebalance close].freeze
  HEDGEABLE_SYMBOLS = %w[ETH WETH].freeze

  def initialize(position:, action:, execute: false, confirmation: nil, venue: HedgeVenues::DEFAULT, hyperliquid_service: nil, hedge_sync_runner: nil, emergency_close_factory: nil, nado_service_factory: nil, ethereal_service_factory: nil, log_dir: nil)
    @position = position
    @hedge = position.hedge
    @action = action.to_s
    @execute = execute
    @confirmation = confirmation.to_s
    @venue_key = HedgeVenues.normalize(venue)
    @hyperliquid_service = hyperliquid_service
    @hedge_sync_runner = hedge_sync_runner || ->(hedge_id) { HedgeSyncJob.perform_now(hedge_id) }
    @emergency_close_factory = emergency_close_factory || method(:default_emergency_close)
    @nado_service_factory = nado_service_factory
    @ethereal_service_factory = ethereal_service_factory
    @log_dir = log_dir || Rails.root.join("storage", "aerodrome_dashboard_hedge_actions")
    @warnings = []
  end

  def report
    return blocked([ "unsupported dashboard hedge action" ]) unless ACTIONS.include?(@action)

    append_informational_preview_warnings
    before_position = current_eth_position
    current_short = short_size(before_position)
    target = target_short
    drift = target ? target - current_short : nil
    blockers = action_blockers(target: target, current_short: current_short, drift: drift)
    blockers.concat(non_hyperliquid_live_blockers(target: target, drift: drift, current_short: current_short, before_position: before_position)) if @execute
    blockers.concat(execution_gate_blockers) if @execute
    result = blockers.any? ? blocked(blockers, target: target, current_short: current_short, drift: drift, before_position: before_position) : run_action(target: target, current_short: current_short, drift: drift, before_position: before_position)

    write_receipt(result)
    result
  rescue => e
    result = base_result(
      status: "failed",
      target: target_short,
      current_short: nil,
      drift: nil,
      before_position: nil,
      after_position: nil,
      blockers: [],
      errors: [ "#{e.class}: #{e.message}" ]
    )
    write_receipt(result)
    result
  end

  def self.execution_gate_blockers(action: nil, submitted_confirmation: nil, require_submitted_confirmation: false)
    blockers = []
    blockers << "AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED must be true" unless bool_env("AERODROME_DASHBOARD_HEDGE_EXECUTION_ENABLED")
    blockers << "AERODROME_DASHBOARD_HEDGE_CONFIRMATION must equal #{CONFIRMATION}" unless ENV["AERODROME_DASHBOARD_HEDGE_CONFIRMATION"].to_s == CONFIRMATION
    if require_submitted_confirmation && submitted_confirmation.to_s != submitted_confirmation_phrase(action)
      blockers << "submitted confirmation must equal #{submitted_confirmation_phrase(action)}"
    end
    blockers << "AERODROME_LIVE_APPROVED must be true" unless bool_env("AERODROME_LIVE_APPROVED")
    blockers << "AERODROME_HEDGE_ENABLED must be true" unless bool_env("AERODROME_HEDGE_ENABLED")
    blockers << "AERODROME_HEDGE_PAUSED must be false" if bool_env("AERODROME_HEDGE_PAUSED", default: true)
    blockers << "HYPERLIQUID_TESTNET must be false" if bool_env("HYPERLIQUID_TESTNET", default: true)
    blockers
  end

  def self.bool_env(key, default: false)
    ActiveModel::Type::Boolean.new.cast(ENV.fetch(key, default.to_s))
  end

  def self.submitted_confirmation_phrase(action)
    action.to_s == "close" ? AerodromeLiveEmergencyClose::CONFIRMATION : CONFIRMATION
  end

  private

  def run_action(target:, current_short:, drift:, before_position:)
    after_position = nil
    execution_result = nil

    if @execute
      execution_result = if @venue_key == "nado"
        run_nado_action(target: target, current_short: current_short, drift: drift, before_position: before_position)
      elsif @venue_key == "ethereal"
        run_ethereal_action(target: target, current_short: current_short, drift: drift, before_position: before_position)
      elsif @venue_key == "extended"
        run_extended_action(target: target, current_short: current_short, drift: drift, before_position: before_position)
      elsif @action == "close"
        run_emergency_close
      else
        @hedge_sync_runner.call(@hedge.id)
        { status: "submitted" }
      end
      after_position = current_eth_position
    end

    base_result(
      status: @execute ? execution_status(execution_result) : "preview",
      target: target,
      current_short: current_short,
      drift: drift,
      before_position: before_position,
      after_position: after_position,
      blockers: [],
      errors: [],
      execution_result: execution_result
    )
  end

  def blocked(blockers, target: nil, current_short: nil, drift: nil, before_position: nil)
    base_result(
      status: "blocked",
      target: target,
      current_short: current_short,
      drift: drift,
      before_position: before_position,
      after_position: nil,
      blockers: blockers.uniq,
      errors: []
    )
  end

  def base_result(status:, target:, current_short:, drift:, before_position:, after_position:, blockers:, errors:, execution_result: nil)
    {
      status: status,
      requested_action: @action,
      position_id: @position.id,
      hedge_id: @hedge&.id,
      dry_run: !@execute,
      database_write: false,
      orders_enabled: @execute && blockers.empty?,
      hyperliquid_execution: @venue_key == "hyperliquid" && @execute && blockers.empty?,
      live_order_capable: venue.live_supported?,
      hedge_venue: @venue_key,
      hedge_venue_name: venue.venue_name,
      hedge_venue_mode: venue.mode,
      hedge_venue_live_supported: venue.live_supported?,
      hedge_venue_live_enabled: venue.live_enabled?,
      hedge_venue_preview: venue_preview(target: target, drift: drift, current_short: current_short),
      hedge_venue_live_preflight: hedge_venue_live_preflight(target: target, drift: drift, current_short: current_short, before_position: before_position),
      hedge_venue_account_state: venue.account_state,
      cap_diagnostics: cap_diagnostics(target: target, current_short: current_short, drift: drift),
      target_short_eth: target&.to_s("F"),
      target_notional_usd: target && eth_price ? (target * eth_price).to_s("F") : nil,
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      drift_notional_usd: drift && eth_price ? (drift * eth_price).to_s("F") : nil,
      tolerance_eth: tolerance_eth(target)&.to_s("F"),
      submitted_delta_eth: submitted_delta(target: target, current_short: current_short, drift: drift)&.to_s("F"),
      current_position_before: serialize_position(before_position),
      readback_after: serialize_position(after_position),
      result: execution_result,
      blockers: blockers,
      warnings: @warnings,
      errors: errors,
      receipt_path: nil
    }
  end

  def action_blockers(target:, current_short:, drift:)
    blockers = base_blockers(target: target, current_short: current_short)
    return blockers if blockers.any?
    return [] if read_only_venue_preview?

    tolerance = tolerance_eth(target)
    case @action
    when "open"
      blockers << "current ETH short already exists; use rebalance or close" if current_short.positive?
      blockers << "target ETH short is zero" unless target&.positive?
      blockers << "target ETH short is within tolerance; open not needed" unless target && tolerance && target > tolerance
    when "rebalance"
      blockers << "drift is within hedge tolerance" unless drift && tolerance && drift.abs > tolerance
    when "close"
      blockers << "no current ETH short to close" unless current_short.positive?
    end
    blockers
  end

  def base_blockers(target:, current_short:)
    blockers = []
    blockers << "position must be Aerodrome Slipstream" unless @position.dex.name == "aerodrome_slipstream"
    blockers << "position is inactive" unless @position.active? || read_only_venue_preview?
    blockers << "active hedge is required" unless @hedge&.active? || read_only_venue_preview?
    blockers << Position::MULTIPLE_ACTIVE_HEDGEABLE_MESSAGE if @execute && Position.active_hedgeable.count > 1
    blockers << "Mellow Autopilot pro-rata exposure is not hedge-ready" if @position.mellow_autopilot? && !@position.hedge_ready?
    blockers << "WETH/ETH LP exposure is unavailable" unless weth_amount
    blockers << "WETH/ETH price is unavailable" unless eth_price
    global_short_cap = RiskSettings.get("AERODROME_MAX_SHORT_ETH")
    global_notional_cap = RiskSettings.get("AERODROME_MAX_SHORT_NOTIONAL_USD")
    blockers.concat(AerodromeProductionRiskLimits.runtime_cap_errors(
      max_short_eth: global_short_cap.value,
      max_short_notional_usd: global_notional_cap.value,
      emergency_close_max_eth: RiskSettings.get("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH").value
    ))
    blockers.concat(cap_blockers(target: target, current_short: current_short))
    blockers.uniq
  end

  def cap_blockers(target:, current_short:)
    diagnostics = cap_diagnostics(target: target, current_short: current_short, drift: target ? target - current_short : nil)
    blockers = []
    short_cap = diagnostics.fetch(:short_cap)
    order_cap = diagnostics.fetch(:order_cap)
    notional_cap = diagnostics.fetch(:notional_cap)

    blockers << "cap not configured for #{short_cap.fetch(:cap_key)}" if cap_checked? && short_cap.fetch(:cap_value).blank?
    blockers << "cap not configured for #{order_cap.fetch(:cap_key)}" if cap_checked? && order_cap.fetch(:cap_value).blank?
    blockers << "cap not configured for #{notional_cap.fetch(:cap_key)}" if cap_checked? && eth_price && notional_cap.fetch(:cap_value).blank?
    if short_cap.fetch(:cap_blocked)
      blockers << "Blocked by risk limit. Target hedge: #{short_cap.fetch(:target_short_eth)} ETH. Current venue short: #{short_cap.fetch(:current_short_eth)} ETH. Requested action: #{short_cap.fetch(:requested_size_eth)} ETH. Current cap: #{short_cap.fetch(:cap_key)} = #{short_cap.fetch(:cap_value)} ETH. Cap source: #{short_cap.fetch(:cap_source)}. Minimum required cap: #{short_cap.fetch(:minimum_required_cap)} ETH. Options: raise cap intentionally, reduce LP size, or choose another supported venue."
    end
    if notional_cap.fetch(:cap_blocked)
      blockers << "target hedge notional exceeds #{notional_cap.fetch(:cap_key)}: expected=#{notional_cap.fetch(:expected_after_notional_usd)} USD cap=#{notional_cap.fetch(:cap_value)} USD"
    end
    if order_cap.fetch(:cap_blocked)
      blockers << "requested order size exceeds #{order_cap.fetch(:cap_key)}: requested=#{order_cap.fetch(:requested_size_eth)} ETH cap=#{order_cap.fetch(:cap_value)} ETH"
    end
    blockers
  end

  def cap_checked?
    @action.in?(%w[open rebalance])
  end

  def read_only_venue_preview?
    !@execute && %w[ethereal nado extended].include?(@venue_key)
  end

  def append_informational_preview_warnings
    return unless read_only_venue_preview?

    @warnings << "Position is inactive; preview is informational only." unless @position.active?
    @warnings << "Active hedge is missing; preview is informational only." unless @hedge&.active?
  end

  def execution_gate_blockers
    return [] if @venue_key.in?(%w[nado ethereal extended])

    self.class.execution_gate_blockers(
      action: @action,
      submitted_confirmation: @confirmation,
      require_submitted_confirmation: @venue_key == "hyperliquid"
    )
  end

  def non_hyperliquid_live_blockers(target:, drift:, current_short:, before_position:)
    return [] if @venue_key == "hyperliquid"
    return nado_service.preflight(
      position: @position,
      action: @action,
      size_eth: nado_action_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ).fetch(:blockers) if @venue_key == "nado"

    return ethereal_service.preflight(
      position: @position,
      action: @action,
      size_eth: ethereal_action_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ).fetch(:blockers) if @venue_key == "ethereal"

    return extended_service.preflight(
      position: @position,
      action: @action,
      size_eth: preflight_target_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ).fetch(:blockers) if @venue_key == "extended"

    single_venue_preflight(target: target, drift: nil, current_short: current_short, before_position: before_position).fetch(:blockers).uniq
  end

  def run_emergency_close
    old_paused = ENV["AERODROME_HEDGE_PAUSED"]
    ENV["AERODROME_HEDGE_PAUSED"] = "true"
    @emergency_close_factory.call.report
  ensure
    old_paused.nil? ? ENV.delete("AERODROME_HEDGE_PAUSED") : ENV["AERODROME_HEDGE_PAUSED"] = old_paused
  end

  def run_nado_action(target:, current_short:, drift:, before_position:)
    size = preflight_target_size(target: target, drift: drift, current_short: current_short)
    result = if @action == "close"
      nado_service.close_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "open"
      nado_service.open_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "rebalance"
      nado_service.rebalance_short(position: @position, delta_eth: drift, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    else
      NadoHedgeExecutionService::Result.new("blocked_before_submit", [ "Nado live rebalance is not implemented; use open or close" ], [], {})
    end
    result.receipt
  end

  def run_ethereal_action(target:, current_short:, drift:, before_position:)
    size = preflight_target_size(target: target, drift: drift, current_short: current_short)
    result = if @action == "close"
      ethereal_service.close_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "open"
      ethereal_service.open_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "rebalance"
      ethereal_service.rebalance_short(position: @position, delta_eth: drift, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    else
      EtherealHedgeExecutionService::Result.new("blocked_before_submit", [ "unsupported Ethereal action" ], [], {})
    end
    result.receipt
  end

  def run_extended_action(target:, current_short:, drift:, before_position:)
    size = preflight_target_size(target: target, drift: drift, current_short: current_short)
    result = if @action == "close"
      extended_service.close_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "open"
      extended_service.open_short(position: @position, size_eth: size, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    elsif @action == "rebalance"
      extended_service.rebalance_short(position: @position, delta_eth: drift, current_position: before_position, confirmation: @confirmation, max_slippage: max_slippage)
    else
      ExtendedHedgeExecutionService::Result.new("blocked_before_submit", [ "unsupported Extended action" ], [], {})
    end
    result.receipt
  end

  def execution_status(execution_result)
    return "submitted" unless execution_result.is_a?(Hash)
    return "submitted" unless execution_result.key?(:final_status)

    case execution_result[:final_status].to_s
    when "submitted_and_confirmed", "submitted_but_readback_pending", "submitted_but_not_confirmed", "success"
      "submitted"
    when "blocked_before_submit"
      "blocked"
    else
      "failed"
    end
  end

  def default_emergency_close
    AerodromeLiveEmergencyClose.new(hyperliquid_service: hyperliquid)
  end

  def current_eth_position
    return nado_service.read_position if @venue_key == "nado"
    return ethereal_service.read_position if @venue_key == "ethereal"

    venue.read_position(symbol: "ETH")
  rescue => e
    @warnings << "current #{venue.venue_name} ETH readback unavailable: #{e.class}: #{e.message}"
    return :unavailable if @venue_key.in?(%w[nado ethereal])

    nil
  end

  def hyperliquid
    @hyperliquid_service ||= HyperliquidService.new(testnet: false)
  end

  def venue
    @venue ||= HedgeVenues.build(@venue_key, hyperliquid_service: @hyperliquid_service)
  end

  def venue_preview(target:, drift:, current_short:)
    return nil unless target && current_short

    case @action
    when "open"
      venue.open_short_preview(symbol: "ETH", size_eth: target, max_slippage: max_slippage)
    when "rebalance"
      venue.rebalance_preview(symbol: "ETH", delta_eth: drift || BigDecimal("0"), max_slippage: max_slippage)
    when "close"
      venue.close_preview(symbol: "ETH", size_eth: current_short)
    end
  end

  def hedge_venue_live_preflight(target:, drift:, current_short:, before_position:)
    return nil if @venue_key == "hyperliquid"
    return nil unless target && current_short

    return nado_service.preflight(
      position: @position,
      action: @action,
      size_eth: nado_action_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ) if @venue_key == "nado"

    return ethereal_service.preflight(
      position: @position,
      action: @action,
      size_eth: ethereal_action_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ) if @venue_key == "ethereal"

    return extended_service.preflight(
      position: @position,
      action: @action,
      size_eth: preflight_target_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    ) if @venue_key == "extended"

    single_venue_preflight(target: target, drift: drift, current_short: current_short, before_position: before_position)
  end

  def single_venue_preflight(target:, drift:, current_short:, before_position:)
    venue.single_venue_preflight(
      position: @position,
      action: @action,
      target_size_eth: preflight_target_size(target: target, drift: drift, current_short: current_short),
      current_position: before_position,
      confirmation: @confirmation,
      max_slippage: max_slippage
    )
  end

  def preflight_target_size(target:, drift:, current_short:)
    case @action
    when "open"
      target
    when "rebalance"
      (drift || target - current_short).abs
    when "close"
      current_short
    else
      BigDecimal("0")
    end
  end

  def cap_diagnostics(target:, current_short:, drift:)
    requested = preflight_target_size(target: target || BigDecimal("0"), drift: drift, current_short: current_short || BigDecimal("0"))
    expected_after = expected_after_short(target: target, current_short: current_short, drift: drift)
    short_cap = RiskSettings.cap_for(venue: @venue_key, kind: :short_eth)
    order_cap = RiskSettings.cap_for(venue: @venue_key, kind: :order_size_eth)
    notional_cap = RiskSettings.cap_for(venue: @venue_key, kind: :notional_usd)
    expected_notional = expected_after && eth_price ? expected_after * eth_price : nil
    {
      venue: @venue_key,
      action: @action,
      settings_path: Rails.application.routes.url_helpers.edit_settings_path(anchor: "risk-settings"),
      short_cap: cap_payload(short_cap, target: target, current_short: current_short, requested: requested, expected_after: expected_after),
      order_cap: order_cap_payload(order_cap, requested: requested),
      notional_cap: notional_cap_payload(notional_cap, expected_notional: expected_notional),
      emergency_close: emergency_close_payload
    }
  end

  def emergency_close_payload
    recommendation = RiskLimitRecommendation.new(position: @position, venue: @venue_key).report
    emergency = RiskSettings.get("AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH")
    compared = RiskSettings.get("AERODROME_MAX_SHORT_ETH")
    hard = RiskSettings.get("AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH")
    emergency_change = recommendation.fetch(:emergency_close)
    recommended_changes = recommendation.fetch(:required_changes).select do |change|
      [ "AERODROME_MAX_SHORT_ETH", "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH" ].include?(change.fetch(:key))
    end
    {
      emergency_close_key: "AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH",
      current_emergency_close: emergency.value&.to_s("F"),
      required_emergency_close: emergency_change&.fetch(:recommended_value),
      compared_against_key: "AERODROME_MAX_SHORT_ETH",
      compared_against_value: compared.value&.to_s("F"),
      hard_emergency_close_key: "AERODROME_PRODUCTION_HARD_EMERGENCY_CLOSE_MAX_ETH",
      hard_emergency_close_value: hard.value&.to_s("F"),
      blocker: emergency_change&.fetch(:required) || false,
      reason: emergency_change&.fetch(:reason),
      recommended_changes: recommended_changes
    }
  end

  def expected_after_short(target:, current_short:, drift:)
    return current_short unless cap_checked?
    return target if @action == "open"
    return current_short + drift if @action == "rebalance" && drift&.positive?

    current_short
  end

  def cap_payload(cap, target:, current_short:, requested:, expected_after:)
    cap_value = cap.value
    {
      selected_venue: @venue_key,
      action: @action,
      target_short_eth: target&.to_s("F"),
      current_short_eth: current_short&.to_s("F"),
      requested_size_eth: requested&.to_s("F"),
      expected_after_short_eth: expected_after&.to_s("F"),
      cap_key: cap.key,
      cap_value: cap_value&.to_s("F"),
      cap_source: cap.source,
      cap_blocked: cap_checked? && cap_value.present? && expected_after.present? && expected_after > cap_value,
      minimum_required_cap: expected_after&.to_s("F")
    }
  end

  def order_cap_payload(cap, requested:)
    cap_value = cap.value
    {
      cap_key: cap.key,
      cap_value: cap_value&.to_s("F"),
      cap_source: cap.source,
      requested_size_eth: requested&.to_s("F"),
      cap_blocked: cap_checked? && cap_value.present? && requested.present? && requested > cap_value
    }
  end

  def notional_cap_payload(cap, expected_notional:)
    cap_value = cap.value
    {
      cap_key: cap.key,
      cap_value: cap_value&.to_s("F"),
      cap_source: cap.source,
      expected_after_notional_usd: expected_notional&.to_s("F"),
      cap_blocked: cap_checked? && cap_value.present? && expected_notional.present? && expected_notional > cap_value
    }
  end

  def nado_action_size(target:, drift:, current_short:)
    return drift || BigDecimal("0") if @action == "rebalance"

    preflight_target_size(target: target, drift: drift, current_short: current_short)
  end

  def ethereal_action_size(target:, drift:, current_short:)
    return drift || BigDecimal("0") if @action == "rebalance"

    preflight_target_size(target: target, drift: drift, current_short: current_short)
  end

  def max_slippage
    ENV.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01")
  end

  def nado_service
    @nado_service ||= @nado_service_factory ? @nado_service_factory.call : NadoHedgeExecutionService.new(venue: venue)
  end

  def ethereal_service
    @ethereal_service ||= @ethereal_service_factory ? @ethereal_service_factory.call : EtherealHedgeExecutionService.new(venue: venue)
  end

  def extended_service
    @extended_service ||= ExtendedHedgeExecutionService.new(venue: venue)
  end

  def target_short
    return nil unless @hedge && weth_amount

    weth_amount * @hedge.target
  end

  def submitted_delta(target:, current_short:, drift:)
    return nil unless target && current_short

    case @action
    when "open", "rebalance"
      drift
    when "close"
      -current_short
    end
  end

  def tolerance_eth(target)
    return nil unless target && @hedge

    target * @hedge.tolerance
  end

  def weth_amount
    return @position.mellow_weth_exposure if @position.mellow_autopilot? && @position.mellow_weth_exposure

    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_amount
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_amount
    end
  end

  def eth_price
    if @position.mellow_autopilot? && @position.mellow_weth_exposure&.positive? && @position.mellow_current_value_usd
      usdc = @position.mellow_usdc_exposure || BigDecimal("0")
      return (@position.mellow_current_value_usd - usdc) / @position.mellow_weth_exposure
    end

    if HEDGEABLE_SYMBOLS.include?(@position.asset0.to_s.upcase)
      @position.asset0_price_usd
    elsif HEDGEABLE_SYMBOLS.include?(@position.asset1.to_s.upcase)
      @position.asset1_price_usd
    end
  end

  def short_size(position)
    return BigDecimal("0") unless position && position != :unavailable
    return position.short_size || BigDecimal("0") if position.respond_to?(:short_size)

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  end

  def serialize_position(position)
    return nil unless position && position != :unavailable
    return position.as_json if position.respond_to?(:as_json) && !position.is_a?(Hash)

    position.merge(size: BigDecimal(position.fetch(:size).to_s).to_s("F"))
  end

  def decimal_env(key)
    RiskSettings.get(key).value
  end

  def write_receipt(result)
    FileUtils.mkdir_p(@log_dir)
    path = @log_dir.join("#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    event = result.merge(
      event: "dashboard_hedge_action",
      timestamp: Time.current.iso8601,
      receipt_path: path.to_s
    )
    File.open(path, "a") { |file| file.puts(JSON.generate(event)) }
    result[:receipt_path] = path.to_s
  end
end
