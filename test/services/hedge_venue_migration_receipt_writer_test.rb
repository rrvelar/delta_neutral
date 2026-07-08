require "test_helper"

class HedgeVenueMigrationReceiptWriterTest < ActiveSupport::TestCase
  setup do
    @dir = Rails.root.join("tmp/receipt-writer-#{SecureRandom.hex(4)}")
  end

  teardown { FileUtils.rm_rf(@dir) }

  def write_and_read(receipt)
    path = HedgeVenueMigrationReceiptWriter.new(receipt_dir: @dir).write(receipt)
    JSON.parse(File.read(path).strip.lines.last)
  end

  test "surfaces non-sensitive confirmation-source diagnostics unredacted" do
    record = write_and_read(
      double_exposure_start_source: "authoritative_fill",
      double_exposure_end_source: "authoritative_fill",
      target_open_confirmation_source: "ethereal_order_list_open_fill",
      source_close_confirmation_source: "extended_order_by_id_fill",
      readback_confirmation_source: "extended_order_by_id_fill",
      target_confirmation_source: "position_readback",
      confirmation_type: "manual_live_canary_confirmation"
    )

    assert_equal "authoritative_fill", record["double_exposure_start_source"]
    assert_equal "authoritative_fill", record["double_exposure_end_source"]
    assert_equal "ethereal_order_list_open_fill", record["target_open_confirmation_source"]
    assert_equal "extended_order_by_id_fill", record["source_close_confirmation_source"]
    assert_equal "extended_order_by_id_fill", record["readback_confirmation_source"]
    assert_equal "position_readback", record["target_confirmation_source"]
    assert_equal "manual_live_canary_confirmation", record["confirmation_type"]
  end

  test "still redacts secrets and generic confirmation material" do
    record = write_and_read(
      api_key: "SECRET",
      apiKey: "SECRET",
      signature: "0xdeadbeef",
      private_key: "0xpriv",
      authorization: "Bearer x",
      required_confirmation_phrase: "I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY",
      nested: { signature: "0xsig", source_close_confirmation_source: "extended_order_by_id_fill" }
    )

    %w[api_key apiKey signature private_key authorization required_confirmation_phrase].each do |k|
      assert_equal "<redacted>", record[k], k
    end
    # redaction still recurses into nested hashes, but the non-sensitive diagnostic survives.
    assert_equal "<redacted>", record.dig("nested", "signature")
    assert_equal "extended_order_by_id_fill", record.dig("nested", "source_close_confirmation_source")
  end
end
