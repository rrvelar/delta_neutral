# Represents a liquidity pool position held in a user's {Wallet}.
#
# A position tracks two assets (+asset0+ / +asset1+), their current amounts,
# and their USD prices as fetched from the Uniswap subgraph. Positions may
# optionally have a {Hedge} for delta-neutral management.
class Position < ApplicationRecord
  SOURCE_AERODROME_DIRECT = "aerodrome_direct"
  SOURCE_MELLOW_AUTOPILOT = "mellow_autopilot"
  SUPPORTED_SOURCES = [ SOURCE_AERODROME_DIRECT, SOURCE_MELLOW_AUTOPILOT ].freeze
  MULTIPLE_ACTIVE_HEDGEABLE_MESSAGE = "Multiple active hedgeable positions detected. This app currently supports one active hedge target; deactivate extras before live hedge sync."

  belongs_to :user
  belongs_to :dex
  belongs_to :wallet

  has_one :hedge, dependent: :destroy
  has_many :pnl_snapshots, dependent: :destroy
  has_many :aerodrome_hedge_proposals, dependent: :destroy

  # @!scope class
  # @!method active
  #   Returns only positions that are currently active.
  #   @return [ActiveRecord::Relation<Position>]
  scope :active, -> { where(active: true) }
  scope :active_hedgeable, -> { active.joins(:hedge, :dex).where(hedges: { active: true }, dexes: { name: "aerodrome_slipstream" }) }

  validates :source, inclusion: { in: SUPPORTED_SOURCES }, allow_nil: true

  # Calculates the total USD value of both assets in this position.
  #
  # Treats +nil+ amounts or prices as zero.
  #
  # @return [BigDecimal] the sum of (asset0_amount * asset0_price_usd) and
  #   (asset1_amount * asset1_price_usd)
  def total_value_usd
    ((asset0_amount || 0) * (asset0_price_usd || 0)) + ((asset1_amount || 0) * (asset1_price_usd || 0))
  end

  def position_source
    source.presence || SOURCE_AERODROME_DIRECT
  end

  def aerodrome_direct?
    position_source == SOURCE_AERODROME_DIRECT
  end

  def mellow_autopilot?
    position_source == SOURCE_MELLOW_AUTOPILOT
  end

  def source_label
    mellow_autopilot? ? "Mellow Autopilot shared strategy" : "Direct Aerodrome Slipstream LP"
  end

  def mellow_metadata_hash
    JSON.parse(mellow_metadata.presence || "{}")
  rescue JSON::ParserError
    {}
  end

  def mellow_metadata_hash=(value)
    self.mellow_metadata = JSON.generate(value || {})
  end

  def hedge_ready?
    return true unless mellow_autopilot?

    metadata = mellow_metadata_hash
    metadata["hedge_ready"] == true && metadata["last_probe_confidence"].present? && asset0_amount.present?
  end

  def self.multiple_active_hedgeable_blocker(excluding: nil)
    relation = active_hedgeable
    relation = relation.where.not(id: excluding.id) if excluding&.persisted?
    relation.count > 0 ? MULTIPLE_ACTIVE_HEDGEABLE_MESSAGE : nil
  end
end
