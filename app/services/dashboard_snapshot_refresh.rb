require "timeout"

class DashboardSnapshotRefresh
  DEFAULT_TIMEOUT_SECONDS = 2

  def initialize(position:, env: ENV, venue_builder: HedgeVenues, signer_client: nil, timeout_seconds: DEFAULT_TIMEOUT_SECONDS)
    @position = position
    @env = env
    @venue_builder = venue_builder
    @signer_client = signer_client || ExtendedStarkSignerClient.new(env: env)
    @timeout_seconds = timeout_seconds
  end

  def refresh
    now = Time.current
    valuation = PositionValuation.current(position)
    target = target_short(valuation)
    tolerance_abs = target && position.hedge ? target * position.hedge.tolerance : nil
    venue_results = %w[extended ethereal nado].to_h { |venue| [ venue, read_venue(venue) ] }
    combined = combined_short(venue_results)
    drift = target && combined ? target - combined : nil
    errors = venue_results.transform_values { |result| result[:error] }.compact
    signer = read_signer_health
    errors[:signer] = signer[:error] if signer[:error].present?
    refresh_status = snapshot_status(venue_results, signer)

    attrs = {
      refreshed_at: now,
      refresh_status: refresh_status,
      stale: false,
      error_summary: errors.values.join("; ").presence,
      production_venue: position.hedge&.execution_venue,
      selected_venue: position.hedge&.execution_venue,
      target_short_eth: target,
      tolerance_ratio: position.hedge&.tolerance,
      tolerance_abs_eth: tolerance_abs,
      combined_short_eth: combined,
      drift_eth: drift,
      inside_tolerance: drift && tolerance_abs ? drift.abs <= tolerance_abs : nil,
      extended_live_enabled: bool_env("EXTENDED_LIVE_ENABLED"),
      extended_auto_enabled: bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_enabled: bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_enabled: bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
      signer_status: signer[:status],
      signer_checked_at: signer[:checked_at],
      source_errors: JSON.generate(errors)
    }.merge(venue_attrs(venue_results))

    position.create_position_dashboard_snapshot! unless position.position_dashboard_snapshot
    position.position_dashboard_snapshot.update!(attrs)
    position.position_dashboard_snapshot.reload
  end

  private

  attr_reader :position, :env, :venue_builder, :signer_client, :timeout_seconds

  def read_venue(venue)
    return not_configured_venue if venue_not_configured?(venue)

    result = with_timeout("#{venue} readback") do
      adapter = venue_builder.build(venue)
      current_position = adapter.read_position(symbol: "ETH")
      account_state = venue == "extended" ? safe_account_state(adapter) : {}
      normalize_venue_result(venue, current_position, account_state)
    end
    result[:source_status] = "ok" if result[:source_status].blank?
    result
  rescue Timeout::Error => e
    venue_error(e)
  rescue => e
    venue_error(e)
  end

  def not_configured_venue
    {
      status: "unknown",
      source_status: "not_configured",
      short_eth: nil
    }
  end

  def venue_not_configured?(venue)
    case venue
    when "extended"
      HedgeVenues::Extended::REQUIRED_CONFIG.keys.any? { |key| env[key].blank? }
    when "ethereal"
      !bool_env("ETHEREAL_READ_ONLY_ENABLED") || env["ETHEREAL_API_BASE_URL"].blank? || env["ETHEREAL_SUBACCOUNT_ID"].blank?
    when "nado"
      !bool_env("NADO_READ_ONLY_ENABLED") || (env["NADO_GATEWAY_QUERY_BASE_URL"].blank? && env["NADO_API_BASE_URL"].blank?) || (env["NADO_ACCOUNT_ADDRESS"].blank? && env["NADO_ACCOUNT_SUBACCOUNT"].blank?)
    else
      false
    end
  end

  def safe_account_state(adapter)
    with_timeout("extended account state") { adapter.account_state || {} }
  rescue
    {}
  end

  def normalize_venue_result(venue, current_position, account_state)
    short = short_size(current_position)
    status = if current_position.nil?
      "flat"
    elsif short&.positive?
      "active"
    else
      "flat"
    end

    {
      status: status,
      source_status: "ok",
      short_eth: short || BigDecimal("0"),
      notional_usd: decimal_or_nil(current_position&.dig(:notional_usd)),
      entry_price: decimal_or_nil(current_position&.dig(:entry_price)),
      mark_price: decimal_or_nil(current_position&.dig(:mark_price)),
      unrealized_pnl_usd: decimal_or_nil(current_position&.dig(:unrealized_pnl_usd)),
      leverage: decimal_or_nil(current_position&.dig(:leverage)),
      effective_leverage: decimal_or_nil(current_position&.dig(:effective_leverage)),
      margin_mode: current_position&.dig(:margin_mode),
      open_orders_count: venue == "extended" ? account_state[:open_orders_count] : nil,
      leverage_margin_gate_status: venue == "extended" ? account_state.dig(:margin_gate, :status) : nil,
      auto_readiness_status: nil,
      planned_auto_action: nil,
      planned_auto_order_size_eth: nil
    }
  end

  def venue_error(error)
    {
      status: "error",
      source_status: "error",
      short_eth: nil,
      error: sanitized_error(error)
    }
  end

  def read_signer_health
    return { status: "unknown", checked_at: nil } if env["EXTENDED_SIGNER_URL"].blank?

    payload = with_timeout("extended signer health") { signer_client.health.with_indifferent_access }
    ok = ActiveModel::Type::Boolean.new.cast(payload[:ok])
    { status: ok ? "ok" : "down", checked_at: Time.current }
  rescue Timeout::Error => e
    { status: "down", checked_at: Time.current, error: sanitized_error(e) }
  rescue => e
    { status: "down", checked_at: Time.current, error: sanitized_error(e) }
  end

  def venue_attrs(results)
    {
      extended_short_eth: results.dig("extended", :short_eth),
      ethereal_short_eth: results.dig("ethereal", :short_eth),
      nado_short_eth: results.dig("nado", :short_eth),
      extended_status: results.dig("extended", :status),
      ethereal_status: results.dig("ethereal", :status),
      nado_status: results.dig("nado", :status),
      extended_notional_usd: results.dig("extended", :notional_usd),
      ethereal_notional_usd: results.dig("ethereal", :notional_usd),
      nado_notional_usd: results.dig("nado", :notional_usd),
      extended_entry_price: results.dig("extended", :entry_price),
      extended_mark_price: results.dig("extended", :mark_price),
      extended_unrealized_pnl_usd: results.dig("extended", :unrealized_pnl_usd),
      extended_leverage: results.dig("extended", :leverage),
      extended_effective_leverage: results.dig("extended", :effective_leverage),
      extended_margin_mode: results.dig("extended", :margin_mode),
      ethereal_effective_leverage: results.dig("ethereal", :effective_leverage),
      open_orders_count_extended: results.dig("extended", :open_orders_count),
      leverage_margin_gate_status: results.dig("extended", :leverage_margin_gate_status),
      auto_readiness_status: results.dig("extended", :auto_readiness_status),
      planned_auto_action: results.dig("extended", :planned_auto_action),
      planned_auto_order_size_eth: results.dig("extended", :planned_auto_order_size_eth),
      extended_source_status: results.dig("extended", :source_status),
      ethereal_source_status: results.dig("ethereal", :source_status),
      nado_source_status: results.dig("nado", :source_status)
    }
  end

  def snapshot_status(results, signer)
    return "ok" if results.values.all? { |result| result[:source_status] == "ok" } && signer[:error].blank?
    return "error" if results.values.all? { |result| result[:source_status] == "error" }

    "partial"
  end

  def combined_short(results)
    values = results.values.map { |result| result[:short_eth] }
    return nil unless values.all?

    values.sum(BigDecimal("0"))
  end

  def target_short(valuation)
    return nil unless valuation.weth_exposure && position.hedge

    valuation.weth_exposure * position.hedge.target
  end

  def short_size(current_position)
    return BigDecimal("0") unless current_position

    value = current_position[:short_size] || current_position["short_size"]
    return BigDecimal(value.to_s) if value.present?

    size = BigDecimal((current_position[:size] || current_position["size"]).to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError
    nil
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def with_timeout(_name, &block)
    Timeout.timeout(timeout_seconds, &block)
  end

  def sanitized_error(error)
    "#{error.class}: #{error.message.to_s.gsub(/Bearer\s+\S+/i, 'Bearer [REDACTED]').gsub(/0x[a-f0-9]{64,}/i, '[REDACTED_HEX]')}"
  end
end
