class MigrationRandomRotationDailyJob < ApplicationJob
  queue_as :default

  def perform(position_id = nil, force: false)
    result = MigrationRandomRotationDailyRunner.new.call(position_id: position_id, force: force)
    Rails.logger.info(
      "[MigrationRandomRotationDailyJob] status=#{result.status} " \
      "positions=#{result.positions.size} orders_submitted=#{result.orders_submitted} " \
      "signatures_created=#{result.signatures_created}"
    )
  end
end
