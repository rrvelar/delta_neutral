class HedgeVenueMigrationReceiptWriter
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_checks")

  def initialize(now: -> { Time.current }, receipt_dir: RECEIPT_DIR)
    @now = now
    @receipt_dir = Pathname(receipt_dir)
  end

  def write(receipt)
    FileUtils.mkdir_p(receipt_dir)
    path = receipt_dir.join("#{@now.call.utc.strftime('%Y%m%d')}.jsonl")
    record = sanitize_sensitive(receipt.merge(receipt_path: path.to_s))
    File.open(path, "a") { |file| file.puts(JSON.generate(record)) }
    path
  rescue SystemCallError => e
    Rails.logger.warn("Hedge migration receipt write failed: #{e.class}: #{e.message}")
    nil
  end

  private

  attr_reader :receipt_dir

  def sanitize_sensitive(value)
    case value
    when Hash
      value.to_h.each_with_object({}) do |(key, nested), sanitized|
        sanitized[key] = sensitive_key?(key) ? "<redacted>" : sanitize_sensitive(nested)
      end
    when Array
      value.map { |nested| sanitize_sensitive(nested) }
    else
      value
    end
  end

  def sensitive_key?(key)
    text = key.to_s
    return false if text == "confirmation_type"
    return false if text == "target_confirmation_source"
    return false if text == "signatures_created"

    text.match?(/api[_-]?key|private|authorization|cookie|signature|secret|confirmation/i)
  end
end
