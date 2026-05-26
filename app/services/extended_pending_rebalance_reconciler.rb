class ExtendedPendingRebalanceReconciler
  CONFIRMED_MESSAGE = "Extended order confirmed by delayed readback"

  def initialize(venue: HedgeVenues::Extended.new, size_increment: "0.001")
    @venue = venue
    @size_increment = BigDecimal(size_increment.to_s)
  end

  def reconcile_for_hedge(hedge)
    pending_rebalances(hedge).filter_map { |rebalance| reconcile(rebalance) }
  end

  def reconcile(rebalance)
    return unless rebalance.status == ShortRebalance::STATUS_PENDING && rebalance.venue == "extended"

    expected_short = expected_short_for(rebalance)
    return unless expected_short

    return mark_success(rebalance, expected_short) if later_row_confirms?(rebalance, expected_short)
    return mark_success(rebalance, expected_short) if receipt_confirms?(rebalance, expected_short)

    position = @venue.read_position(symbol: "ETH")
    current_short = short_size(position)
    return mark_success(rebalance, current_short) if matches?(current_short, expected_short, rebalance)

    nil
  end

  private

  def pending_rebalances(hedge)
    hedge.short_rebalances
      .where(venue: "extended", status: ShortRebalance::STATUS_PENDING)
      .order(:rebalanced_at, :id)
  end

  def expected_short_for(rebalance)
    expected_short_from_receipt(rebalance) || rebalance.new_short_size
  end

  def expected_short_from_receipt(rebalance)
    receipt = receipt_for(rebalance)
    raw = receipt["expected_short_eth"] ||
      receipt["expected_after_short_eth"] ||
      receipt.dig("submitted_order_summary", "expected_after_short_eth") ||
      receipt.dig("order_payload_summaries", 0, "expected_after_short_eth")
    return BigDecimal(raw.to_s) if raw.present?

    nil
  rescue ArgumentError
    nil
  end

  def receipt_confirms?(rebalance, expected_short)
    receipt = receipt_for(rebalance)
    readback = receipt["final_readback"] || receipt["post_submit_readback"]
    readback ||= Array(receipt["readback_attempts"]).reverse.find { |attempt| attempt["confirmed"] == true }
    return false unless readback.is_a?(Hash)

    matches?(short_size(readback), expected_short, rebalance)
  end

  def later_row_confirms?(rebalance, expected_short)
    rebalance.hedge.short_rebalances
      .where(venue: "extended")
      .where("id > ?", rebalance.id)
      .any? { |later| matches?(later.old_short_size, expected_short, rebalance) }
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

    event["hedge_id"].to_s == rebalance.hedge_id.to_s && event["venue"].to_s == "extended"
  end

  def mark_success(rebalance, confirmed_short)
    rebalance.update!(
      status: ShortRebalance::STATUS_SUCCESS,
      new_short_size: confirmed_short,
      message: CONFIRMED_MESSAGE,
      rebalanced_at: Time.current
    )
    rebalance
  end

  def matches?(actual, expected, rebalance)
    return false unless actual && expected

    (BigDecimal(actual.to_s) - BigDecimal(expected.to_s)).abs <= reconciliation_tolerance(rebalance, BigDecimal(expected.to_s))
  rescue ArgumentError
    false
  end

  def reconciliation_tolerance(rebalance, expected_short)
    hedge_tolerance = rebalance.hedge&.tolerance
    [ @size_increment, hedge_tolerance ? expected_short.abs * hedge_tolerance : BigDecimal("0") ].max
  end

  def short_size(position)
    return BigDecimal("0") unless position.is_a?(Hash)
    return BigDecimal(position[:short_size].to_s) if position[:short_size].present?
    return BigDecimal(position["short_size"].to_s) if position["short_size"].present?

    raw_size = position[:size] || position["size"]
    size = BigDecimal(raw_size.to_s)
    size.negative? ? size.abs : BigDecimal("0")
  rescue ArgumentError
    BigDecimal("0")
  end
end
