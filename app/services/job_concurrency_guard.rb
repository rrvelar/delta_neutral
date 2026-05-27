class JobConcurrencyGuard
  @mutex = Mutex.new
  @locks = {}

  class << self
    def with_lock(key)
      acquired = acquire(key)
      return false unless acquired

      yield
      true
    ensure
      release(key) if acquired
    end

    def locked?(key)
      @mutex.synchronize { @locks.key?(key) }
    end

    private

    def acquire(key)
      @mutex.synchronize do
        return false if @locks[key]

        @locks[key] = true
      end
    end

    def release(key)
      @mutex.synchronize { @locks.delete(key) }
    end
  end
end
