require "timeout"

# Manages the current user's DeFi positions.
#
# All queries are scoped to {Current.user} to prevent cross-user data access.
class PositionsController < ApplicationController
  # GET /positions
  #
  # Lists all active positions for the current user, eager-loading the
  # associated DEX and hedge records.
  #
  # @return [void]
  def index
    @positions = Current.user.positions.active.includes(:dex, :hedge, wallet: :network)
  end

  def new
    @aerodrome_import_defaults = aerodrome_import_defaults
  end

  def create
    attrs = aerodrome_position_params
    token_id = attrs[:external_id].to_s.strip
    @aerodrome_import_defaults = aerodrome_import_defaults.merge(attrs.to_h.symbolize_keys)

    if token_id.blank?
      flash.now[:alert] = "Token ID is required."
      return render :new, status: :unprocessable_entity
    end

    dex = Dex.find(attrs[:dex_id])
    if Position.active.where(dex: dex, external_id: token_id).exists?
      flash.now[:alert] = "An active Aerodrome position with token ID #{token_id} already exists."
      return render :new, status: :unprocessable_entity
    end

    position = nil
    hedge = nil
    ActiveRecord::Base.transaction do
      if ActiveModel::Type::Boolean.new.cast(attrs[:deactivate_existing_aerodrome_positions])
        Position.active.where(dex: dex).update_all(active: false, updated_at: Time.current)
      end

      position = Position.create!(
        user_id: attrs[:user_id],
        wallet_id: attrs[:wallet_id],
        dex: dex,
        source: Position::SOURCE_AERODROME_DIRECT,
        external_id: token_id,
        pool_address: attrs[:pool_address],
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: BigDecimal("0"),
        asset1_amount: BigDecimal("0"),
        asset0_price_usd: nil,
        asset1_price_usd: nil,
        active: true
      )
      hedge = position.create_hedge!(
        target: attrs[:hedge_target],
        tolerance: attrs[:hedge_tolerance],
        active: true
      )
    end

    sync_warning = nil
    begin
      PositionSyncJob.perform_now(position.id)
    rescue => e
      Rails.logger.warn("Aerodrome import sync failed for position #{position.id}: #{e.class} #{e.message}")
      sync_warning = " Position was created with hedge ##{hedge.id}, but read-only sync failed: #{e.message}"
    end

    redirect_to position_path(position), notice: "Aerodrome LP position imported.#{sync_warning}"
  rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound, ArgumentError => e
    flash.now[:alert] = "Import failed: #{e.message}"
    render :new, status: :unprocessable_entity
  end

  # GET /positions/:id
  #
  # Displays a single position along with its most recent 50 P&L snapshots
  # and full rebalance history.
  #
  # @return [void]
  def show
    @position = Current.user.positions.includes(:dex, :hedge, wallet: :network).find(params[:id])
    @position_valuation = PositionValuation.current(@position)
    @pnl_snapshots = @position.pnl_snapshots.order(captured_at: :desc).limit(10)
    @rebalances = @position.hedge&.short_rebalances&.order(rebalanced_at: :desc) || ShortRebalance.none
    if @position.dex.name == "aerodrome_slipstream"
      @selected_hedge_venue = HedgeVenues.normalize(params[:hedge_venue].presence || @position.hedge&.execution_venue)
      @hedge_venue_options = HedgeVenues.options
      @selected_hedge_venue_adapter = HedgeVenues.build(@selected_hedge_venue)
      @cached_hedge_dashboard_snapshot = cached_hedge_dashboard_snapshot
      @selected_hedge_venue_dashboard = lightweight_selected_hedge_venue_dashboard
      @hedge_venue_accounting = unavailable_hedge_accounting("Hedge accounting diagnostics are loaded separately.")
      @latest_aerodrome_weth_rebalance = safe_dashboard_section("latest_rebalance", fallback: nil) { @position.hedge&.short_rebalances&.where(asset: [ "ETH", "WETH" ])&.order(rebalanced_at: :desc)&.first }
      @aerodrome_hedge_proposals = safe_dashboard_section("hedge_proposals", fallback: []) { @position.aerodrome_hedge_proposals.latest_first.limit(10) }
      @latest_aerodrome_hedge_proposal = @aerodrome_hedge_proposals.first
      @aerodrome_proposal_safety_results = safe_dashboard_section("proposal_safety", fallback: {}) do
        safety = AerodromeHedgeProposalSafety.new
        @aerodrome_hedge_proposals.to_h { |proposal| [ proposal.id, safety.evaluate(proposal, current_position: @position) ] }
      end
      @aerodrome_rewards_report = unavailable_rewards_report("Rewards diagnostics are not loaded during initial dashboard render.")
      @aerodrome_fees_report = unavailable_fees_report("Fee diagnostics are not loaded during initial dashboard render.")
      @aerodrome_production_dashboard_status = unavailable_production_dashboard_status
      @aerodrome_rebalance_history_status = safe_dashboard_section("rebalance_history_status", fallback: {}) do
        AerodromeRebalanceHistoryStatus.new(
          position: @position,
          dashboard_status: @aerodrome_production_dashboard_status
        ).report
      end
      @aerodrome_auto_rebalance_status = lightweight_auto_rebalance_status
    end
  end

  def extended_diagnostics
    load_aerodrome_position_for_diagnostics
    render json: safe_dashboard_section("extended_diagnostics", timeout_seconds: diagnostic_timeout_seconds, fallback: unavailable_extended_auto_readiness) {
      ExtendedAutoReadiness.new.report(position: @position)
    }
  end

  def hedge_accounting_diagnostics
    load_aerodrome_position_for_diagnostics
    render json: safe_dashboard_section("hedge_accounting_diagnostics", timeout_seconds: diagnostic_timeout_seconds, fallback: unavailable_hedge_accounting) {
      selected_dashboard = selected_hedge_venue_dashboard
      @selected_hedge_venue_dashboard = selected_dashboard
      hedge_venue_accounting
    }
  end

  def rewards_fees_diagnostics
    load_aerodrome_position_for_diagnostics
    rewards = safe_dashboard_section("aerodrome_rewards_diagnostics", timeout_seconds: diagnostic_timeout_seconds, fallback: unavailable_rewards_report("rewards diagnostics timed out")) { aerodrome_rewards_report }
    fees = safe_dashboard_section("aerodrome_fees_diagnostics", timeout_seconds: diagnostic_timeout_seconds, fallback: unavailable_fees_report("fees diagnostics timed out")) { aerodrome_fees_report }
    render json: { rewards: rewards, fees: fees }
  end

  def production_diagnostics
    load_aerodrome_position_for_diagnostics
    render json: safe_dashboard_section("production_diagnostics", timeout_seconds: diagnostic_timeout_seconds, fallback: unavailable_production_dashboard_status) {
      AerodromeProductionDashboardStatus.new(
        position: @position,
        hedge_venue_adapter: @selected_hedge_venue_adapter
      ).report
    }
  end

  # POST /positions/:id/sync_now
  #
  # Enqueues a {PositionSyncJob} for the given position and redirects back
  # to the position detail page.
  #
  # @return [void]
  def sync_now
    @position = Current.user.positions.find(params[:id])
    PositionSyncJob.perform_later(@position.id)
    redirect_to position_path(@position), notice: "Position sync queued."
  end

  def hedge_open_preview
    run_dashboard_hedge_action("open", execute: false)
  end

  def hedge_open
    run_dashboard_hedge_action("open", execute: true)
  end

  def hedge_rebalance_preview
    run_dashboard_hedge_action("rebalance", execute: false)
  end

  def hedge_rebalance
    run_dashboard_hedge_action("rebalance", execute: true)
  end

  def hedge_close_preview
    run_dashboard_hedge_action("close", execute: false)
  end

  def hedge_close
    run_dashboard_hedge_action("close", execute: true)
  end

  def hedge_venue
    position = Current.user.positions.includes(:hedge).find(params[:id])
    hedge = position.hedge
    return redirect_to position_path(position), alert: "Create an active hedge before selecting a venue." unless hedge

    venue = HedgeVenues.normalize(params[:hedge_venue])
    hedge.update!(execution_venue: venue)
    redirect_to position_path(position, hedge_venue: venue), notice: "Hedge venue set to #{HedgeVenues.label(venue)}."
  end

  private

  def load_aerodrome_position_for_diagnostics
    @position = Current.user.positions.includes(:dex, :hedge, wallet: :network).find(params[:id])
    @position_valuation = PositionValuation.current(@position)
    @selected_hedge_venue = HedgeVenues.normalize(params[:hedge_venue].presence || @position.hedge&.execution_venue)
    @selected_hedge_venue_adapter = HedgeVenues.build(@selected_hedge_venue)
  end

  def run_dashboard_hedge_action(action, execute:)
    position = Current.user.positions.includes(:dex, :hedge).find(params[:id])
    report = AerodromeDashboardHedgeAction.new(
      position: position,
      action: action,
      execute: execute,
      confirmation: params[:dashboard_hedge_confirmation],
      venue: params[:hedge_venue].presence || position.hedge&.execution_venue
    ).report
    level = report.fetch(:status) == "blocked" || report.fetch(:status) == "failed" ? :alert : :notice
    redirect_params = report.fetch(:hedge_venue) == HedgeVenues::DEFAULT ? {} : { hedge_venue: report.fetch(:hedge_venue) }
    redirect_to position_path(position, redirect_params), flash: { level => dashboard_hedge_action_message(report) }
  end

  def dashboard_hedge_action_message(report)
    label = report.fetch(:requested_action).to_s.humanize
    venue = report.fetch(:hedge_venue_name)
    if report.fetch(:blockers).present?
      "#{label} #{report.fetch(:status)} on #{venue}: #{report.fetch(:blockers).join('; ')}"
    elsif report.fetch(:errors).present?
      "#{label} #{report.fetch(:status)} on #{venue}: #{report.fetch(:errors).join('; ')}"
    else
      delta = report[:submitted_delta_eth].presence || "0"
      message = "#{label} #{report.fetch(:status)} on #{venue}. Target #{report[:target_short_eth] || 'unavailable'} ETH, delta #{delta} ETH."
      report.fetch(:warnings).present? ? "#{message} #{report.fetch(:warnings).join('; ')}" : message
    end
  end

  def selected_hedge_venue_dashboard
    return nil if @selected_hedge_venue == HedgeVenues::DEFAULT

    current_position = @selected_hedge_venue_adapter.read_position(symbol: "ETH")
    current_short = selected_venue_short_size(current_position)
    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    drift = target ? target - current_short : nil
    tolerance = target && @position.hedge ? target * @position.hedge.tolerance : nil

    {
      target_hedge_eth: target&.to_s("F"),
      current_venue_position: current_position,
      current_short_eth: current_short.to_s("F"),
      drift_eth: drift&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      next_action: selected_venue_next_action(target: target, current_short: current_short, drift: drift, tolerance: tolerance),
      account_state: safe_dashboard_section("selected_venue_account_state", fallback: unavailable_account_state) { @selected_hedge_venue_adapter.account_state },
      open_preview: target ? @selected_hedge_venue_adapter.open_short_preview(symbol: "ETH", size_eth: target, max_slippage: ENV.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01")) : nil,
      close_preview: current_short.positive? ? @selected_hedge_venue_adapter.close_preview(symbol: "ETH", size_eth: current_short) : nil,
      live_preflight: target ? safe_dashboard_section("selected_venue_live_preflight", fallback: unavailable_preflight) { selected_venue_live_preflight(target: target, current_short: current_short, drift: drift, current_position: current_position) } : nil,
      action_live_preflights: safe_dashboard_section("selected_venue_action_preflights", fallback: unavailable_action_preflights) { selected_venue_action_live_preflights(target: target, current_short: current_short, drift: drift, current_position: current_position) },
      migration_full_readiness: @selected_hedge_venue == "extended" ? safe_dashboard_section("extended_migration_full_readiness", fallback: unavailable_migration_full_readiness) { extended_migration_full_readiness(target: target, extended_short: current_short) } : nil,
      auto_readiness: @selected_hedge_venue == "extended" ? safe_dashboard_section("extended_auto_readiness", fallback: unavailable_extended_auto_readiness) { ExtendedAutoReadiness.new.report(position: @position) } : nil
    }
  rescue => e
    { warnings: [ "#{@selected_hedge_venue_adapter.venue_name} dashboard preview unavailable: #{e.class}: #{e.message}" ] }
  end

  def lightweight_selected_hedge_venue_dashboard
    return nil if @selected_hedge_venue == HedgeVenues::DEFAULT

    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size) || cached_selected_venue_short_size
    drift = target && current_short ? target - current_short : nil
    tolerance = target && @position.hedge ? target * @position.hedge.tolerance : nil

    {
      target_hedge_eth: target&.to_s("F"),
      current_venue_position: cached_selected_venue_position(current_short, @selected_hedge_venue),
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      next_action: selected_venue_next_action(target: target, current_short: current_short || BigDecimal("0"), drift: drift, tolerance: tolerance),
      account_state: unavailable_account_state("Venue account diagnostics are loaded separately."),
      open_preview: nil,
      close_preview: nil,
      live_preflight: unavailable_preflight("Live preflight is loaded separately."),
      action_live_preflights: unavailable_action_preflights("Live preflight is loaded separately."),
      migration_full_readiness: @selected_hedge_venue == "extended" ? unavailable_migration_full_readiness : nil,
      auto_readiness: @selected_hedge_venue == "extended" ? unavailable_extended_auto_readiness : nil,
      warnings: [ "Initial dashboard uses cached hedge values; refresh diagnostics for live venue readback." ]
    }
  end

  def cached_selected_venue_short_size
    rebalance = latest_successful_selected_venue_rebalance
    return BigDecimal(rebalance.new_short_size.to_s) if rebalance&.new_short_size

    nil
  rescue ArgumentError
    nil
  end

  def latest_successful_selected_venue_rebalance
    @latest_successful_selected_venue_rebalance ||= @position.hedge&.short_rebalances&.
      where(venue: @selected_hedge_venue, asset: [ nil, "ETH", "WETH" ], status: ShortRebalance::STATUS_SUCCESS)&.
      order(rebalanced_at: :desc)&.
      first
  end

  def cached_selected_venue_position(current_short, venue_key = @selected_hedge_venue)
    return nil unless current_short

    {
      venue: HedgeVenues.label(venue_key),
      symbol: "ETH",
      side: current_short.positive? ? "short" : nil,
      short_size: current_short.to_s("F"),
      size: current_short.positive? ? "-#{current_short.to_s('F')}" : "0",
      status: "cached_from_rebalance_history",
      stale: true
    }
  end

  def cached_hedge_dashboard_snapshot
    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    tolerance = target && @position.hedge ? target * @position.hedge.tolerance : nil
    venue_states = %w[extended ethereal nado].to_h { |venue| [ venue.to_sym, cached_venue_state(venue) ] }
    selected = venue_states[@selected_hedge_venue&.to_sym] || cached_venue_state(@selected_hedge_venue)
    selected_short = selected[:short_size]
    drift = target && selected_short ? target - selected_short : nil
    inside_tolerance = drift && tolerance ? drift.abs <= tolerance : nil
    {
      production_venue: @position.hedge&.execution_venue,
      production_venue_name: HedgeVenues.label(@position.hedge&.execution_venue),
      selected_venue: selected,
      venue_states: venue_states,
      target_short_eth: target&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      inside_tolerance: inside_tolerance,
      hedge_status: hedge_status_label(inside_tolerance),
      combined_short_eth: combined_short(venue_states)&.to_s("F"),
      auto_status: cached_auto_status,
      signer_status: cached_signer_status,
      latest_rebalance: latest_venue_rebalance(@selected_hedge_venue),
      migration_status: cached_migration_status(venue_states)
    }
  end

  def cached_venue_state(venue)
    latest = latest_venue_rebalance(venue)
    success = latest_successful_venue_rebalance(venue)
    short = parse_decimal(success&.new_short_size)
    {
      venue: venue,
      venue_name: HedgeVenues.label(venue),
      short_size: short,
      short_size_eth: short&.to_s("F"),
      status: cached_venue_position_status(short, success),
      notional_usd: nil,
      leverage: nil,
      latest_status: latest&.status,
      latest_message: latest&.message,
      stale_as_of: success&.rebalanced_at || success&.updated_at,
      latest_rebalance_at: latest&.rebalanced_at || latest&.updated_at,
      source: success ? "ShortRebalance ##{success.id}" : "unavailable"
    }
  end

  def latest_venue_rebalance(venue)
    return nil unless @position.hedge && venue.present?

    @latest_venue_rebalances ||= {}
    @latest_venue_rebalances[venue] ||= @position.hedge.short_rebalances
      .where(venue: venue, asset: [ nil, "ETH", "WETH" ])
      .order(rebalanced_at: :desc, id: :desc)
      .first
  end

  def latest_successful_venue_rebalance(venue)
    return nil unless @position.hedge && venue.present?

    @latest_successful_venue_rebalances ||= {}
    @latest_successful_venue_rebalances[venue] ||= @position.hedge.short_rebalances
      .where(venue: venue, asset: [ nil, "ETH", "WETH" ], status: ShortRebalance::STATUS_SUCCESS)
      .order(rebalanced_at: :desc, id: :desc)
      .first
  end

  def cached_venue_position_status(short, success)
    return "unknown" unless success
    return "flat" if short.nil? || short.zero?

    "short"
  end

  def combined_short(venue_states)
    shorts = venue_states.values.filter_map { |state| state[:short_size] }
    return nil if shorts.empty?

    shorts.sum(BigDecimal("0"))
  end

  def hedge_status_label(inside_tolerance)
    return "Unknown / diagnostics unavailable" if inside_tolerance.nil?

    inside_tolerance ? "In tolerance" : "Out of tolerance"
  end

  def cached_auto_status
    enabled = case @position.hedge&.execution_venue
    when "extended" then ActiveModel::Type::Boolean.new.cast(ENV["EXTENDED_AUTO_REBALANCE_ENABLED"])
    when "ethereal" then ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"])
    when "nado" then ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_NADO_AUTO_REBALANCE_ENABLED"])
    else ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_HEDGE_ENABLED"]) && !ActiveModel::Type::Boolean.new.cast(ENV["AERODROME_HEDGE_PAUSED"])
    end
    { enabled: enabled, label: enabled ? "Auto Active" : "Auto Off" }
  end

  def cached_signer_status
    return { label: "Unknown", ok: nil, source: "not cached" } unless @position.hedge&.extended_execution?

    receipt = latest_jsonl_receipt("storage/extended_auto_rebalance_checks/*.jsonl", "storage/extended_mainnet_live_checks/*.jsonl", "storage/extended_migration_checks/*.jsonl")
    health = receipt&.dig("signer_health") || receipt&.dig("readiness_gates", "signer_health")
    ok = health&.fetch("ok", nil)
    {
      label: ok.nil? ? "Unknown" : (ok ? "OK" : "Down"),
      ok: ok,
      source: receipt ? "latest Extended receipt" : "not cached",
      stale_as_of: receipt&.dig("created_at") || receipt&.dig("timestamp")
    }
  end

  def cached_migration_status(venue_states)
    return { label: "Not active", complete: false } unless @position.hedge&.extended_execution?

    ethereal_flat = venue_states.dig(:ethereal, :status) == "flat"
    nado_flat = venue_states.dig(:nado, :status) == "flat"
    if ethereal_flat && nado_flat
      { label: "Migration complete: production venue Extended.", complete: true, ethereal_flat: true, nado_flat: true }
    else
      { label: "Migration status needs diagnostics.", complete: false, ethereal_flat: ethereal_flat, nado_flat: nado_flat }
    end
  end

  def latest_jsonl_receipt(*patterns)
    files = patterns.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }.sort
    path = files.last
    return nil unless path && File.file?(path)

    line = File.readlines(path).reverse.find(&:present?)
    line ? JSON.parse(line) : nil
  rescue JSON::ParserError, SystemCallError
    nil
  end

  def parse_decimal(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def hedge_venue_accounting
    return nil if @selected_hedge_venue == HedgeVenues::DEFAULT

    current_position = @selected_hedge_venue_dashboard&.dig(:current_venue_position)
    account_state = @selected_hedge_venue_dashboard&.dig(:account_state)
    HedgeVenueAccounting.new(
      position: @position,
      venue_key: @selected_hedge_venue,
      adapter: @selected_hedge_venue_adapter,
      current_position: current_position,
      account_state: account_state
    ).report
  end

  def selected_venue_short_size(position)
    return BigDecimal("0") unless position
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?

    size = BigDecimal(position.fetch(:size).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, KeyError
    BigDecimal("0")
  end

  def selected_venue_next_action(target:, current_short:, drift:, tolerance:)
    return "unavailable" unless target && drift && tolerance
    return "close" if target.zero? && current_short.positive?
    return "open" if current_short.zero? && target.positive? && target > tolerance
    return "increase short" if drift > tolerance
    return "reduce short" if drift < -tolerance

    "no-op"
  end

  def selected_venue_live_preflight(target:, current_short:, drift:, current_position:)
    action = selected_venue_next_action(target: target, current_short: current_short, drift: drift, tolerance: target && @position.hedge ? target * @position.hedge.tolerance : nil)
    mapped_action = action == "increase short" || action == "reduce short" ? "rebalance" : action
    mapped_action = "open" unless %w[open rebalance close].include?(mapped_action)
    selected_venue_action_live_preflight(action: mapped_action, target: target, current_short: current_short, drift: drift, current_position: current_position)
  end

  def selected_venue_action_live_preflights(target:, current_short:, drift:, current_position:)
    {
      open: selected_venue_action_live_preflight(action: "open", target: target, current_short: current_short, drift: drift, current_position: current_position),
      rebalance: selected_venue_action_live_preflight(action: "rebalance", target: target, current_short: current_short, drift: drift, current_position: current_position),
      close: selected_venue_action_live_preflight(action: "close", target: target, current_short: current_short, drift: drift, current_position: current_position)
    }
  end

  def selected_venue_action_live_preflight(action:, target:, current_short:, drift:, current_position:)
    max_slippage = ENV.fetch("AERODROME_DASHBOARD_HEDGE_MAX_SLIPPAGE", "0.01")
    if @selected_hedge_venue == "nado"
      return NadoHedgeExecutionService.new(venue: @selected_hedge_venue_adapter).preflight(
        position: @position,
        action: action,
        size_eth: selected_venue_action_size(action: action, target: target, current_short: current_short, drift: drift),
        current_position: current_position,
        confirmation: nil,
        max_slippage: max_slippage
      )
    end

    if @selected_hedge_venue == "ethereal"
      return EtherealHedgeExecutionService.new(venue: @selected_hedge_venue_adapter).preflight(
        position: @position,
        action: action,
        size_eth: selected_venue_action_size(action: action, target: target, current_short: current_short, drift: drift),
        current_position: current_position,
        confirmation: nil,
        max_slippage: max_slippage
      )
    end

    if @selected_hedge_venue == "extended"
      return ExtendedHedgeExecutionService.new(venue: @selected_hedge_venue_adapter).preflight(
        position: @position,
        action: action,
        size_eth: selected_venue_action_size(action: action, target: target, current_short: current_short, drift: drift),
        current_position: current_position,
        confirmation: nil,
        max_slippage: max_slippage
      )
    end

    @selected_hedge_venue_adapter.single_venue_preflight(
      position: @position,
      action: action,
      target_size_eth: selected_venue_action_size(action: action, target: target, current_short: current_short, drift: drift),
      current_position: current_position,
      confirmation: nil,
      max_slippage: max_slippage
    )
  end

  def selected_venue_action_size(action:, target:, current_short:, drift:)
    case action
    when "open"
      target || BigDecimal("0")
    when "rebalance"
      drift || BigDecimal("0")
    when "close"
      current_short || BigDecimal("0")
    else
      BigDecimal("0")
    end
  end

  def extended_migration_full_readiness(target:, extended_short:)
    ethereal_position = EtherealHedgeExecutionService.new.read_position
    ethereal_short = selected_venue_short_size(ethereal_position)
    {
      ethereal_short_eth: ethereal_short.to_s("F"),
      extended_short_eth: extended_short.to_s("F"),
      target_short_eth: target&.to_s("F"),
      expected_extended_short_after: target&.to_s("F"),
      expected_ethereal_short_after: "0",
      expected_combined_short_after: target&.to_s("F"),
      sequence: "extended_first",
      warning: "Extended-first temporarily overhedges until Ethereal close confirms."
    }
  rescue => e
    {
      status: "unavailable",
      warning: "Fast migration readiness unavailable: #{e.class}: #{e.message}"
    }
  end

  def aerodrome_rewards_report
    unless ENV["AERODROME_REWARDS_ENABLED"].to_s.downcase == "true"
      return {
        status: "not configured",
        gauge_status: "not configured",
        claimable_aero: nil,
        claimable_aero_usd: nil,
        depositor_address: nil,
        depositor_source: nil,
        gauge_address: nil,
        token_id: @position.external_id,
        strategy_level_estimate: @position.mellow_autopilot?,
        reward_label: @position.mellow_autopilot? ? "Mellow pro-rata AERO rewards estimate" : "Claimable AERO",
        claimable_by_app: false,
        aero_usd_price: nil,
        aero_usd_price_source: "unavailable",
        value_state: "unavailable",
        stop_reason: "AERODROME_REWARDS_ENABLED is not true",
        warnings: [ "AERODROME_REWARDS_ENABLED is not true" ]
      }
    end

    AerodromeRewardsCheck.new(position: @position).report
  rescue => e
    Rails.logger.warn("Aerodrome rewards dashboard read failed for position #{@position.id}: #{e.class} #{e.message}")
    {
      status: "unavailable",
      gauge_status: "unavailable",
      claimable_aero: nil,
      claimable_aero_usd: nil,
      depositor_address: nil,
      depositor_source: nil,
      gauge_address: nil,
      token_id: @position.external_id,
      aero_usd_price: nil,
      aero_usd_price_source: "unavailable",
      value_state: "unavailable",
      stop_reason: e.message,
      warnings: [ e.message ]
    }
  end

  def aerodrome_fees_report
    unless ENV["AERODROME_FEES_ENABLED"].to_s.downcase == "true"
      return {
        status: "not configured",
        fee_source: "not configured",
        fee0_symbol: nil,
        fee0_amount: nil,
        fee0_usd: nil,
        fee1_symbol: nil,
        fee1_amount: nil,
        fee1_usd: nil,
        total_fees_usd: nil,
        token_id: @position.external_id,
        strategy_level_estimate: @position.mellow_autopilot?,
        fee_label: @position.mellow_autopilot? ? "Mellow pro-rata LP fee estimate" : "Unclaimed fees USD estimate",
        collect_enabled_by_app: false,
        value_state: "unavailable",
        stop_reason: "AERODROME_FEES_ENABLED is not true",
        warnings: [ "AERODROME_FEES_ENABLED is not true" ]
      }
    end

    AerodromeFeesCheck.new(position: @position).report
  rescue => e
    Rails.logger.warn("Aerodrome fees dashboard read failed for position #{@position.id}: #{e.class} #{e.message}")
    {
      status: "unavailable",
      fee_source: "unavailable",
      fee0_symbol: nil,
      fee0_amount: nil,
      fee0_usd: nil,
      fee1_symbol: nil,
      fee1_amount: nil,
      fee1_usd: nil,
      total_fees_usd: nil,
      value_state: "unavailable",
      stop_reason: e.message,
      warnings: [ e.message ]
    }
  end

  def safe_dashboard_section(name, timeout_seconds: dashboard_section_timeout_seconds, fallback:)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Timeout.timeout(timeout_seconds) { yield }.tap do
      log_dashboard_section_duration(name, started)
    end
  rescue Timeout::Error
    log_dashboard_section_duration(name, started, timed_out: true)
    fallback_with_warning(fallback, "#{name} timed out after #{timeout_seconds}s")
  rescue => e
    log_dashboard_section_duration(name, started, error: e)
    fallback_with_warning(fallback, "#{name} unavailable: #{e.class}: #{e.message}")
  end

  def dashboard_section_timeout_seconds
    BigDecimal(ENV.fetch("POSITIONS_DASHBOARD_SECTION_TIMEOUT_SECONDS", "0.25")).to_f
  rescue ArgumentError
    0.25
  end

  def diagnostic_timeout_seconds
    BigDecimal(ENV.fetch("POSITIONS_DASHBOARD_DIAGNOSTIC_TIMEOUT_SECONDS", "2.0")).to_f
  rescue ArgumentError
    2.0
  end

  def log_dashboard_section_duration(name, started, timed_out: false, error: nil)
    elapsed_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round(1)
    suffix = if timed_out
      " timed_out=true"
    elsif error
      " error=#{error.class}"
    else
      ""
    end
    Rails.logger.info("[PositionsController#show] section=#{name} duration_ms=#{elapsed_ms}#{suffix}")
  end

  def fallback_with_warning(fallback, warning)
    case fallback
    when Hash
      fallback.deep_dup.tap do |copy|
        copy[:status] ||= "unavailable"
        copy[:warnings] = Array(copy[:warnings]) + [ warning ]
        copy[:blockers] = Array(copy[:blockers]) + [ warning ] if copy.key?(:blockers)
      end
    else
      fallback
    end
  end

  def unavailable_venue_dashboard(reason = "Venue dashboard diagnostics unavailable; refresh diagnostics.")
    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    {
      target_hedge_eth: target&.to_s("F"),
      current_short_eth: nil,
      drift_eth: nil,
      tolerance_eth: target && @position.hedge ? (target * @position.hedge.tolerance).to_s("F") : nil,
      next_action: "unavailable",
      current_venue_position: nil,
      account_state: unavailable_account_state(reason),
      live_preflight: unavailable_preflight(reason),
      action_live_preflights: unavailable_action_preflights(reason),
      warnings: [ reason ]
    }
  end

  def unavailable_account_state(reason = "venue diagnostics unavailable")
    {
      status: "unavailable",
      read_only_diagnostics: { current_position_status: "unavailable" },
      open_orders_count: nil,
      margin_gate: { status: "unavailable", blockers: [ reason ] },
      blockers: [ reason ],
      warnings: [ reason ]
    }
  end

  def unavailable_preflight(reason = "live preflight unavailable; refresh diagnostics")
    { blockers: [ reason ], warnings: [ reason ] }
  end

  def unavailable_action_preflights(reason = "live preflight unavailable; refresh diagnostics")
    { open: unavailable_preflight(reason), rebalance: unavailable_preflight(reason), close: unavailable_preflight(reason) }
  end

  def unavailable_migration_full_readiness
    { status: "unavailable", warning: "Fast migration readiness unavailable; refresh diagnostics." }
  end

  def unavailable_extended_auto_readiness
    {
      status: "unavailable",
      continuous_auto_ready: false,
      planned_auto_action: "unavailable",
      planned_auto_order_size_eth: nil,
      auto_max_rebalance_size_eth: nil,
      partial_auto_rebalance: false,
      auto_can_act: false,
      ethereal_flat: nil,
      nado_flat: nil,
      signer_health: { ok: false, reason: "unavailable" },
      blockers: [ "Extended auto readiness unavailable; refresh diagnostics" ],
      warnings: [ "Extended auto readiness unavailable; refresh diagnostics" ]
    }
  end

  def unavailable_hedge_accounting(reason = "Hedge accounting unavailable; refresh diagnostics.")
    {
      status: "unavailable",
      components: {},
      net_venue_pnl_usd: nil,
      warnings: [ reason ]
    }
  end

  def unavailable_production_dashboard_status
    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size) || cached_selected_venue_short_size
    drift = target && current_short ? target - current_short : nil
    tolerance = target && @position.hedge ? target * @position.hedge.tolerance : nil
    {
      status: "unavailable",
      execution_venue: @selected_hedge_venue,
      target_hedge_eth: target&.to_s("F"),
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      rebalance_needed_now: drift && tolerance ? drift.abs > tolerance : false,
      warnings: [ "Production dashboard diagnostics unavailable; refresh diagnostics." ]
    }
  end

  def unavailable_auto_rebalance_status(reason = "auto-rebalance diagnostics unavailable")
    { status: "unavailable", blockers: [ reason ], warnings: [ reason ] }
  end

  def lightweight_auto_rebalance_status
    target = @position_valuation.weth_exposure && @position.hedge ? @position_valuation.weth_exposure * @position.hedge.target : nil
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size) || cached_selected_venue_short_size
    drift = target && current_short ? target - current_short : nil
    tolerance = target && @position.hedge ? target * @position.hedge.tolerance : nil
    {
      status: "cached",
      target_short_eth: target&.to_s("F"),
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      rebalance_needed: drift && tolerance ? drift.abs > tolerance : false,
      warnings: [ "Auto diagnostics are loaded separately." ]
    }
  end

  def unavailable_rewards_report(reason)
    {
      status: "unavailable",
      gauge_status: "unavailable",
      claimable_aero: nil,
      claimable_aero_usd: nil,
      token_id: @position.external_id,
      strategy_level_estimate: @position.mellow_autopilot?,
      reward_label: @position.mellow_autopilot? ? "Mellow pro-rata AERO rewards estimate" : "Claimable AERO",
      claimable_by_app: false,
      value_state: "unavailable",
      stop_reason: reason,
      warnings: [ reason ]
    }
  end

  def unavailable_fees_report(reason)
    {
      status: "unavailable",
      fee_source: "unavailable",
      total_fees_usd: nil,
      token_id: @position.external_id,
      strategy_level_estimate: @position.mellow_autopilot?,
      fee_label: @position.mellow_autopilot? ? "Mellow pro-rata LP fee estimate" : "Unclaimed fees USD estimate",
      collect_enabled_by_app: false,
      value_state: "unavailable",
      stop_reason: reason,
      warnings: [ reason ]
    }
  end

  def aerodrome_position_params
    params.require(:position).permit(
      :external_id,
      :pool_address,
      :dex_id,
      :user_id,
      :wallet_id,
      :hedge_target,
      :hedge_tolerance,
      :deactivate_existing_aerodrome_positions
    )
  end

  def aerodrome_import_defaults
    aerodrome_dex = Dex.find_or_create_by!(name: "aerodrome_slipstream")
    last_aerodrome = Position.where(dex: aerodrome_dex).order(created_at: :desc, id: :desc).first

    {
      external_id: "",
      pool_address: last_aerodrome&.pool_address,
      dex_id: aerodrome_dex.id,
      user_id: User.find_by(id: 1)&.id || Current.user.id,
      wallet_id: Wallet.find_by(id: 1)&.id || Current.user.wallets.order(:id).first&.id,
      hedge_target: "1.0",
      hedge_tolerance: "0.03",
      source: Position::SOURCE_AERODROME_DIRECT,
      deactivate_existing_aerodrome_positions: "1"
    }
  end
end
