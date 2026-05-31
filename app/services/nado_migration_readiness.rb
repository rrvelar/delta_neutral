class NadoMigrationReadiness
  DEFAULT_MAX_SLIPPAGE = BigDecimal("0.01")
  DEFAULT_SYNTHETIC_PROOF_SHORT_ETH = BigDecimal("0.01")
  LIVE_BLOCKER = "Nado live migration requires AERODROME_NADO_LIVE_MIGRATION_ENABLED=true and AERODROME_NADO_HEDGE_LIVE_ENABLED=true.".freeze

  def initialize(position: nil, position_id: nil, snapshot: nil, intended_role: "either", mode: "full", sequence: "target_first", env: ENV, nado_service: nil, synthetic_proof_short_eth: nil)
    @position = position || Position.find_by(id: position_id)
    @snapshot = snapshot || @position&.position_dashboard_snapshot
    @intended_role = intended_role.to_s
    @mode = mode.to_s
    @sequence = sequence.to_s
    @env = env
    @nado_service = nado_service
    @synthetic_proof_short_eth = synthetic_proof_short_eth || env["NADO_MIGRATION_SYNTHETIC_PROOF_SHORT_ETH"] || DEFAULT_SYNTHETIC_PROOF_SHORT_ETH
  end

  def report
    blockers = []
    warnings = [ "Nado migration readiness is no-live unless explicit migration and Nado live gates are opened." ]
    blockers << "Nado migration readiness is not proven." unless nado_position_read_available? && nado_open_orders_read_available? && nado_market_read_available?
    blockers << "Position dashboard snapshot is missing; Nado migration proof requires snapshot exposure." unless snapshot
    blockers << LIVE_BLOCKER unless bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED") && bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    blockers << "Nado close/open readback proof required." unless nado_position_read_available?
    blockers << "Nado open orders readback is unavailable." unless nado_open_orders_read_available?
    blockers << nado_open_orders_unavailable_reason if !nado_open_orders_read_available? && nado_open_orders_unavailable_reason.present?
    blockers << "Nado open orders must be zero for migration proof." if nado_open_orders_count.to_i.positive?
    blockers << "Nado market metadata is unavailable." unless nado_market_read_available?
    blockers.concat(account_blockers)

    target_preview = target_leg_preview
    source_preview = source_leg_preview
    source_proof = source_leg_preview_proof
    blockers << "Nado open/increase short payload preview unavailable." if target_role? && !target_preview_available?(target_preview)
    blockers << "Nado reduce-only close/reduce payload preview unavailable." if source_role? && !source_preview_available?(source_preview) && !source_preview_available?(source_proof)
    blockers << "source venue Nado has no current short to migrate." if source_role? && nado_current_short&.zero?

    missing = missing_capabilities(
      target_preview: target_preview,
      source_preview: source_preview,
      source_proof: source_proof
    )

    {
      status: readiness_status(blockers: blockers, target_preview: target_preview, source_preview: source_preview, source_proof: source_proof),
      intended_role: intended_role,
      mode: mode,
      sequence: sequence,
      nado_position_read_available: nado_position_read_available?,
      nado_open_orders_read_available: nado_open_orders_read_available?,
      nado_current_short_eth: decimal_string(nado_current_short),
      nado_flat: nado_current_short&.zero?,
      nado_open_orders_count: nado_open_orders_count,
      nado_open_orders_unavailable_reason: nado_open_orders_unavailable_reason,
      nado_open_orders_read_diagnostics: nado_open_orders_read_diagnostics,
      nado_market_read_available: nado_market_read_available?,
      nado_open_short_preview_available: target_preview_available?(target_preview),
      nado_reduce_only_close_preview_available: source_preview_available?(source_preview) || source_preview_available?(source_proof),
      nado_reduce_only_close_preview_proof_mode: nado_current_short&.positive? ? "current_position" : "synthetic",
      production_source_route_available: nado_current_short&.positive?,
      route_still_blocked_because_source_flat: source_role? && nado_current_short&.zero?,
      nado_open_short_supported: target_preview_available?(target_preview),
      nado_reduce_only_close_supported: source_preview_available?(source_preview) || source_preview_available?(source_proof),
      nado_leverage_margin_known: nado_market_read_available?,
      nado_live_enabled: bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED"),
      nado_auto_enabled: bool_env("AERODROME_NADO_AUTO_ENABLED"),
      nado_live_migration_supported: true,
      target_leg_preview: target_preview,
      source_leg_preview: source_preview,
      nado_source_leg_preview_proof: source_proof,
      source_leg_preview_proof: source_proof,
      blockers: blockers.uniq,
      warnings: warnings.uniq,
      missing_capabilities: missing.uniq,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :position, :snapshot, :intended_role, :mode, :sequence, :env, :synthetic_proof_short_eth

  def nado_service
    @nado_service ||= NadoHedgeExecutionService.new(env: env)
  end

  def nado_position
    @nado_position = nado_service.read_position if !defined?(@nado_position)
    @nado_position
  rescue => e
    @nado_position_error = "#{e.class}: #{e.message}"
    :unavailable
  end

  def account_state
    return @account_state if defined?(@account_state)

    if nado_service.respond_to?(:account_state)
      return @account_state = nado_service.account_state
    end

    venue = nado_service.instance_variable_get(:@venue) if nado_service.respond_to?(:instance_variable_get)
    @account_state = venue&.account_state || {}
  rescue => e
    @account_state_error = "#{e.class}: #{e.message}"
    @account_state = {}
  end

  def nado_position_read_available?
    return false if account_blockers.any? { |blocker| blocker.to_s.include?("position readback") || blocker.to_s.include?("read-only checks") }

    nado_position != :unavailable
  end

  def nado_open_orders_read_available?
    !nado_open_orders_count.nil?
  end

  def nado_open_orders_count
    raw = account_state[:open_orders_count] || account_state["open_orders_count"]
    return nil if raw.nil?

    raw.to_i
  end

  def nado_open_orders_unavailable_reason
    return nil if nado_open_orders_read_available?

    account_state[:open_orders_unavailable_reason] || account_state["open_orders_unavailable_reason"] || "Nado open orders endpoint is unavailable or not configured."
  end

  def nado_open_orders_read_diagnostics
    diagnostics = account_state[:open_orders_read_diagnostics] || account_state["open_orders_read_diagnostics"]
    return diagnostics if bool_env("NADO_OPEN_ORDERS_DIAGNOSTICS_VERBOSE")

    compact_open_orders_diagnostics(diagnostics)
  end

  def account_blockers
    Array(account_state[:blockers] || account_state["blockers"])
  end

  def compact_open_orders_diagnostics(diagnostics)
    return nil unless diagnostics.is_a?(Hash)

    data = diagnostics.with_indifferent_access
    attempts = Array(data[:attempts]).select { |attempt| attempt.is_a?(Hash) }
    successful_attempts = attempts.select { |attempt| attempt.with_indifferent_access[:status].to_s == "ok" }
    eth_attempt = attempts.find { |attempt| attempt.with_indifferent_access[:product_id].to_s == "4" }
    {
      endpoint_path: data[:endpoint_path],
      query_type: data[:query_type],
      query_keys: data[:query_keys],
      product_ids_available: data[:product_ids_available],
      nado_open_orders_product_ids_checked_count: attempts.size,
      nado_open_orders_successful_attempts_count: successful_attempts.size,
      nado_eth_perp_product_id: eth_attempt ? "4" : nil,
      nado_eth_perp_open_orders_count: eth_attempt&.with_indifferent_access&.fetch(:rows_count, nil)
    }.compact
  end

  def nado_market_read_available?
    [ target_leg_preview, source_leg_preview, source_leg_preview_proof ].compact.any? { |preview| preview.dig(:payload_summary, :product_id).present? || preview.dig(:payload_summary, :rounded_price).present? }
  end

  def nado_current_short
    short_from_position(nado_position)
  end

  def target_leg_preview
    return @target_leg_preview if defined?(@target_leg_preview)
    return @target_leg_preview = nil unless target_role? && snapshot && position

    size = target_leg_size
    return @target_leg_preview = nil unless size&.positive?

    action = nado_current_short&.positive? ? "rebalance" : "open"
    order = nado_service.build_order_preview(
      position: position,
      action: action,
      size_eth: size,
      max_slippage: DEFAULT_MAX_SLIPPAGE,
      current_position: nado_position == :unavailable ? nil : nado_position
    )
    @target_leg_preview = leg_preview(order: order, action: action, size: size, expected_after: nado_current_short.to_d + size)
  rescue => e
    @target_leg_preview = unavailable_preview("Nado target leg preview unavailable: #{e.class}: #{e.message}")
  end

  def source_leg_preview
    return @source_leg_preview if defined?(@source_leg_preview)
    return @source_leg_preview = nil unless source_role? && snapshot && position
    return @source_leg_preview = nil unless nado_current_short&.positive?

    @source_leg_preview = build_source_leg_preview(short: nado_current_short, synthetic: false)
  end

  def source_leg_preview_proof
    return @source_leg_preview_proof if defined?(@source_leg_preview_proof)
    return @source_leg_preview_proof = nil unless source_role? && snapshot && position
    return @source_leg_preview_proof = source_leg_preview if nado_current_short&.positive?

    @source_leg_preview_proof = build_source_leg_preview(short: synthetic_proof_short, synthetic: true)
  end

  def build_source_leg_preview(short:, synthetic:)
    return nil unless short&.positive?

    size = source_leg_size(short)
    return nil unless size&.positive?

    service_action = mode == "full" ? "close" : "rebalance"
    service_size = mode == "full" ? size : -size
    expected_after = [ short - size, BigDecimal("0") ].max
    order = nado_service.build_order_preview(
      position: position,
      action: service_action,
      size_eth: service_size,
      max_slippage: DEFAULT_MAX_SLIPPAGE,
      current_position: synthetic ? synthetic_position(short) : nado_position
    )
    leg_preview(
      order: order,
      action: mode == "full" ? "close_short" : "decrease_short",
      size: size,
      expected_after: expected_after,
      synthetic: synthetic,
      production_current_short: nado_current_short
    )
  rescue => e
    unavailable_preview("Nado source leg preview unavailable: #{e.class}: #{e.message}")
  end

  def leg_preview(order:, action:, size:, expected_after:, synthetic: false, production_current_short: nil)
    summary = order.fetch(:summary, {}).to_h.symbolize_keys
    {
      venue: "nado",
      action: action,
      side: summary[:side],
      reduce_only: summary[:reduce_only],
      size_eth: decimal_string(size),
      expected_after_short_eth: decimal_string(expected_after),
      payload_summary: summary.slice(
        :venue,
        :symbol,
        :action,
        :side,
        :reduce_only,
        :full_close,
        :close_strategy,
        :rounded_size_eth,
        :rounded_price,
        :estimated_notional_usd,
        :product_id,
        :order_type,
        :margin_mode,
        :requested_leverage,
        :appendix,
        :appendix_decoded,
        :isolated,
        :order_sender_kind
      ),
      blockers: order.fetch(:blockers, []),
      warnings: order.fetch(:warnings, []),
      ok: order.fetch(:ok, false),
      synthetic_proof: synthetic,
      not_current_position: synthetic,
      production_current_short_eth: decimal_string(production_current_short),
      route_still_blocked_because_source_flat: synthetic && production_current_short&.zero?,
      submitted: false,
      signatures_created: 0,
      orders_submitted: 0
    }
  end

  def unavailable_preview(message)
    {
      venue: "nado",
      ok: false,
      blockers: [ message ],
      warnings: [],
      submitted: false,
      signatures_created: 0,
      orders_submitted: 0
    }
  end

  def target_role?
    intended_role.in?(%w[target either matrix])
  end

  def source_role?
    intended_role.in?(%w[source either matrix])
  end

  def target_leg_size
    target = BigDecimal(snapshot.target_short_eth.to_s)
    [ target - nado_current_short.to_d, BigDecimal("0") ].max
  rescue ArgumentError
    nil
  end

  def source_leg_size(short)
    return short if mode == "full"

    [ short, BigDecimal(ENV.fetch("MIGRATION_MAX_STEP_SIZE_ETH", "0.01")) ].min
  rescue ArgumentError
    short
  end

  def synthetic_position(short)
    {
      venue: "Nado",
      asset: "ETH",
      symbol: "ETH-PERP",
      side: "short",
      size: -short,
      short_size: short,
      margin_mode: "isolated",
      isolated_margin_usd: short * BigDecimal("2500")
    }
  end

  def synthetic_proof_short
    return nil if synthetic_proof_short_eth.blank?

    BigDecimal(synthetic_proof_short_eth.to_s)
  rescue ArgumentError
    nil
  end

  def target_preview_available?(preview)
    preview.present? && preview.fetch(:ok, false) && preview.fetch(:blockers, []).empty?
  end

  def source_preview_available?(preview)
    preview.present? && preview.fetch(:ok, false) && preview.fetch(:blockers, []).empty?
  end

  def missing_capabilities(target_preview:, source_preview:, source_proof:)
    missing = []
    missing << "Nado current position readback" unless nado_position_read_available?
    missing << "Nado open orders readback" unless nado_open_orders_read_available?
    missing << "Nado market metadata" unless nado_market_read_available?
    missing << "Nado open/increase short payload preview" if target_role? && !target_preview_available?(target_preview)
    missing << "Nado reduce-only close/reduce payload preview" if source_role? && !source_preview_available?(source_preview) && !source_preview_available?(source_proof)
    missing << LIVE_BLOCKER unless bool_env("AERODROME_NADO_LIVE_MIGRATION_ENABLED") && bool_env("AERODROME_NADO_HEDGE_LIVE_ENABLED")
    missing
  end

  def readiness_status(blockers:, target_preview:, source_preview:, source_proof:)
    return "not_implemented" unless nado_position_read_available? || nado_market_read_available?

    preview_ok = (!target_role? || target_preview_available?(target_preview)) &&
      (!source_role? || source_preview_available?(source_preview) || source_preview_available?(source_proof))
    operational_blockers = blockers - [ LIVE_BLOCKER ]
    return "partial" if preview_ok && operational_blockers.empty?
    return "partial" if [ target_preview, source_preview, source_proof ].compact.any? { |preview| preview.fetch(:ok, false) }

    "blocked"
  end

  def short_from_position(position)
    return BigDecimal("0") if position.nil?
    return nil if position == :unavailable
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?
    return BigDecimal(position["short_size"].to_s) if position["short_size"].present?

    size = BigDecimal((position[:size] || position["size"]).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError, NoMethodError
    BigDecimal(snapshot&.nado_short_eth.to_s)
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def decimal_string(value)
    value&.to_s("F")
  end
end
