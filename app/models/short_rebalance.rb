# Records a single hedge rebalancing event for a {Hedge}.
#
# Created by {HedgeSyncJob} whenever a short position is adjusted. Stores
# the before and after sizes and the realized P&L captured from Hyperliquid
# fill data at the time of the rebalance.
class ShortRebalance < ApplicationRecord
  STATUS_SUCCESS = "success"
  STATUS_FAILED = "failed"
  STATUS_PENDING = "pending"
  STATUS_STALE_ACKNOWLEDGED = "stale_acknowledged"
  STATUS_STALE_SUPERSEDED = "stale_superseded"
  STATUS_OPERATOR_REVIEWED_STALE = "operator_reviewed_stale"
  STALE_PENDING_STATUSES = [
    STATUS_STALE_ACKNOWLEDGED,
    STATUS_STALE_SUPERSEDED,
    STATUS_OPERATOR_REVIEWED_STALE
  ].freeze

  belongs_to :hedge

  validates :venue, inclusion: { in: Hedge::EXECUTION_VENUES }
end
