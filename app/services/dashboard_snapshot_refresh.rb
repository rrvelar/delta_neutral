require "timeout"

class DashboardSnapshotRefresh
  DEFAULT_TIMEOUT_SECONDS = 8.0
  DEFAULT_EXTENDED_OPTIONAL_INTERVAL_SECONDS = 300
  @extended_optional_attempts = {}

  class << self
    attr_reader :extended_optional_attempts
  end

  def initialize(position:, env: ENV, venue_builder: HedgeVenues, signer_client: nil, timeout_seconds: nil, force: false, fresh_target_factory: nil)
    @position = position
    @env = env
    @venue_builder = venue_builder
    @signer_client = signer_client || ExtendedStarkSignerClient.new(env: env)
    @timeout_seconds = timeout_seconds || configured_timeout_seconds
    @force = force
    @fresh_target_factory = fresh_target_factory || ->(position) { HedgeFreshTarget.new(position: position, env: env) }
  end

  def refresh
    now = Time.current
    fresh_target = @fresh_target_factory.call(position).resolve(refresh_if_stale: true)
    target = fresh_target[:target_short_eth]
    tolerance_abs = target && position.hedge ? target * position.hedge.tolerance : nil
    venue_results = %w[extended ethereal nado].to_h { |venue| [ venue, read_venue(venue) ] }
    combined = combined_short(venue_results)
    drift = target && combined ? target - combined : nil
    errors = venue_results.each_with_object({}) do |(venue, result), memo|
      memo[venue] = result[:error] if result[:error].present?
      memo["#{venue}_optional"] = result[:optional_error] if result[:optional_error].present?
    end
    signer = read_signer_health
    errors[:signer] = signer[:error] if signer[:error].present?
    errors[:mellow_exposure] = fresh_target[:blockers].join("; ") if fresh_target[:blockers].present?
    derived_attrs = {
      production_venue: position.hedge&.execution_venue,
      target_short_eth: target,
      combined_short_eth: combined,
      drift_eth: drift,
      inside_tolerance: drift && tolerance_abs ? drift.abs <= tolerance_abs : nil
    }.merge(venue_attrs(venue_results))
    missing_critical = missing_critical_fields(derived_attrs)
    errors[:critical_derived_fields] = "missing critical migration fields: #{missing_critical.join(', ')}" if missing_critical.any?
    refresh_status = snapshot_status(venue_results, signer, missing_critical: missing_critical)

    attrs = {
      refreshed_at: now,
      refresh_status: refresh_status,
      stale: false,
      error_summary: errors.values.join("; ").presence,
      production_venue: derived_attrs[:production_venue],
      selected_venue: position.hedge&.execution_venue,
      target_short_eth: derived_attrs[:target_short_eth],
      tolerance_ratio: position.hedge&.tolerance,
      tolerance_abs_eth: tolerance_abs,
      combined_short_eth: derived_attrs[:combined_short_eth],
      drift_eth: derived_attrs[:drift_eth],
      inside_tolerance: derived_attrs[:inside_tolerance],
      extended_live_enabled: bool_env("EXTENDED_LIVE_ENABLED"),
      extended_auto_enabled: bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      ethereal_auto_enabled: bool_env("AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED"),
      nado_auto_enabled: bool_env("AERODROME_NADO_AUTO_REBALANCE_ENABLED"),
      signer_status: signer[:status],
      signer_checked_at: signer[:checked_at],
      timeout_seconds_used: timeout_seconds,
      source_errors: JSON.generate(errors)
    }.merge(derived_attrs.except(:production_venue, :target_short_eth, :combined_short_eth, :drift_eth, :inside_tolerance))

    position.create_position_dashboard_snapshot! unless position.position_dashboard_snapshot
    position.position_dashboard_snapshot.update!(attrs)
    position.position_dashboard_snapshot.reload
  end

  private

  attr_reader :position, :env, :venue_builder, :signer_client, :timeout_seconds

  def read_venue(venue)
    return not_configured_venue if venue_not_configured?(venue)

    adapter = venue_builder.build(venue)
    result = if venue == "extended"
      read_extended_venue(adapter)
    else
      read_standard_venue(venue, adapter)
    end
    result[:source_status] = "ok" if result[:source_status].blank?
    result
  rescue Timeout::Error => e
    carry_forward_venue_error(venue, e)
  rescue => e
    carry_forward_venue_error(venue, e)
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

  def read_standard_venue(venue, adapter)
    timed_read("#{venue} readback") do
      current_position = adapter.read_position(symbol: "ETH")
      normalize_venue_result(venue, current_position, {})
    end.fetch(:result)
  end

  def read_extended_venue(adapter)
    critical = timed_read("extended critical readback") { adapter.read_position(symbol: "ETH") }
    current_position = critical.fetch(:result)
    optional = read_extended_optional_account_state(adapter)
    account_state = optional.fetch(:result)
    normalize_venue_result("extended", current_position, account_state).merge(
      critical_read_duration_ms: critical.fetch(:duration_ms),
      critical_read_status: "ok",
      optional_read_duration_ms: optional.fetch(:duration_ms),
      optional_read_status: optional.fetch(:status)
    )
  rescue Timeout::Error, StandardError => e
    if defined?(critical) && critical&.dig(:result)
      previous_optional = previous_extended_optional_account_state(position.position_dashboard_snapshot)
      normalize_venue_result("extended", critical.fetch(:result), previous_optional).merge(
        critical_read_duration_ms: critical.fetch(:duration_ms),
        critical_read_status: "ok",
        optional_read_duration_ms: duration_ms_from(defined?(optional_started) ? optional_started : nil),
        optional_read_status: "error",
        optional_error: sanitized_error(e)
      )
    else
      raise
    end
  end

  def read_extended_optional_account_state(adapter)
    unless force_refresh? || extended_optional_due?
      previous = position.position_dashboard_snapshot
      Rails.logger.info("[DashboardSnapshotRefresh] section=extended optional account state skipped=true reason=throttled interval_seconds=#{extended_optional_interval_seconds}")
      return {
        result: previous_extended_optional_account_state(previous),
        duration_ms: nil,
        status: "skipped_throttled"
      }
    end

    timed_read("extended optional account state") { adapter.account_state || {} }.tap do
      write_extended_optional_attempt
    end
  rescue Timeout::Error, StandardError
    write_extended_optional_attempt
    raise
  end

  def previous_extended_optional_account_state(previous)
    return {} unless previous

    {
      open_orders_count: previous.open_orders_count_extended,
      margin_gate: { status: previous.leverage_margin_gate_status },
      account_value_usd: nil,
      collateral_usd: nil,
      market_metadata_available: nil
    }.compact
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

  def carry_forward_venue_error(venue, error)
    previous = position.position_dashboard_snapshot
    return venue_error(error) unless venue == "extended" && previous&.extended_short_eth

    {
      status: "error",
      source_status: "stale",
      short_eth: previous.extended_short_eth,
      notional_usd: previous.extended_notional_usd,
      entry_price: previous.extended_entry_price,
      mark_price: previous.extended_mark_price,
      unrealized_pnl_usd: previous.extended_unrealized_pnl_usd,
      leverage: previous.extended_leverage,
      effective_leverage: previous.extended_effective_leverage,
      margin_mode: previous.extended_margin_mode,
      open_orders_count: previous.open_orders_count_extended,
      leverage_margin_gate_status: previous.leverage_margin_gate_status,
      critical_read_duration_ms: nil,
      critical_read_status: "error_carried_forward",
      optional_read_duration_ms: nil,
      optional_read_status: "not_attempted",
      value_stale_as_of: previous.refreshed_at,
      error: "#{sanitized_error(error)}; carried forward previous Extended snapshot ##{previous.id}"
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
      extended_value_stale_as_of: results.dig("extended", :value_stale_as_of),
      extended_critical_read_duration_ms: results.dig("extended", :critical_read_duration_ms),
      extended_critical_read_status: results.dig("extended", :critical_read_status),
      extended_optional_read_duration_ms: results.dig("extended", :optional_read_duration_ms),
      extended_optional_read_status: results.dig("extended", :optional_read_status),
      extended_source_status: results.dig("extended", :source_status),
      ethereal_source_status: results.dig("ethereal", :source_status),
      nado_source_status: results.dig("nado", :source_status)
    }
  end

  def snapshot_status(results, signer, missing_critical: [])
    return "partial" if missing_critical.any?
    return "ok" if results.values.all? { |result| result[:source_status] == "ok" } && signer[:error].blank?
    return "error" if results.values.all? { |result| result[:source_status] == "error" }

    "partial"
  end

  def combined_short(results)
    values = results.values.map { |result| result[:short_eth] }
    return nil unless values.all?

    values.sum(BigDecimal("0"))
  end

  def target_short
    return nil unless position.asset0_amount && position.hedge

    position.asset0_amount * position.hedge.target
  end

  def missing_critical_fields(attrs)
    missing = []
    missing << "production_venue" if attrs[:production_venue].blank?
    missing << "target_short_eth" unless positive_decimal?(attrs[:target_short_eth])
    missing << "combined_short_eth" unless decimal_present?(attrs[:combined_short_eth])
    missing << "drift_eth" unless decimal_present?(attrs[:drift_eth])
    missing << "inside_tolerance" if attrs[:inside_tolerance].nil?
    missing << "extended_short_eth" unless decimal_present?(attrs[:extended_short_eth])
    missing << "ethereal_short_eth" unless decimal_present?(attrs[:ethereal_short_eth])
    missing << "nado_short_eth" unless decimal_present?(attrs[:nado_short_eth])
    missing
  end

  def decimal_present?(value)
    return false if value.nil?

    BigDecimal(value.to_s)
    true
  rescue ArgumentError
    false
  end

  def positive_decimal?(value)
    decimal_present?(value) && BigDecimal(value.to_s).positive?
  rescue ArgumentError
    false
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
    return OperationalSettings.enabled?(key, env: env) if OperationalSettings.allowed_key?(key)

    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def with_timeout(_name, &block)
    Timeout.timeout(timeout_seconds, &block)
  end

  def timed_read(name)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = with_timeout(name) { yield }
    duration = duration_ms_from(started)
    Rails.logger.info("[DashboardSnapshotRefresh] section=#{name} duration_ms=#{duration} timeout_seconds=#{timeout_seconds}")
    { result: result, duration_ms: duration, status: "ok" }
  rescue Timeout::Error => e
    Rails.logger.warn("[DashboardSnapshotRefresh] section=#{name} timed_out=true timeout_seconds=#{timeout_seconds}")
    raise e
  rescue => e
    Rails.logger.warn("[DashboardSnapshotRefresh] section=#{name} error=#{e.class} timeout_seconds=#{timeout_seconds}")
    raise e
  end

  def duration_ms_from(started)
    return nil unless started

    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end

  def configured_timeout_seconds
    Float(env.fetch("DASHBOARD_SNAPSHOT_VENUE_TIMEOUT_SECONDS", DEFAULT_TIMEOUT_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_TIMEOUT_SECONDS
  end

  def force_refresh?
    ActiveModel::Type::Boolean.new.cast(@force)
  end

  def extended_optional_due?
    last_attempt = Rails.cache.read(extended_optional_attempt_cache_key) || self.class.extended_optional_attempts[extended_optional_attempt_cache_key]
    return true if last_attempt.blank?

    Time.at(last_attempt.to_i) <= extended_optional_interval_seconds.seconds.ago
  end

  def extended_optional_attempt_cache_key
    "dashboard_snapshot:extended_optional_attempt:position:#{position.id}"
  end

  def write_extended_optional_attempt
    timestamp = Time.current.to_i
    self.class.extended_optional_attempts[extended_optional_attempt_cache_key] = timestamp
    Rails.cache.write(extended_optional_attempt_cache_key, timestamp, expires_in: extended_optional_interval_seconds.seconds)
  end

  def extended_optional_interval_seconds
    Integer(env.fetch("DASHBOARD_SNAPSHOT_EXTENDED_OPTIONAL_INTERVAL_SECONDS", DEFAULT_EXTENDED_OPTIONAL_INTERVAL_SECONDS.to_s))
  rescue ArgumentError
    DEFAULT_EXTENDED_OPTIONAL_INTERVAL_SECONDS
  end

  def sanitized_error(error)
    "#{error.class}: #{error.message.to_s.gsub(/Bearer\s+\S+/i, 'Bearer [REDACTED]').gsub(/0x[a-f0-9]{64,}/i, '[REDACTED_HEX]')}"
  end
end
