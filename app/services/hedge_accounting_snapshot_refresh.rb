class HedgeAccountingSnapshotRefresh
  def initialize(position:)
    @position = position
  end

  def refresh
    snapshot = position.position_dashboard_snapshot
    venue = HedgeVenues.normalize(position.hedge&.execution_venue)
    report = accounting_report(snapshot, venue)
    components = report.fetch(:components, {})

    attrs = {
      refreshed_at: Time.current,
      refresh_status: report[:warnings].present? ? "partial" : "ok",
      venue: venue,
      current_short_eth: decimal_or_nil(report[:current_short_eth]),
      entry_price: decimal_or_nil(report[:entry_price]),
      mark_price: decimal_or_nil(report[:mark_price]),
      notional_usd: decimal_or_nil(report[:notional_usd]),
      unrealized_pnl_usd: decimal_or_nil(components.dig(:unrealized_pnl_usd, :value)),
      realized_pnl_usd: decimal_or_nil(components.dig(:realized_pnl_usd, :value)),
      trading_fees_usd: decimal_or_nil(components.dig(:trading_fees_usd, :value)),
      funding_usd: decimal_or_nil(components.dig(:funding_pnl_usd, :value)),
      borrow_interest_usd: decimal_or_nil(components.dig(:borrow_interest_usd, :value)),
      rebates_credits_usd: decimal_or_nil(components.dig(:rebates_or_credits_usd, :value)),
      net_hedge_pnl_usd: decimal_or_nil(report[:net_venue_pnl_usd]),
      unavailable_components: JSON.generate(Array(report[:unavailable_components])),
      source_errors: JSON.generate(report[:warnings].present? ? { accounting: report[:warnings].join("; ") } : {}),
      orders_submitted: 0,
      signatures_created: 0
    }

    position.create_position_hedge_accounting_snapshot! unless position.position_hedge_accounting_snapshot
    position.position_hedge_accounting_snapshot.update!(attrs)
    position.position_hedge_accounting_snapshot.reload
  end

  private

  attr_reader :position

  def accounting_report(snapshot, venue)
    current_position = current_position_from_snapshot(snapshot, venue)
    HedgeVenueAccounting.new(
      position: position,
      venue_key: venue,
      adapter: NullAccountingAdapter.new,
      current_position: current_position,
      account_state: {}
    ).report
  rescue => e
    {
      venue: venue,
      components: {},
      unavailable_components: HedgeVenueAccounting::COMPONENTS,
      warnings: [ "#{HedgeVenues.label(venue)} accounting snapshot unavailable: #{e.class}: #{e.message}" ]
    }
  end

  def current_position_from_snapshot(snapshot, venue)
    return nil unless snapshot

    case venue
    when "extended"
      short = decimal_or_nil(snapshot.extended_short_eth) || BigDecimal("0")
      {
        side: short.positive? ? "short" : nil,
        short_size: short,
        entry_price: snapshot.extended_entry_price,
        mark_price: snapshot.extended_mark_price,
        notional_usd: snapshot.extended_notional_usd,
        unrealized_pnl_usd: snapshot.extended_unrealized_pnl_usd,
        margin_mode: snapshot.extended_margin_mode
      }
    when "ethereal"
      short = decimal_or_nil(snapshot.ethereal_short_eth) || BigDecimal("0")
      { side: short.positive? ? "short" : nil, short_size: short, notional_usd: snapshot.ethereal_notional_usd }
    when "nado"
      short = decimal_or_nil(snapshot.nado_short_eth) || BigDecimal("0")
      { side: short.positive? ? "short" : nil, short_size: short, notional_usd: snapshot.nado_notional_usd }
    end
  end

  def decimal_or_nil(value)
    return nil if value.blank?

    BigDecimal(value.to_s)
  rescue ArgumentError
    nil
  end

  class NullAccountingAdapter
    def read_position(symbol:)
      nil
    end

    def account_state
      {}
    end
  end
end
