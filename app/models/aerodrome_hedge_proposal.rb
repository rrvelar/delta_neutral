class AerodromeHedgeProposal < ApplicationRecord
  STATUSES = %w[draft reviewed rejected expired].freeze
  STALE_THRESHOLD = BigDecimal("0.005")

  belongs_to :position

  validates :status, inclusion: { in: STATUSES }
  validates :hedge_asset, :hedge_side, :source, :generated_at, presence: true
  validates :suggested_short_amount, :suggested_short_notional_usd,
    :lp_total_value_usd, :weth_price_usd,
    numericality: { greater_than_or_equal_to: 0 }
  validates :execution_enabled, exclusion: { in: [ true ], message: "must remain false for manual proposals" }
  validates :hyperliquid_called, exclusion: { in: [ true ], message: "must remain false for manual proposals" }

  scope :draft, -> { where(status: "draft") }
  scope :latest_first, -> { order(generated_at: :desc, created_at: :desc) }

  def mark_reviewed!
    update!(status: "reviewed", reviewed_at: Time.current)
  end

  def reject!(notes: nil)
    attributes = { status: "rejected", reviewed_at: Time.current }
    attributes[:notes] = notes if notes.present?
    update!(attributes)
  end

  def stale?(current_position = position)
    stale_reasons(current_position).any?
  end

  def stale_reasons(current_position = position)
    reasons = []
    reasons << "proposal rejected/expired" if %w[rejected expired].include?(status)
    reasons << "position inactive" unless current_position.active?
    reasons << "amount changed" if materially_changed?(current_weth_amount(current_position), suggested_short_amount)
    reasons << "notional changed" if materially_changed?(current_short_notional(current_position), suggested_short_notional_usd)
    reasons
  end

  def freshness_label(current_position = position)
    stale?(current_position) ? "Stale" : "Current"
  end

  private

  def current_weth_amount(current_position)
    if current_position.asset0.to_s.upcase == "WETH"
      current_position.asset0_amount
    elsif current_position.asset1.to_s.upcase == "WETH"
      current_position.asset1_amount
    end
  end

  def current_weth_price(current_position)
    if current_position.asset0.to_s.upcase == "WETH"
      current_position.asset0_price_usd
    elsif current_position.asset1.to_s.upcase == "WETH"
      current_position.asset1_price_usd
    end
  end

  def current_short_notional(current_position)
    amount = current_weth_amount(current_position)
    price = current_weth_price(current_position)
    return nil if amount.nil? || price.nil?

    amount * price
  end

  def materially_changed?(current_value, proposed_value)
    return true if current_value.nil? || proposed_value.nil?
    return current_value.abs > 0 if proposed_value.zero?

    ((current_value - proposed_value).abs / proposed_value.abs) > STALE_THRESHOLD
  end
end
