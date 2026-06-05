class MigrationExecutionLock
  def self.key(position)
    "migration_execution:position:#{position.id}"
  end

  def self.with_lock(position)
    JobConcurrencyGuard.with_lock(key(position)) { yield }
  end

  def self.locked?(position)
    JobConcurrencyGuard.locked?(key(position))
  end
end
