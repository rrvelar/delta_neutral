class AerodromeHedgeProposal < ApplicationRecord
  STATUSES = %w[draft reviewed rejected expired].freeze

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
end
