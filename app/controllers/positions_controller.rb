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
    @visible_positions = DashboardVisiblePositions.new(user: Current.user).call.to_a
    @positions = Position
      .left_outer_joins(:wallet)
      .where("positions.user_id = :user_id OR wallets.user_id = :user_id", user_id: Current.user.id)
      .includes(
        :dex,
        :hedge,
        :position_dashboard_snapshot,
        wallet: :network
      )
      .distinct
      .order(active: :desc, updated_at: :desc, id: :desc)
      .to_a
    @duplicate_position_ids = duplicate_position_ids(@positions)
    Rails.logger.info(
      "PositionsController#index visible_positions user_id=#{Current.user.id} " \
      "email=#{Current.user.email_address} visible_count=#{@visible_positions.size} " \
      "visible_position_ids=#{@visible_positions.map(&:id).join(',')}"
    )
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
    user = Current.user
    wallet = Current.user.wallets.find(attrs[:wallet_id])
    position = nil
    hedge = nil
    duplicate = duplicate_aerodrome_position(user: user, wallet: wallet, dex: dex, external_id: token_id, pool_address: attrs[:pool_address])
    ActiveRecord::Base.transaction do
      if ActiveModel::Type::Boolean.new.cast(attrs[:deactivate_existing_aerodrome_positions])
        sibling_positions = Position.active.where(user: user)
        sibling_positions = sibling_positions.where.not(id: duplicate.id) if duplicate
        sibling_positions.update_all(active: false, updated_at: Time.current)
      end

      position = duplicate || Position.new(
        user: user,
        wallet: wallet,
        dex: dex,
        source: Position::SOURCE_AERODROME_DIRECT,
        external_id: token_id,
        asset0: "WETH",
        asset1: "USDC",
        asset0_amount: BigDecimal("0"),
        asset1_amount: BigDecimal("0")
      )
      position.assign_attributes(
        pool_address: attrs[:pool_address],
        active: true
      )
      position.save!
      hedge = position.hedge || position.build_hedge(
        target: attrs[:hedge_target],
        tolerance: attrs[:hedge_tolerance]
      )
      hedge.assign_attributes(
        target: attrs[:hedge_target],
        tolerance: attrs[:hedge_tolerance],
        active: true,
        execution_venue: supported_import_hedge_venue(hedge.execution_venue)
      )
      hedge.save!
    end

    sync_warning = nil
    begin
      PositionSyncJob.perform_now(position.id)
    rescue => e
      Rails.logger.warn("Aerodrome import sync failed for position #{position.id}: #{e.class} #{e.message}")
      sync_warning = " Position was created with hedge ##{hedge.id}, but read-only sync failed: #{e.message}"
    end
    DashboardSnapshotJob.perform_later(position.id, force: true)

    duplicate_message = duplicate ? " Existing position ##{position.id} was activated instead of creating a duplicate." : ""
    redirect_to position_path(position), notice: "Aerodrome LP position imported.#{duplicate_message}#{sync_warning}"
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
    @position = Current.user.positions.includes(
      :dex,
      :hedge,
      :position_dashboard_snapshot,
      :position_rewards_fees_snapshot,
      :position_hedge_accounting_snapshot,
      wallet: :network
    ).find(params[:id])
    @position_valuation = PositionValuation.current(@position)
    @pnl_snapshots = @position.pnl_snapshots.order(captured_at: :desc).limit(10)
    @rebalances = @position.hedge&.short_rebalances&.order(rebalanced_at: :desc) || ShortRebalance.none
    if @position.dex.name == "aerodrome_slipstream"
      @unsupported_legacy_hedge_venue = @position.hedge&.unsupported_legacy_execution_venue?
      @selected_hedge_venue = selected_supported_hedge_venue(@position)
      @hedge_venue_options = HedgeVenues.options
      @selected_hedge_venue_adapter = HedgeVenues.build(@selected_hedge_venue)
      @cached_hedge_dashboard_snapshot = cached_hedge_dashboard_snapshot
      @position_tab = selected_position_tab
      @risk_recommendation = RiskLimitRecommendation.new(position: @position, venue: @selected_hedge_venue).report
      @auto_control_status = AutoRebalanceControl.new(position: @position, venue: @selected_hedge_venue).status
      @current_auto_readiness = unavailable_extended_auto_readiness("Initial render uses cached dashboard snapshot; refresh diagnostics for venue readiness.")
      @current_extended_auto_readiness = @selected_hedge_venue == "extended" ? @current_auto_readiness : nil
      @selected_hedge_venue_dashboard = lightweight_selected_hedge_venue_dashboard
      @selected_hedge_venue_dashboard[:auto_readiness] = @current_extended_auto_readiness if @current_extended_auto_readiness
      @hedge_venue_accounting = cached_hedge_accounting_report || unavailable_hedge_accounting("Hedge accounting diagnostics are loaded separately.")
      @latest_aerodrome_weth_rebalance = safe_dashboard_section("latest_rebalance", fallback: nil) { @position.hedge&.short_rebalances&.where(asset: [ "ETH", "WETH" ])&.order(rebalanced_at: :desc)&.first }
      @aerodrome_hedge_proposals = safe_dashboard_section("hedge_proposals", fallback: []) { @position.aerodrome_hedge_proposals.latest_first.limit(10) }
      @latest_aerodrome_hedge_proposal = @aerodrome_hedge_proposals.first
      @aerodrome_proposal_safety_results = safe_dashboard_section("proposal_safety", fallback: {}) do
        safety = AerodromeHedgeProposalSafety.new
        @aerodrome_hedge_proposals.to_h { |proposal| [ proposal.id, safety.evaluate(proposal, current_position: @position) ] }
      end
      @aerodrome_rewards_report = cached_rewards_report || unavailable_rewards_report("Rewards/fees snapshot not refreshed yet.")
      @aerodrome_fees_report = cached_fees_report || unavailable_fees_report("Rewards/fees snapshot not refreshed yet.")
      @aerodrome_production_dashboard_status = unavailable_production_dashboard_status
      @latest_hedge_migration_receipt = latest_jsonl_receipt("storage/hedge_migration_checks/*.jsonl", "storage/extended_migration_checks/*.jsonl")
      @latest_daily_random_rotation_receipt = latest_jsonl_receipt_for_position(@position.id, "storage/hedge_migration_random_rotation_daily/*.jsonl")
      @random_rotation_virtual_state = MigrationRandomRotationVirtualState.new(position: @position).current
      @migration_control_plan = cached_migration_control_plan
      @migration_route_matrix = HedgeVenueMigrationRouteMatrix.new(position: @position).report
      @auto_migration_decision = HedgeVenueAutoMigrationPlanner.new(route_matrix: @migration_route_matrix).plan(position: @position).receipt
      @live_autopilot_readiness = MigrationLiveAutopilotReadiness.new(position: @position, route_matrix: @migration_route_matrix).report
      @production_health = auto_readiness_production_health(@current_auto_readiness)
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
    @position = Current.user.positions.includes(:dex).find(params[:id])
    PositionSyncJob.perform_later(@position.id)
    DashboardSnapshotJob.perform_later(@position.id, force: true) if @position.dex.name == "aerodrome_slipstream"
    redirect_to position_path(@position), notice: @position.dex.name == "aerodrome_slipstream" ? "Position sync and read-only dashboard snapshot refresh queued." : "Position sync queued."
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
    return redirect_to position_path(position), alert: "#{HedgeVenues.label(venue)} is an unsupported legacy venue." unless HedgeVenues.supported?(venue)

    hedge.update!(execution_venue: venue)
    path = venue == HedgeVenues.default_supported ? position_path(position) : position_path(position, hedge_venue: venue)
    redirect_to path, notice: "Hedge venue set to #{HedgeVenues.label(venue)}."
  end

  def activate
    position = Current.user.positions.includes(:hedge).find(params[:id])
    PositionProductionState.new(position).activate!
    DashboardSnapshotJob.perform_later(position.id, force: true) if position.dex.name == "aerodrome_slipstream"
    redirect_to position_path(position), notice: "Position ##{position.id} is now the active production position. No orders or signatures were created."
  end

  def archive
    position = Current.user.positions.includes(:hedge, :position_dashboard_snapshot).find(params[:id])
    ok, blockers = PositionProductionState.new(position).archive!
    if ok
      redirect_to positions_path, notice: "Position ##{position.id} archived and hedge deactivated. This did not close the on-chain LP or any perps."
    else
      redirect_to position_path(position), alert: "Archive blocked: #{blockers.join('; ')}"
    end
  end

  def auto_rebalance
    position = Current.user.positions.includes(:hedge, :position_dashboard_snapshot).find(params[:id])
    control = AutoRebalanceControl.new(position: position, venue: params[:venue] || params[:hedge_venue], updated_by: Current.user)
    result = control.set!(enabled: params[:enabled], confirmation: params[:auto_confirmation])
    redirect_params = {
      hedge_venue: control.status.fetch(:selected_venue),
      tab: "accounting"
    }
    if result.ok
      state = ActiveModel::Type::Boolean.new.cast(params[:enabled]) ? "enabled" : "disabled"
      redirect_to position_path(position, redirect_params), notice: "#{control.status.fetch(:selected_venue_name)} auto #{state}. No orders or signatures were created."
    else
      redirect_to position_path(position, redirect_params), alert: "Auto setting blocked: #{result.errors.join('; ')}"
    end
  end

  def migration_preview
    position = load_position_for_migration
    result = HedgeVenueMigrationPlanner.new.plan(
      position: position,
      from_venue: params[:from_venue],
      to_venue: params[:to_venue],
      mode: params[:migration_mode].presence || "preview",
      step_size_eth: params[:max_step_size_eth],
      full_migration_allowed: ActiveModel::Type::Boolean.new.cast(params[:full_migration_allowed]),
      migration_sequence: params[:migration_sequence]
    )
    write_migration_preview_receipt(result, position)
    level = result.blockers.present? ? :alert : :notice
    redirect_to position_path(position, migration_preview_query_params(position)),
      flash: { level => migration_result_message("Migration preview", result) }
  end

  def migration_run
    position = load_position_for_migration
    result = HedgeVenueMigrationExecutor.new.run(
      position: position,
      from_venue: params[:from_venue],
      to_venue: params[:to_venue],
      mode: params[:migration_mode].presence || "preview",
      dry_run: false,
      confirmation: params[:migration_confirmation],
      step_size_eth: params[:max_step_size_eth],
      full_migration_allowed: ActiveModel::Type::Boolean.new.cast(params[:full_migration_allowed]),
      migration_sequence: params[:migration_sequence]
    )
    level = result.status == "success" ? :notice : :alert
    redirect_to position_path(position, migration_preview_query_params(position)),
      flash: { level => migration_result_message("Manual migration", result) }
  end

  def migration_finalize
    position = load_position_for_migration
    redirect_to position_path(position, hedge_venue: position.hedge&.execution_venue),
      alert: "Dashboard finalize is fail-closed. Use the dedicated gated migration finalize task after read-only snapshot confirms readiness."
  end

  def migration_cancel
    position = load_position_for_migration
    redirect_to position_path(position, hedge_venue: position.hedge&.execution_venue),
      notice: "No active dashboard migration state was changed."
  end

  def migration_route_proof
    position = load_position_for_migration
    summary = HedgeVenueMigrationRouteMatrix.new(position: position).prove_routes!
    redirect_to position_path(position, hedge_venue: position.hedge&.execution_venue),
      notice: "Dry-run route proof wrote #{summary.fetch(:receipts_written)} receipt rows. No orders or signatures."
  end

  def migration_random_rotation_decision
    position = load_position_for_migration
    matrix = HedgeVenueMigrationRouteMatrix.new(position: position).report
    use_virtual_state = ActiveModel::Type::Boolean.new.cast(params[:use_virtual_state])
    state = use_virtual_state ? MigrationRandomRotationVirtualState.new(position: position).current : nil
    planner = HedgeVenueAutoMigrationPlanner.new(
      route_matrix: matrix,
      current_venue_override: state&.fetch(:virtual_current_venue, nil),
      virtual_mode: use_virtual_state
    )
    result = planner.plan(position: position)
    path = planner.write_receipt(result.receipt)
    redirect_to position_path(position, hedge_venue: position.hedge&.execution_venue),
      notice: "Random rotation decision recorded#{path ? " at #{path}" : ""}. No orders or signatures."
  end

  def hedge_emergency_restore
    position = load_position_for_migration
    live = ActiveModel::Type::Boolean.new.cast(params[:live])
    result = HedgeEmergencyRestore.new(
      position: position,
      dry_run: !live,
      live: live,
      confirmation: params[:hedge_emergency_restore_confirmation],
      explicit_position_id: params[:id].present?,
      action: params[:emergency_action].presence || "adjust"
    ).run
    level = result.blockers.present? || result.status.to_s.include?("MANUAL_ACTION") || result.status.to_s.include?("FAILED") ? :alert : :notice
    redirect_to position_path(position, hedge_venue: position.hedge&.execution_venue),
      flash: { level => hedge_emergency_restore_message(result.receipt) }
  end

  private

  def load_position_for_migration
    Current.user.positions.includes(:dex, :hedge, :position_dashboard_snapshot).find(params[:id])
  end

  def migration_result_message(label, result)
    receipt = result.receipt
    if result.blockers.present?
      "#{label} #{result.status}: #{result.blockers.join('; ')}"
    else
      "#{label} #{result.status}: #{HedgeVenues.label(receipt[:from_venue])} -> #{HedgeVenues.label(receipt[:to_venue])}, #{receipt[:planned_to_leg]&.dig(:size_eth) || '0'} ETH target leg, #{receipt[:planned_from_leg]&.dig(:size_eth) || '0'} ETH source leg."
    end
  end

  def hedge_emergency_restore_message(receipt)
    if receipt[:blockers].present?
      "Emergency restore #{receipt[:final_status]}: #{receipt[:blockers].join('; ')}"
    else
      "Emergency restore #{receipt[:final_status]}: target #{receipt[:target_short_eth]} ETH, order #{receipt[:rounded_size_eth] || receipt[:order_size_eth]} ETH, orders #{receipt[:orders_submitted]}."
    end
  end

  def load_aerodrome_position_for_diagnostics
    @position = Current.user.positions.includes(:dex, :hedge, wallet: :network).find(params[:id])
    @position_valuation = PositionValuation.current(@position)
    @selected_hedge_venue = selected_supported_hedge_venue(@position)
    @selected_hedge_venue_adapter = HedgeVenues.build(@selected_hedge_venue)
  end

  def run_dashboard_hedge_action(action, execute:)
    position = Current.user.positions.includes(:dex, :hedge).find(params[:id])
    report = AerodromeDashboardHedgeAction.new(
      position: position,
      action: action,
      execute: execute,
      confirmation: params[:dashboard_hedge_confirmation],
      venue: supported_action_venue(params[:hedge_venue].presence || position.hedge&.execution_venue)
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
      auto_readiness: @selected_hedge_venue == @position.hedge&.execution_venue ? safe_dashboard_section("hedge_venue_auto_readiness", fallback: unavailable_extended_auto_readiness) { HedgeVenueAutoReadiness.new.report(position: @position) } : nil
    }
  rescue => e
    { warnings: [ "#{@selected_hedge_venue_adapter.venue_name} dashboard preview unavailable: #{e.class}: #{e.message}" ] }
  end

  def lightweight_selected_hedge_venue_dashboard
    target = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:target_short_eth))
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size)
    drift = target && current_short ? target - current_short : nil
    tolerance = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:tolerance_eth))

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

  def cached_selected_venue_position(current_short, venue_key = @selected_hedge_venue)
    return nil unless current_short

    {
      venue: HedgeVenues.label(venue_key),
      symbol: "ETH",
      side: current_short.positive? ? "short" : nil,
      short_size: current_short.to_s("F"),
      size: current_short.positive? ? "-#{current_short.to_s('F')}" : "0",
      status: "snapshot",
      stale: true
    }
  end

  def cached_hedge_dashboard_snapshot
    snapshot = @position.position_dashboard_snapshot
    return missing_dashboard_snapshot if snapshot.nil?

    venue_states = %w[extended ethereal nado].to_h { |venue| [ venue.to_sym, snapshot_venue_state(snapshot, venue) ] }
    selected = venue_states[@selected_hedge_venue&.to_sym] || unknown_venue_state(@selected_hedge_venue)
    inside_tolerance = snapshot.inside_tolerance
    {
      id: snapshot.id,
      refreshed_at: snapshot.refreshed_at,
      stale: snapshot.stale_now?,
      refresh_status: snapshot.refresh_status,
      error_summary: snapshot.error_summary,
      production_venue: snapshot.production_venue,
      production_venue_name: HedgeVenues.label(snapshot.production_venue),
      selected_venue: selected,
      venue_states: venue_states,
      target_short_eth: snapshot.decimal_string(snapshot.target_short_eth),
      tolerance_eth: snapshot.decimal_string(snapshot.tolerance_abs_eth),
      drift_eth: snapshot.decimal_string(snapshot.drift_eth),
      inside_tolerance: inside_tolerance,
      hedge_status: hedge_status_label(inside_tolerance),
      combined_short_eth: snapshot.decimal_string(snapshot.combined_short_eth),
      leverage_margin_gate_status: snapshot.leverage_margin_gate_status,
      auto_readiness_status: snapshot.auto_readiness_status,
      planned_auto_action: snapshot.planned_auto_action,
      planned_auto_order_size_eth: snapshot.decimal_string(snapshot.planned_auto_order_size_eth),
      auto_status: snapshot_auto_status(snapshot),
      signer_status: snapshot_signer_status(snapshot),
      latest_rebalance: latest_venue_rebalance(@selected_hedge_venue),
      migration_status: cached_migration_status(venue_states),
      message: snapshot.stale_now? ? "Dashboard snapshot is stale." : "Dashboard snapshot refreshed."
    }
  end

  def cached_rewards_report
    snapshot = @position.position_rewards_fees_snapshot
    return nil unless snapshot

    {
      status: snapshot.refresh_status,
      value_state: snapshot.rewards_value_state,
      claimable_aero: snapshot.aero_rewards_amount&.to_s("F"),
      claimable_aero_usd: snapshot.aero_rewards_usd&.to_s("F"),
      aero_usd_price: snapshot.aero_usd_price&.to_s("F"),
      aero_usd_price_source: snapshot.aero_price_source,
      reward_source: snapshot.rewards_source,
      source_confidence: snapshot.rewards_confidence,
      stop_reason: snapshot.rewards_stop_reason,
      warnings: snapshot.warnings_list,
      snapshot_refreshed_at: snapshot.refreshed_at,
      snapshot_stale: snapshot.stale_now?,
      orders_submitted: snapshot.orders_submitted,
      signatures_created: snapshot.signatures_created
    }
  end

  def cached_fees_report
    snapshot = @position.position_rewards_fees_snapshot
    return nil unless snapshot

    {
      status: snapshot.refresh_status,
      value_state: snapshot.fee_value_state,
      fee_source: snapshot.fee_source,
      stop_reason: snapshot.fee_stop_reason,
      fee0_symbol: "WETH",
      fee0_amount: snapshot.lp_fee_weth_amount&.to_s("F"),
      fee0_usd: snapshot.lp_fee_weth_usd&.to_s("F"),
      fee1_symbol: "USDC",
      fee1_amount: snapshot.lp_fee_usdc_amount&.to_s("F"),
      fee1_usd: snapshot.lp_fee_usdc_usd&.to_s("F"),
      total_fees_usd: snapshot.lp_fee_total_usd&.to_s("F"),
      warnings: snapshot.warnings_list,
      snapshot_refreshed_at: snapshot.refreshed_at,
      snapshot_stale: snapshot.stale_now?,
      orders_submitted: snapshot.orders_submitted,
      signatures_created: snapshot.signatures_created
    }
  end

  def cached_hedge_accounting_report
    snapshot = @position.position_hedge_accounting_snapshot
    return nil unless snapshot

    components = {
      realized_pnl_usd: accounting_component(snapshot.realized_pnl_usd, "PositionHedgeAccountingSnapshot"),
      unrealized_pnl_usd: accounting_component(snapshot.unrealized_pnl_usd, "PositionHedgeAccountingSnapshot"),
      funding_pnl_usd: accounting_component(snapshot.funding_usd, "PositionHedgeAccountingSnapshot"),
      trading_fees_usd: accounting_component(snapshot.trading_fees_usd, "PositionHedgeAccountingSnapshot"),
      borrow_interest_usd: accounting_component(snapshot.borrow_interest_usd, "PositionHedgeAccountingSnapshot"),
      rebates_or_credits_usd: accounting_component(snapshot.rebates_credits_usd, "PositionHedgeAccountingSnapshot")
    }
    {
      venue: snapshot.venue,
      venue_name: HedgeVenues.label(snapshot.venue),
      current_short_eth: snapshot.current_short_eth&.to_s("F"),
      entry_price: snapshot.entry_price&.to_s("F"),
      mark_price: snapshot.mark_price&.to_s("F"),
      notional_usd: snapshot.notional_usd&.to_s("F"),
      components: components,
      net_venue_pnl_usd: snapshot.net_hedge_pnl_usd&.to_s("F"),
      unavailable_components: snapshot.unavailable_components_list,
      snapshot_refreshed_at: snapshot.refreshed_at,
      snapshot_stale: snapshot.stale_now?,
      orders_submitted: snapshot.orders_submitted,
      signatures_created: snapshot.signatures_created
    }
  end

  def accounting_component(value, source)
    return { state: "unavailable", value: nil, source: source } if value.blank?

    { state: "available", value: value.to_s("F"), source: source }
  end

  def missing_dashboard_snapshot
    venue_states = %w[extended ethereal nado].to_h { |venue| [ venue.to_sym, unknown_venue_state(venue) ] }
    {
      stale: true,
      refresh_status: "missing",
      production_venue: @position.hedge&.execution_venue,
      production_venue_name: HedgeVenues.label(@position.hedge&.execution_venue),
      selected_venue: venue_states[@selected_hedge_venue&.to_sym] || unknown_venue_state(@selected_hedge_venue),
      venue_states: venue_states,
      target_short_eth: nil,
      tolerance_eth: nil,
      drift_eth: nil,
      inside_tolerance: nil,
      hedge_status: "Unknown / snapshot not refreshed",
      combined_short_eth: nil,
      auto_status: { enabled: nil, label: "Auto Unknown", source: "snapshot missing" },
      signer_status: { label: "Unknown", ok: nil, source: "snapshot missing" },
      latest_rebalance: latest_venue_rebalance(@selected_hedge_venue),
      migration_status: { label: "Snapshot not refreshed.", complete: false },
      message: "Snapshot not refreshed yet. Click Refresh Read-only Data."
    }
  end

  def snapshot_venue_state(snapshot, venue)
    latest = latest_venue_rebalance(venue)
    state = snapshot.venue_state(venue)
    state.merge(
      latest_status: latest&.status,
      latest_message: latest&.message,
      latest_rebalance_at: latest&.rebalanced_at || latest&.updated_at
    )
  end

  def unknown_venue_state(venue)
    {
      venue: venue,
      venue_name: HedgeVenues.label(venue),
      short_size: nil,
      short_size_eth: nil,
      status: "unknown",
      notional_usd: nil,
      leverage: nil,
      latest_status: latest_venue_rebalance(venue)&.status,
      latest_message: latest_venue_rebalance(venue)&.message,
      stale_as_of: nil,
      source: "PositionDashboardSnapshot missing"
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

  def hedge_status_label(inside_tolerance)
    return "Unknown / diagnostics unavailable" if inside_tolerance.nil?

    inside_tolerance ? "In tolerance" : "Out of tolerance"
  end

  def snapshot_auto_status(snapshot)
    enabled = case snapshot.production_venue
    when "extended" then snapshot.extended_auto_enabled
    when "ethereal" then snapshot.ethereal_auto_enabled
    when "nado" then snapshot.nado_auto_enabled
    end
    return { enabled: nil, label: "Auto Unknown", source: "snapshot" } if enabled.nil?

    { enabled: enabled, label: enabled ? "Auto Active" : "Auto Off", source: "PositionDashboardSnapshot ##{snapshot.id}" }
  end

  def snapshot_signer_status(snapshot)
    status = snapshot.signer_status.presence || "unknown"
    {
      label: status == "ok" ? "OK" : status.humanize,
      ok: status == "ok",
      source: "PositionDashboardSnapshot ##{snapshot.id}",
      stale_as_of: snapshot.signer_checked_at
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

  def cached_migration_control_plan
    HedgeVenueMigrationPlanner.new.plan(
      position: @position,
      from_venue: params[:preview_from_venue].presence || params[:from_venue].presence || @position.hedge&.execution_venue,
      to_venue: params[:preview_to_venue].presence || params[:to_venue].presence || selected_migration_to_venue,
      mode: params[:preview_migration_mode].presence || params[:migration_mode].presence || "preview",
      step_size_eth: params[:max_step_size_eth].presence || default_migration_step_size_eth,
      full_migration_allowed: ActiveModel::Type::Boolean.new.cast(params[:preview_full_migration_allowed].presence || params[:full_migration_allowed]),
      migration_sequence: params[:preview_migration_sequence].presence || params[:migration_sequence]
    ).receipt
  rescue => e
    {
      status: "unavailable",
      blockers: [ "Migration planner unavailable: #{e.class}: #{e.message}" ],
      warnings: [],
      orders_placed: 0,
      signatures_created: 0,
      submitted: false
    }
  end

  def selected_migration_to_venue
    production = HedgeVenues.normalize(@position.hedge&.execution_venue)
    production == "extended" ? "ethereal" : "extended"
  end

  def default_migration_step_size_eth
    ENV.fetch("MIGRATION_MAX_STEP_SIZE_ETH", "0.01")
  end

  def migration_preview_query_params(position)
    {
      hedge_venue: position.hedge&.execution_venue,
      preview_from_venue: params[:from_venue],
      preview_to_venue: params[:to_venue],
      preview_migration_mode: params[:migration_mode],
      preview_migration_sequence: params[:migration_sequence],
      max_step_size_eth: params[:max_step_size_eth],
      preview_full_migration_allowed: params[:full_migration_allowed]
    }.compact
  end

  def write_migration_preview_receipt(result, position)
    receipt = result.receipt.merge(
      action: "migration_preview",
      final_status: result.blockers.present? ? "blocked_preview" : "preview_ready",
      dry_run: true,
      live: false,
      production_venue: position.hedge&.execution_venue,
      orders_placed: 0,
      orders_submitted: 0,
      signatures_created: 0,
      submitted: false
    )
    HedgeVenueMigrationReceiptWriter.new.write(receipt)
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

  def latest_jsonl_receipt_for_position(position_id, *patterns)
    files = patterns.flat_map { |pattern| Dir.glob(Rails.root.join(pattern)) }.sort
    files.reverse_each do |path|
      File.readlines(path).reverse_each do |line|
        next if line.blank?

        receipt = JSON.parse(line)
        return receipt if receipt["position_id"].to_s == position_id.to_s
      rescue JSON::ParserError
        next
      end
    end
    nil
  rescue SystemCallError
    nil
  end

  def parse_decimal(value)
    return nil if value.nil?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def decimal_or_nil(value)
    parse_decimal(value)
  end

  def hedge_venue_accounting
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

  def unavailable_extended_auto_readiness(message = "Extended auto readiness unavailable; refresh diagnostics")
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
      blockers: [ message ],
      warnings: [ message ]
    }
  end

  def auto_readiness_production_health(readiness)
    status = if readiness[:within_tolerance] == true || readiness[:active_within_tolerance] == true
      "HEALTHY"
    elsif readiness[:auto_can_act] == true
      "ACTION PENDING"
    elsif Array(readiness[:blockers]).present?
      "BLOCKED"
    else
      "WATCH"
    end
    {
      status: status,
      reason: readiness[:action_suppressed_reason].presence || Array(readiness[:blockers]).first || (status == "HEALTHY" ? "inside tolerance" : nil),
      venue: readiness[:active_auto_venue] || readiness[:venue],
      blockers: Array(readiness[:blockers]),
      warnings: Array(readiness[:warnings])
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
    target = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:target_short_eth))
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size)
    drift = target && current_short ? target - current_short : nil
    tolerance = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:tolerance_eth))
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
    target = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:target_short_eth))
    current_short = @cached_hedge_dashboard_snapshot&.dig(:selected_venue, :short_size)
    drift = target && current_short ? target - current_short : nil
    tolerance = decimal_or_nil(@cached_hedge_dashboard_snapshot&.dig(:tolerance_eth))
    latest_success = latest_successful_venue_action(@selected_hedge_venue)
    {
      status: "cached",
      target_short_eth: target&.to_s("F"),
      current_short_eth: current_short&.to_s("F"),
      drift_eth: drift&.to_s("F"),
      tolerance_eth: tolerance&.to_s("F"),
      rebalance_needed: drift && tolerance ? drift.abs > tolerance : false,
      last_rebalance_id: latest_success&.id,
      last_rebalance_time: latest_success&.rebalanced_at || latest_success&.updated_at,
      last_rebalance_status: latest_success&.status,
      last_rebalance_old_short_eth: latest_success&.old_short_size,
      last_rebalance_new_short_eth: latest_success&.new_short_size,
      warnings: [ "Auto diagnostics are loaded separately." ]
    }
  end

  def latest_successful_venue_action(venue)
    return nil unless @position.hedge && venue.present?

    @latest_successful_venue_actions ||= {}
    @latest_successful_venue_actions[venue] ||= @position.hedge.short_rebalances
      .where(venue: venue, asset: [ nil, "ETH", "WETH" ], status: ShortRebalance::STATUS_SUCCESS)
      .order(rebalanced_at: :desc, id: :desc)
      .first
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
      :deactivate_existing_aerodrome_positions,
      :active
    )
  end

  def duplicate_aerodrome_position(user:, wallet:, dex:, external_id:, pool_address:)
    Position.where(
      user: user,
      wallet: wallet,
      dex: dex,
      external_id: external_id,
      pool_address: pool_address
    )
      .where(source: [ nil, Position::SOURCE_AERODROME_DIRECT ])
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def supported_import_hedge_venue(existing)
    HedgeVenues.supported?(existing) ? HedgeVenues.normalize(existing) : RiskSettings.default_hedge_venue
  end

  def selected_supported_hedge_venue(position)
    requested = params[:hedge_venue].presence
    return HedgeVenues.normalize(requested) if requested.present? && HedgeVenues.supported?(requested)

    current = position.hedge&.execution_venue
    HedgeVenues.supported?(current) ? HedgeVenues.normalize(current) : RiskSettings.default_hedge_venue
  end

  def supported_action_venue(value)
    HedgeVenues.supported?(value) ? HedgeVenues.normalize(value) : RiskSettings.default_hedge_venue
  end

  def selected_position_tab
    requested = params[:tab].presence
    return requested if %w[overview hedge migration routes accounting diagnostics settings].include?(requested)
    return "hedge" if hedge_tab_default?

    "overview"
  end

  def hedge_tab_default?
    return false unless @position.hedge&.active?
    snapshot = @cached_hedge_dashboard_snapshot || {}
    return true if snapshot[:inside_tolerance] == false

    current_short = decimal_or_nil(snapshot[:selected_venue]&.dig(:short_size))
    target_short = decimal_or_nil(snapshot[:target_short_eth])
    return true if target_short&.positive? && (current_short.nil? || current_short.zero?)

    false
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

  def duplicate_position_ids(positions)
    PositionProductionState.duplicates(Position.where(id: positions.map(&:id))).flat_map { |group| group.fetch(:duplicates).map(&:id) }.to_set
  end
end
