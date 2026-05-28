require "test_helper"

class MigrationRandomRotationDailyJobTest < ActiveJob::TestCase
  test "job exits disabled through runner when env gate is false" do
    calls = []
    fake_runner = Object.new
    fake_runner.define_singleton_method(:call) do |position_id: nil, force: false|
      calls << { position_id: position_id, force: force }
      MigrationRandomRotationDailyRunner::Result.new("disabled", [], [], [ "disabled" ], 0, 0)
    end

    MigrationRandomRotationDailyRunner.stub(:new, -> { fake_runner }) do
      MigrationRandomRotationDailyJob.perform_now(123, force: true)
    end

    assert_equal [ { position_id: 123, force: true } ], calls
  end
end
