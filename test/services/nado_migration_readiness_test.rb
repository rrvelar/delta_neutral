require "test_helper"

class NadoMigrationReadinessTest < ActiveSupport::TestCase
  test "readiness is read only and blocked until implemented" do
    report = NadoMigrationReadiness.new.report

    assert_equal "not_implemented", report.fetch(:status)
    assert_equal false, report.fetch(:nado_position_read_available)
    assert_equal false, report.fetch(:nado_open_short_supported)
    assert_includes report.fetch(:blockers), "Nado migration readiness is not proven."
    assert_equal 0, report.fetch(:orders_submitted)
    assert_equal 0, report.fetch(:signatures_created)
  end
end
