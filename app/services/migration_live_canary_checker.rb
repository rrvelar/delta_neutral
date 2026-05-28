class MigrationLiveCanaryChecker
  RECEIPT_DIR = Rails.root.join("storage/hedge_migration_live_canaries")
  CONFIRMED_STATUS = "LIVE_CANARY_CONFIRMED".freeze

  def initialize(receipt_dir: RECEIPT_DIR)
    @receipt_dir = Pathname(receipt_dir)
  end

  def latest_for(from:, to:)
    events
      .select { |event| event["from_venue"] == from && event["to_venue"] == to }
      .max_by { |event| event["timestamp"].to_s }
  end

  def confirmed?(from:, to:)
    receipt = latest_for(from: from, to: to)
    valid_confirmed_receipt?(receipt)
  end

  def status_for(from:, to:)
    receipt = latest_for(from: from, to: to)
    {
      live_canary_confirmed: valid_confirmed_receipt?(receipt),
      latest_canary_status: receipt&.fetch("final_status", nil),
      latest_canary_receipt_path: receipt&.fetch("receipt_path", nil),
      blockers: valid_confirmed_receipt?(receipt) ? [] : [ "LIVE_CANARY_CONFIRMED receipt is required for #{from}->#{to}." ],
      orders_submitted: 0,
      signatures_created: 0
    }
  end

  private

  attr_reader :receipt_dir

  def valid_confirmed_receipt?(receipt)
    return false unless receipt

    receipt["final_status"] == CONFIRMED_STATUS &&
      receipt["mode"].to_s == "full" &&
      receipt["target_leg_readback_confirmed"] == true &&
      receipt["source_leg_readback_confirmed"] == true &&
      receipt["final_inside_tolerance"] == true &&
      receipt["source_flat_after"] == true &&
      receipt["target_holds_expected_short"] == true &&
      receipt["open_orders_after"].to_i.zero?
  end

  def events
    @events ||= Dir.glob(receipt_dir.join("*.jsonl")).flat_map do |path|
      File.readlines(path).filter_map do |line|
        JSON.parse(line).merge("receipt_path" => path)
      rescue JSON::ParserError
        nil
      end
    end
  rescue SystemCallError
    []
  end
end
