namespace :nado do
  desc "Read-only Nado unified active-venue auto readiness diagnostics"
  task auto_readiness: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:dex, :hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        action: "nado_auto_readiness",
        status: "blocked",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    report = HedgeVenueAutoAdapters::Nado.new.readiness(position: position)
    puts JSON.pretty_generate(report.merge(action: "nado_auto_readiness", orders_submitted: 0, signatures_created: 0))
  end

  desc "Run Nado active-venue one-shot auto rebalance; dry-run by default"
  task auto_rebalance_once: :environment do
    position_id = ENV["position_id"].presence || ENV["POSITION_ID"].presence
    position = Position.includes(:dex, :hedge, :position_dashboard_snapshot).find_by(id: position_id)

    unless position
      puts JSON.pretty_generate(
        action: "nado_auto_rebalance_once",
        status: "blocked",
        position_id: position_id,
        blockers: [ "Position #{position_id || '(missing)'} not found." ],
        orders_submitted: 0,
        signatures_created: 0
      )
      next
    end

    live = ActiveModel::Type::Boolean.new.cast(ENV["live"].presence || ENV["LIVE"])
    dry_run = if ENV.key?("dry_run") || ENV.key?("DRY_RUN")
      ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    else
      !live
    end
    result = HedgeVenueAutoRebalanceAdapters::Nado.new.run(
      position: position,
      dry_run: dry_run,
      live: live,
      confirmation: ENV["confirmation"].presence || ENV["CONFIRMATION"].presence,
      max_slippage: ENV["max_slippage"].presence || ENV["MAX_SLIPPAGE"].presence || "0.01"
    )
    payload = result.receipt.merge(action: "nado_auto_rebalance_once", cli_status: nado_auto_cli_status(result))
    puts JSON.pretty_generate(payload)
    abort("Nado auto rebalance #{payload[:cli_status]}: #{result.blockers.join('; ')}") if live && nado_auto_cli_failure?(result)
  end

  desc "Read-only Nado ETH-PERP market metadata diagnostics"
  task market_metadata: :environment do
    product_id = ENV["product_id"].presence || ENV["PRODUCT_ID"].presence || NadoHedgeExecutionService::ETH_PERP_PRODUCT_ID
    position = Position.find_by(id: ENV["position_id"].presence || ENV["POSITION_ID"].presence) if ENV["position_id"].present? || ENV["POSITION_ID"].present?
    service = NadoHedgeExecutionService.new(env: ENV)
    metadata = service.market_metadata(position: position)
    diagnostics = metadata[:diagnostics] || {}
    market_query = diagnostics[:market_price_query] || {}
    puts JSON.pretty_generate(
      action: "nado_market_metadata",
      product_id: product_id.to_s,
      status: metadata[:status],
      endpoint: market_query[:endpoint],
      query_params: market_query[:query_params],
      http_status: market_query[:http_status],
      query_status: market_query[:status],
      response_keys: market_query[:response_keys],
      top_level_keys: market_query[:top_level_keys],
      bid_x18: market_query[:bid_x18],
      ask_x18: market_query[:ask_x18],
      parsed_bid: market_query[:parsed_bid],
      parsed_ask: market_query[:parsed_ask],
      selected_mark_price: market_query[:selected_mark_price] || metadata[:market_price],
      price_increment: metadata[:price_increment],
      size_increment: metadata[:size_increment],
      metadata_source: metadata[:source],
      blockers: metadata[:blockers],
      warnings: metadata[:warnings],
      orders_submitted: 0,
      signatures_created: 0
    )
  end

  desc "Read-only reconciliation for pending Nado ShortRebalance records"
  task reconcile_pending_rebalances: :environment do
    scope = ShortRebalance.where(venue: "nado", status: ShortRebalance::STATUS_PENDING)
    scope = scope.where(hedge_id: ENV["HEDGE_ID"]) if ENV["HEDGE_ID"].present?
    position = Position.find_by(id: ENV["position_id"] || ENV["POSITION_ID"])
    resolver = NadoStalePendingRebalanceResolver.new
    reconciler = NadoPendingRebalanceReconciler.new
    results = scope.includes(:hedge).order(:rebalanced_at, :id).map do |rebalance|
      before = rebalance.status
      reconciled = reconciler.reconcile(rebalance)
      rebalance.reload
      {
        id: rebalance.id,
        hedge_id: rebalance.hedge_id,
        before_status: before,
        after_status: rebalance.status,
        new_short_size: rebalance.new_short_size&.to_s("F"),
        message: rebalance.message,
        reconciled: reconciled.present? && rebalance.status == ShortRebalance::STATUS_SUCCESS
      }
    end
    stale_report = position ? resolver.report(position: position, dry_run: true).receipt : nil
    puts JSON.pretty_generate({
      checked: results.size,
      results: results,
      stale_candidates: stale_report&.fetch(:candidates, [])&.select { |candidate| candidate[:stale_candidate] },
      stale_candidates_count: stale_report&.fetch(:stale_candidates_count, 0),
      blocking_pending_count: stale_report&.fetch(:blocking_pending_count, results.count { |row| row[:after_status] == ShortRebalance::STATUS_PENDING }),
      ignored_stale_count: stale_report&.fetch(:ignored_stale_count, 0),
      recommended_command: position ? stale_report.fetch(:recommended_command) : "pass position_id=... to evaluate stale pending candidates",
      orders_submitted: 0,
      signatures_created: 0
    })
  end

  desc "Acknowledge stale/superseded Nado pending ShortRebalance rows without live exchange actions"
  task acknowledge_stale_pending_rebalances: :environment do
    position_id = ENV["position_id"] || ENV["POSITION_ID"]
    abort("position_id is required") if position_id.blank?

    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", "true"))
    result = NadoStalePendingRebalanceResolver.new.report(
      position: Position.find(position_id),
      dry_run: dry_run,
      confirmation: ENV["confirmation"]
    )
    puts JSON.pretty_generate(result.receipt)
    abort("Nado stale pending acknowledgement blocked: #{result.blockers.join('; ')}") if result.blockers.any?
  end

  desc "No-live Nado isolated payload parity check"
  task isolated_payload_check: :environment do
    env = {
      "NADO_API_BASE_URL" => "https://nado.invalid/v1",
      "NADO_ACCOUNT_ADDRESS" => "0x#{"11" * 20}",
      "NADO_ACCOUNT_SUBACCOUNT" => "0x#{"01" * 32}",
      "NADO_ETH_PERP_PRODUCT_METADATA_JSON" => {
        product_id: 4,
        chain_id: 1,
        price_increment_x18: "100000000000000000",
        size_increment: "1000000000000000",
        market_price: "2300"
      }.to_json
    }
    service = NadoHedgeExecutionService.new(env: env)
    position = Position.new(
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "0.809",
      asset1_amount: "240",
      asset0_price_usd: "2300",
      asset1_price_usd: "1",
      mellow_metadata: {
        hedge_ready: true,
        user_weth_exposure: "0.809",
        user_usdc_exposure: "240",
        user_total_value_usd: "2100.7"
      }.to_json
    )
    current = {
      size: BigDecimal("-0.809"),
      short_size: BigDecimal("0.809"),
      symbol: "ETH-PERP",
      side: "short",
      margin_mode: "isolated",
      isolated_margin_usd: BigDecimal("1860.7"),
      metadata: { raw: { "subaccount" => "0x#{"02" * 32}" } }
    }
    close = service.build_order_preview(position: position, action: "close", size_eth: BigDecimal("0.809"), max_slippage: "0.01", current_position: current)
    increase = service.build_order_preview(position: position, action: "rebalance", size_eth: BigDecimal("0.047"), max_slippage: "0.01", current_position: current)
    plan = service.plan_rebalance(target_size_eth: BigDecimal("0.762"), current_position: current, tolerance_eth: BigDecimal("0.001"))
    failures = []
    failures << "close appendix must be UI-equivalent 2817" unless close.dig(:summary, :appendix).to_s == "2817"
    failures << "close sender must be default_1" unless close.dig(:summary, :order_sender_kind) == "default_1"
    failures << "close amount must be positive buy full size" unless close.dig(:summary, :amount_x18).to_s == "809000000000000000"
    failures << "increase amount must be negative sell delta" unless increase.dig(:summary, :amount_x18).to_s == "-47000000000000000"
    failures << "target decrease must plan close/reopen while partial reduce is unproven" unless plan[:action] == "isolated_full_close_then_reopen"
    result = {
      status: failures.empty? ? "PASS" : "FAIL",
      failures: failures,
      statement: "No orders submitted and no signatures created.",
      source: "delta_neutral no-live Nado isolated payload parity check",
      close_summary: close[:summary].except(:signature),
      increase_summary: increase[:summary].except(:signature),
      decrease_plan: plan
    }
    puts JSON.pretty_generate(result)
    abort("Nado isolated payload check failed") if failures.any?
  end

  desc "Controlled Nado isolated delta-order live verification path; dry-run by default"
  task isolated_delta_live_check: :environment do
    direction = (ENV["direction"] || ENV["DIRECTION"] || "decrease").to_s.downcase
    size_eth = BigDecimal((ENV["size_eth"] || ENV["SIZE_ETH"] || "0.005").to_s)
    dry_run = ActiveModel::Type::Boolean.new.cast(ENV.fetch("dry_run", ENV.fetch("DRY_RUN", "true")))
    confirmation = ENV["confirmation"] || ENV["CONFIRMATION"]
    position = nado_delta_probe_position
    current_position = nado_delta_probe_current_position
    service = nado_delta_probe_service(current_position)

    result = if direction == "round_trip"
      service.round_trip_delta_probe(
        position: position,
        size_eth: size_eth,
        current_position: current_position,
        confirmation: confirmation,
        max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
        dry_run: dry_run
      )
    else
      service.delta_probe(
        position: position,
        direction: direction,
        size_eth: size_eth,
        current_position: current_position,
        confirmation: confirmation,
        max_slippage: ENV["max_slippage"] || ENV["MAX_SLIPPAGE"] || "0.01",
        dry_run: dry_run
      )
    end

    receipt_path = Rails.root.join("storage", "nado_delta_live_checks", "#{Time.current.utc.strftime('%Y%m%d')}.jsonl")
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(result.receipt)) }

    puts JSON.pretty_generate(result.receipt)
    puts "Receipt appended to #{receipt_path}"
    abort("Nado isolated delta probe did not pass: #{result.status}") unless result.status.in?(%w[dry_run submitted_and_confirmed])
  end

  def nado_delta_probe_position
    return nado_delta_probe_mock_position if ActiveModel::Type::Boolean.new.cast(ENV["MOCK_NADO_READBACK"])

    Position.find(ENV["position_id"] || ENV["POSITION_ID"] || 3)
  end

  def nado_auto_cli_status(result)
    final_status = result.receipt[:final_status].to_s
    return "confirmed_late" if result.status.to_s == "rebalance_confirmed_late" || final_status == "REBALANCE_CONFIRMED_LATE"
    return "confirmed" if result.status.to_s.in?(%w[success submitted_and_confirmed no_op]) || final_status == "REBALANCE_CONFIRMED"
    return "pending_recheck" if result.status.to_s.in?(%w[submitted_pending_readback submitted_but_readback_pending submitted_but_not_confirmed]) || final_status == "REBALANCE_REQUIRES_RECHECK"
    return "blocked_before_submit" if result.status.to_s == "blocked_before_submit"

    "failed_after_submit"
  end

  def nado_auto_cli_failure?(result)
    nado_auto_cli_status(result).in?(%w[blocked_before_submit failed_after_submit])
  end

  def nado_delta_probe_mock_position
    Position.new(
      id: ENV["position_id"] || ENV["POSITION_ID"] || 3,
      source: Position::SOURCE_MELLOW_AUTOPILOT,
      external_id: "mellow:mock-delta-probe",
      asset0: "WETH",
      asset1: "USDC",
      asset0_amount: "0.809",
      asset1_amount: "240",
      asset0_price_usd: "2300",
      asset1_price_usd: "1",
      active: true,
      mellow_metadata: {
        hedge_ready: true,
        last_probe_confidence: "high",
        user_weth_exposure: "0.809",
        user_usdc_exposure: "240",
        user_total_value_usd: "2100.7"
      }.to_json
    )
  end

  def nado_delta_probe_current_position
    return nado_delta_probe_mock_readback if ActiveModel::Type::Boolean.new.cast(ENV["MOCK_NADO_READBACK"])

    HedgeVenues::Nado.new.read_position(symbol: "ETH")
  end

  def nado_delta_probe_mock_readback(size: BigDecimal("0.809"))
    {
      size: -size,
      short_size: size,
      symbol: "ETH-PERP",
      side: "short",
      margin_mode: "isolated",
      isolated_margin_usd: BigDecimal("1860.7"),
      product_id: 4,
      entry_price: BigDecimal("2300"),
      mark_price: BigDecimal("2300"),
      metadata: { raw: { "subaccount" => "0x#{"02" * 32}" } }
    }
  end

  def nado_delta_probe_service(current_position)
    mock = ActiveModel::Type::Boolean.new.cast(ENV["MOCK_NADO_READBACK"])
    env = mock ? nado_delta_probe_mock_env : ENV
    venue = mock ? NadoDeltaProbeMockVenue.new([ current_position ]) : nil
    NadoHedgeExecutionService.new(env: env, venue: venue, sleeper: ->(_seconds) { })
  end

  def nado_delta_probe_mock_env
    {
      "NADO_API_BASE_URL" => "https://nado.invalid/v1",
      "NADO_ACCOUNT_ADDRESS" => "0x#{"11" * 20}",
      "NADO_ACCOUNT_SUBACCOUNT" => "0x#{"01" * 32}",
      "EXECUTION_SIGNER_URL" => "http://127.0.0.1:9123",
      "NADO_ETH_PERP_PRODUCT_METADATA_JSON" => {
        product_id: 4,
        chain_id: 1,
        price_increment_x18: "100000000000000000",
        size_increment: "1000000000000000",
        market_price: "2300"
      }.to_json
    }
  end

  class NadoDeltaProbeMockVenue
    def initialize(readbacks)
      @readbacks = readbacks
    end

    def read_position(symbol:)
      @readbacks.last
    end

    def raw_positions_present_but_unnormalized?
      false
    end
  end
end
