require "test_helper"

class VpsDeploymentFoundationTest < ActiveSupport::TestCase
  test "VPS helper scripts are executable and safe-scoped" do
    readiness = Rails.root.join("bin", "vps-readiness-check")
    watchdog = Rails.root.join("bin", "vps-watchdog-tick")
    backup = Rails.root.join("bin", "vps-backup-storage")

    [ readiness, watchdog, backup ].each do |path|
      assert_predicate path, :exist?
      assert_predicate path, :executable?
    end

    assert_includes readiness.read, "aerodrome:production_supervised_readiness"
    assert_includes watchdog.read, "bin/aerodrome-watchdog-tick"
    assert_includes backup.read, "tar"
    refute_includes readiness.read, "live_observation_window"
    refute_includes watchdog.read, "live_emergency_close"
  end

  test "systemd templates run watchdog tick only" do
    service = Rails.root.join("deploy", "systemd", "aerodrome-watchdog.service.example")
    timer = Rails.root.join("deploy", "systemd", "aerodrome-watchdog.timer.example")

    assert_predicate service, :exist?
    assert_predicate timer, :exist?
    assert_includes service.read, "bin/vps-watchdog-tick"
    assert_includes timer.read, "OnUnitActiveSec=5min"
    refute_includes service.read, "live_observation_window"
    refute_includes service.read, "live_emergency_close"
  end

  test "production env example keeps live gates safe and secrets blank" do
    template = Rails.root.join("docs/templates/vps-production-env-template.txt").read

    assert_includes template, "HYPERLIQUID_TESTNET=true"
    assert_includes template, "AERODROME_HEDGE_ENABLED=false"
    assert_includes template, "AERODROME_HEDGE_PAUSED=true"
    assert_includes template, "AERODROME_LIVE_APPROVED=false"
    assert_includes template, "AERODROME_ALERTS_ENABLED=false"
    assert_includes template, "AERODROME_ALERTS_DELIVERY=dry_run"
    assert_includes template, "AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED=false"
    assert_match(/^HYPERLIQUID_PRIVATE_KEY=$/, template)
    assert_match(/^RAILS_MASTER_KEY=$/, template)
  end
end
