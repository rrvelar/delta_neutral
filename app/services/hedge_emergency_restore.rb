class HedgeEmergencyRestore
  CONFIRMATION = "I_UNDERSTAND_THIS_RESTORES_LIVE_HEDGE".freeze
  RECEIPT_DIR = Rails.root.join("storage/hedge_emergency_restores")

  Result = Data.define(:status, :blockers, :warnings, :receipt)

  def initialize(position:, dry_run: nil, live: false, confirmation: nil, env: ENV, venue: nil, lifecycle_factory: nil, now: -> { Time.current }, receipt_dir: RECEIPT_DIR, explicit_position_id: true)
    @position = position
    @hedge = position.hedge
    @live = ActiveModel::Type::Boolean.new.cast(live)
    @dry_run = dry_run.nil? ? !@live : ActiveModel::Type::Boolean.new.cast(dry_run)
    @confirmation = confirmation.to_s
    @env = env
    @venue = venue || HedgeVenues::Extended.new(env: env)
    @lifecycle_factory = lifecycle_factory
    @now = now
    @receipt_dir = Pathname(receipt_dir)
    @explicit_position_id = explicit_position_id
  end

  def run
    context = build_context
    blockers = safety_blockers(context)
    execution = nil

    if live? && blockers.empty?
      execution = run_extended_restore(context)
      context = context.merge(final_extended_short: final_extended_short(execution), final_combined_short: final_combined_short(execution, context))
      blockers = Array(execution.blockers) unless execution.status == "success"
    end

    receipt = receipt_for(context: context, blockers: blockers, execution: execution)
    write_receipt(receipt)
    Result.new(receipt.fetch(:final_status), blockers, receipt.fetch(:warnings), receipt)
  rescue => e
    receipt = failure_receipt(e)
    write_receipt(receipt)
    Result.new(receipt.fetch(:final_status), receipt.fetch(:blockers), receipt.fetch(:warnings), receipt)
  end

  private

  attr_reader :position, :hedge, :confirmation, :env, :venue, :now, :receipt_dir

  def live?
    @live && !@dry_run
  end

  def build_context
    extended_position = venue.read_position(symbol: "ETH")
    extended_short = short_size(extended_position)
    snapshot = position.position_dashboard_snapshot
    ethereal_short = decimal_or_nil(snapshot&.ethereal_short_eth)
    nado_short = decimal_or_nil(snapshot&.nado_short_eth)
    target = target_short_eth
    tolerance = target && hedge ? target * BigDecimal(hedge.tolerance.to_s) : nil
    combined = combine_known(extended_short, ethereal_short, nado_short)
    order_size = target && combined ? [ target - extended_short, BigDecimal("0") ].max : nil
    preview = order_size&.positive? ? restore_preview(order_size: order_size, current_extended_short: extended_short) : nil

    {
      timestamp: now.call.utc.iso8601,
      production_venue: hedge&.execution_venue,
      extended_position_before: extended_position,
      current_extended_short: extended_short,
      current_ethereal_short: ethereal_short,
      current_nado_short: nado_short,
      target_short_eth: target,
      tolerance_eth: tolerance,
      combined_short_before: combined,
      drift_before: target && combined ? target - combined : nil,
      order_size_eth: order_size,
      preview: preview,
      rounded_size_eth: decimal_or_nil(preview&.dig(:payload, :rounded_size_eth)),
      eth_price_usd: eth_price,
      account_state: nil
    }
  end

  def safety_blockers(context)
    blockers = []
    blockers << "position_id must be explicitly provided" unless @explicit_position_id
    blockers << "position must be Aerodrome Slipstream" unless position.dex.name == "aerodrome_slipstream"
    blockers << "position must be active" unless position.active?
    blockers << "active hedge is required" unless hedge&.active?
    blockers << "production venue must be extended for emergency restore" unless context.fetch(:production_venue) == "extended"
    blockers << "target_short_eth is unavailable" unless context.fetch(:target_short_eth)&.positive?
    blockers << "current Ethereal short readback is unavailable" if context.fetch(:current_ethereal_short).nil?
    blockers << "current Nado short readback is unavailable" if context.fetch(:current_nado_short).nil?
    blockers.concat(underhedged_blockers(context))
    blockers.concat(cap_blockers(context))
    blockers.concat(preview_blockers(context))
    blockers.concat(live_gate_blockers(context)) if live?
    blockers.uniq
  end

  def underhedged_blockers(context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    combined = context.fetch(:combined_short_before)
    blockers = []
    return blockers unless target && tolerance && combined

    blockers << "position is not underhedged beyond tolerance" unless target - combined > tolerance
    blockers << "Ethereal has a conflicting short above tolerance" if context.fetch(:current_ethereal_short).to_d > tolerance
    blockers << "Nado has a conflicting short above tolerance" if context.fetch(:current_nado_short).to_d > tolerance
    blockers << "Extended current short is above target tolerance; emergency restore only increases shorts" if context.fetch(:current_extended_short) > target + tolerance
    blockers << "restore order size is zero or within tolerance" unless context.fetch(:order_size_eth)&.positive? && context.fetch(:order_size_eth) > tolerance
    blockers
  end

  def cap_blockers(context)
    target = context.fetch(:target_short_eth)
    order_size = context.fetch(:order_size_eth)
    price = context.fetch(:eth_price_usd)
    max_eth = decimal_env("AERODROME_MAX_SHORT_ETH")
    max_notional = decimal_env("AERODROME_MAX_SHORT_NOTIONAL_USD")
    min_notional = decimal_env("AERODROME_MIN_ORDER_NOTIONAL_USD")
    blockers = []
    blockers << "AERODROME_MAX_SHORT_ETH must be configured" unless max_eth
    blockers << "AERODROME_MAX_SHORT_NOTIONAL_USD must be configured" unless max_notional
    blockers << "AERODROME_MIN_ORDER_NOTIONAL_USD must be configured" unless min_notional
    blockers << "ETH price is unavailable for restore cap checks" unless price
    blockers << "target_short_eth exceeds AERODROME_MAX_SHORT_ETH" if target && max_eth && target > max_eth
    blockers << "target_short_eth notional exceeds AERODROME_MAX_SHORT_NOTIONAL_USD" if target && price && max_notional && target * price > max_notional
    blockers << "restore order notional is below AERODROME_MIN_ORDER_NOTIONAL_USD" if order_size && price && min_notional && order_size * price < min_notional
    blockers
  end

  def preview_blockers(context)
    preview = context.fetch(:preview)
    blockers = []
    blockers << "Extended restore preview unavailable" unless preview
    return blockers unless preview

    payload = preview.fetch(:payload, {})
    blockers << "restore order must be sell" unless payload[:side].to_s == "sell"
    blockers << "restore order must not be reduce-only" unless payload[:reduce_only] == false
    blockers.concat(Array(payload[:validation_blockers]))
    blockers
  end

  def live_gate_blockers(context)
    blockers = []
    blockers << "HEDGE_EMERGENCY_RESTORE_ENABLED must be true" unless bool_env("HEDGE_EMERGENCY_RESTORE_ENABLED")
    blockers << "submitted confirmation must equal #{CONFIRMATION}" unless confirmation == CONFIRMATION
    blockers << "EXTENDED_LIVE_ENABLED must be true" unless venue.live_enabled?
    blockers << "EXTENDED_MAINNET_PROBE_ENABLED must be true" unless bool_env("EXTENDED_MAINNET_PROBE_ENABLED")
    blockers << "EXTENDED_AUTO_REBALANCE_ENABLED must remain false during emergency restore" if bool_env("EXTENDED_AUTO_REBALANCE_ENABLED")

    account_state = venue.account_state
    context[:account_state] = account_state
    blockers << "Extended open_orders_count must be 0 for emergency restore" unless account_state[:open_orders_count].to_i.zero?
    blockers.concat(Array(account_state.dig(:margin_gate, :blockers)))
    blockers
  end

  def run_extended_restore(context)
    lifecycle.run(
      position: position,
      mode: context.fetch(:current_extended_short).positive? ? "rebalance_delta" : "open_only",
      size_eth: context.fetch(:order_size_eth),
      delta_eth: context.fetch(:current_extended_short).positive? ? context.fetch(:order_size_eth) : nil,
      confirmation: ExtendedMainnetLifecycleCheck::CONFIRMATION,
      dry_run: false,
      max_slippage: env.fetch("HEDGE_EMERGENCY_RESTORE_MAX_SLIPPAGE", "0.01")
    )
  end

  def lifecycle
    @lifecycle ||= begin
      lifecycle_env = env.to_h.merge("EXTENDED_PROBE_MAX_SIZE_ETH" => @last_order_size.to_s)
      if @lifecycle_factory
        @lifecycle_factory.call(lifecycle_env, venue)
      else
        ExtendedMainnetLifecycleCheck.new(env: lifecycle_env, venue: venue)
      end
    end
  end

  def restore_preview(order_size:, current_extended_short:)
    @last_order_size = order_size
    if current_extended_short.positive?
      venue.rebalance_preview(symbol: "ETH", delta_eth: order_size, max_slippage: env.fetch("HEDGE_EMERGENCY_RESTORE_MAX_SLIPPAGE", "0.01"))
    else
      venue.open_short_preview(symbol: "ETH", size_eth: order_size, max_slippage: env.fetch("HEDGE_EMERGENCY_RESTORE_MAX_SLIPPAGE", "0.01"))
    end
  end

  def receipt_for(context:, blockers:, execution:)
    final_extended = context[:final_extended_short] || context.fetch(:current_extended_short)
    final_combined = context[:final_combined_short] || context.fetch(:combined_short_before)
    inside = inside_tolerance?(final_combined, context)
    final_status = final_status(blockers: blockers, execution: execution, inside_tolerance: inside)
    {
      action: "hedge_emergency_restore",
      timestamp: context.fetch(:timestamp),
      position_id: position.id,
      hedge_id: hedge&.id,
      dry_run: !live?,
      live: live?,
      production_venue: context.fetch(:production_venue),
      current_venue_exposures: {
        extended: decimal_string(context.fetch(:current_extended_short)),
        ethereal: decimal_string(context.fetch(:current_ethereal_short)),
        nado: decimal_string(context.fetch(:current_nado_short))
      },
      target_short_eth: decimal_string(context.fetch(:target_short_eth)),
      combined_short_before: decimal_string(context.fetch(:combined_short_before)),
      drift_before: decimal_string(context.fetch(:drift_before)),
      tolerance_eth: decimal_string(context.fetch(:tolerance_eth)),
      order_size_eth: decimal_string(context.fetch(:order_size_eth)),
      rounded_size_eth: decimal_string(context.fetch(:rounded_size_eth)),
      side: "sell",
      reduce_only: false,
      live_gates: live_gates(context),
      preview_payload: context.dig(:preview, :payload)&.slice(:action, :side, :extended_side, :reduce_only, :requested_size_eth, :rounded_size_eth, :estimated_notional_usd, :validation_blockers),
      execution_receipt: sanitize_sensitive(execution&.receipt),
      submitted_order_id: execution&.receipt&.fetch(:exchange_order_id, nil),
      orders_submitted: execution&.receipt&.fetch(:orders_placed, 0).to_i,
      orders_placed: execution&.receipt&.fetch(:orders_placed, 0).to_i,
      signatures_created: execution&.receipt&.fetch(:signatures_created, 0).to_i,
      readback_confirmed: execution&.status == "success",
      final_extended_short: decimal_string(final_extended),
      final_combined_short: decimal_string(final_combined),
      inside_tolerance: inside,
      final_status: final_status,
      blockers: blockers,
      warnings: [ "Emergency restore bypasses Mellow/proposal/history gates but keeps live venue safety gates." ],
      receipt_path: receipt_path.to_s
    }
  end

  def final_status(blockers:, execution:, inside_tolerance:)
    return live? ? "RESTORE_BLOCKED" : "dry_run" if blockers.any?
    return "dry_run" unless live?

    execution&.status == "success" && inside_tolerance ? "RESTORE_CONFIRMED" : "RESTORE_MANUAL_ACTION_REQUIRED"
  end

  def live_gates(context)
    {
      hedge_emergency_restore_enabled: bool_env("HEDGE_EMERGENCY_RESTORE_ENABLED"),
      exact_confirmation: confirmation == CONFIRMATION,
      production_venue_extended: context.fetch(:production_venue) == "extended",
      extended_live_enabled: venue.live_enabled?,
      extended_mainnet_probe_enabled: bool_env("EXTENDED_MAINNET_PROBE_ENABLED"),
      extended_auto_rebalance_disabled: !bool_env("EXTENDED_AUTO_REBALANCE_ENABLED"),
      extended_open_orders_count: context[:account_state]&.dig(:open_orders_count),
      target_within_caps: cap_blockers(context).empty?
    }
  end

  def final_extended_short(execution)
    attempts = Array(execution.receipt[:readback_attempts])
    confirmed = attempts.reverse.find { |attempt| attempt[:confirmed] || attempt["confirmed"] }
    decimal_or_nil(confirmed&.fetch(:short_size, nil)) || short_size(venue.read_position(symbol: "ETH"))
  end

  def final_combined_short(execution, context)
    final_extended_short(execution) + context.fetch(:current_ethereal_short).to_d + context.fetch(:current_nado_short).to_d
  end

  def inside_tolerance?(combined, context)
    target = context.fetch(:target_short_eth)
    tolerance = context.fetch(:tolerance_eth)
    return nil unless target && tolerance && combined

    (target - combined).abs <= tolerance
  end

  def target_short_eth
    return nil unless position.asset0_amount && hedge&.target

    BigDecimal(position.asset0_amount.to_s) * BigDecimal(hedge.target.to_s)
  end

  def eth_price
    decimal_or_nil(position.asset0_price_usd) || decimal_or_nil(venue.market_metadata_diagnostics[:mark_price])
  end

  def short_size(position_payload)
    BigDecimal(position_payload&.fetch(:short_size, 0).to_s)
  rescue ArgumentError
    BigDecimal("0")
  end

  def combine_known(*values)
    return nil if values.any?(&:nil?)

    values.sum(BigDecimal("0"))
  end

  def decimal_env(key)
    decimal_or_nil(env[key])
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  def decimal_string(value)
    value.nil? ? nil : BigDecimal(value.to_s).to_s("F")
  rescue ArgumentError
    nil
  end

  def bool_env(key)
    ActiveModel::Type::Boolean.new.cast(env[key])
  end

  def receipt_path
    receipt_dir.join("#{now.call.utc.strftime('%Y%m%d')}.jsonl")
  end

  def write_receipt(receipt)
    FileUtils.mkdir_p(receipt_path.dirname)
    File.open(receipt_path, "a") { |file| file.puts(JSON.generate(receipt)) }
  end

  def failure_receipt(error)
    {
      action: "hedge_emergency_restore",
      timestamp: now.call.utc.iso8601,
      position_id: position.id,
      hedge_id: hedge&.id,
      dry_run: !live?,
      live: live?,
      orders_submitted: 0,
      orders_placed: 0,
      signatures_created: 0,
      final_status: "RESTORE_FAILED",
      blockers: [ "#{error.class}: #{error.message}" ],
      warnings: [],
      receipt_path: receipt_path.to_s
    }
  end

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = key.to_s.match?(/api[_-]?key|private|authorization|cookie|signature/i) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end
end
