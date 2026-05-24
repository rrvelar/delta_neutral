class NadoPendingRebalanceReconciler
  CONFIRMED_MESSAGE = "Confirmed by later Nado readback"
  CONFLICT_MESSAGE = "Nado pending readback conflicts with expected final short; keeping pending for operator review."

  def initialize(service: NadoHedgeExecutionService.new, size_increment: ENV.fetch("NADO_SIZE_INCREMENT", "0.001"))
    @service = service
    @size_increment = BigDecimal(size_increment.to_s)
  end

  def reconcile_for_hedge(hedge)
    pending_rebalances(hedge).filter_map { |rebalance| reconcile(rebalance) }
  end

  def reconcile(rebalance)
    return unless rebalance.status == ShortRebalance::STATUS_PENDING && rebalance.venue == "nado"

    expected_short = expected_short_for(rebalance)
    return unless expected_short

    readback = @service.read_position
    return if readback == :unavailable

    current_size = position_size(readback)
    if current_size.positive?
      rebalance.update!(message: "Nado pending readback found a long ETH-PERP position; manual action required.")
      return rebalance
    end

    current_short = current_size.negative? ? current_size.abs : BigDecimal("0")
    tolerance = reconciliation_tolerance(rebalance, expected_short)
    if (current_short - expected_short).abs <= tolerance
      rebalance.update!(
        status: ShortRebalance::STATUS_SUCCESS,
        new_short_size: current_short,
        message: CONFIRMED_MESSAGE,
        rebalanced_at: Time.current
      )
      return rebalance
    end

    rebalance.update!(message: CONFLICT_MESSAGE)
    rebalance
  end

  private

  def pending_rebalances(hedge)
    hedge.short_rebalances
      .where(venue: "nado", status: ShortRebalance::STATUS_PENDING)
      .order(:rebalanced_at, :id)
  end

  def expected_short_for(rebalance)
    from_receipt = expected_short_from_receipt(rebalance)
    return from_receipt if from_receipt

    rebalance.new_short_size
  end

  def expected_short_from_receipt(rebalance)
    receipt = receipt_for(rebalance)
    raw = receipt["expected_after_short_eth"] ||
      receipt.dig("action_plan", "expected_after_short_eth") ||
      receipt.dig("submitted_order_summary", "expected_after_short_eth")
    return BigDecimal(raw.to_s) if raw.present?

    pre = receipt["pre_submit_readback"] || receipt["before_readback"]
    delta = receipt.dig("action_plan", "delta_eth")
    return unless pre && delta

    short_size_from_hash(pre) + BigDecimal(delta.to_s)
  rescue ArgumentError
    nil
  end

  def receipt_for(rebalance)
    return {} if rebalance.receipt_path.blank?

    path = Pathname.new(rebalance.receipt_path)
    return {} unless path.file?

    File.foreach(path).filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end.reverse.find { |event| receipt_matches_rebalance?(event, rebalance) } || {}
  end

  def receipt_matches_rebalance?(event, rebalance)
    return false unless event.is_a?(Hash)
    return true if rebalance.exchange_order_id.present? && event["exchange_order_id"].to_s == rebalance.exchange_order_id.to_s

    event["hedge_id"].to_s == rebalance.hedge_id.to_s && event["venue"].to_s == "nado"
  end

  def reconciliation_tolerance(rebalance, expected_short)
    hedge_tolerance = rebalance.hedge&.tolerance
    [ @size_increment, hedge_tolerance ? expected_short.abs * hedge_tolerance : BigDecimal("0") ].max
  end

  def position_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)

    BigDecimal(position.fetch(:size).to_s)
  rescue
    BigDecimal("0")
  end

  def short_size_from_hash(position)
    size = position_size(position)
    size.negative? ? size.abs : BigDecimal("0")
  end
end
