require "test_helper"

class VpsDeploymentFoundationTest < ActiveSupport::TestCase
  test "VPS helper scripts are executable and safe-scoped" do
    readiness = Rails.root.join("bin", "vps-readiness-check")
    watchdog = Rails.root.join("bin", "vps-watchdog-tick")
    backup = Rails.root.join("bin", "vps-backup-storage")
    production_status = Rails.root.join("bin", "vps-production-status")
    production_backup = Rails.root.join("bin", "vps-production-backup")
    post_run = Rails.root.join("bin", "vps-production-post-run-check")
    tail_log = Rails.root.join("bin", "vps-production-tail-latest-log")

    [ readiness, watchdog, backup, production_status, production_backup, post_run, tail_log ].each do |path|
      assert_predicate path, :exist?
      assert_predicate path, :executable?
    end

    assert_includes readiness.read, "aerodrome:production_supervised_readiness"
    assert_includes watchdog.read, "bin/aerodrome-watchdog-tick"
    assert_includes backup.read, "tar"
    assert_includes production_status.read, "aerodrome:production_supervised_readiness"
    assert_includes production_status.read, "aerodrome:production_live_status"
    assert_includes production_status.read, "aerodrome:approved_open_position"
    assert_includes production_status.read, "aerodrome:watchdog_alerts"
    assert_includes production_status.read, "get_position(\"ETH\")"
    assert_includes post_run.read, "aerodrome:production_live_status"
    assert_includes post_run.read, "aerodrome:approved_open_position"
    assert_includes post_run.read, "aerodrome:watchdog_alerts"
    assert_includes post_run.read, "get_position(\"ETH\")"
    assert_includes production_backup.read, "/root/delta_neutral_backups"
    assert_includes production_backup.read, "--exclude=\"./backups\""
    assert_includes production_backup.read, "--exclude=\"*/._*\""
    assert_includes tail_log.read, "storage/aerodrome_production_live/*.jsonl"
    refute_includes readiness.read, "live_observation_window"
    refute_includes watchdog.read, "live_emergency_close"
    refute_includes production_status.read, "production_live_run"
    refute_includes production_status.read, "live_emergency_close"
    refute_includes post_run.read, "production_live_run"
    refute_includes post_run.read, "live_emergency_close"
    refute_includes production_backup.read, "PRIVATE_KEY"
    refute_includes production_backup.read, "SECRET"
  end

  test "production command templates warn and do not auto execute live commands" do
    open_template = Rails.root.join("bin", "vps-production-open-run-template")
    close_template = Rails.root.join("bin", "vps-production-close-template")

    [ open_template, close_template ].each do |path|
      assert_predicate path, :exist?
      assert_predicate path, :executable?
      assert_includes path.read, "DO NOT RUN AUTOMATICALLY"
      assert_includes path.read, "copy/paste template only"
      refute_includes path.read, "exec bin/rails"
    end

    assert_includes open_template.read, "bin/rails aerodrome:production_live_run"
    assert_includes open_template.read, "<duration_seconds>"
    assert_includes open_template.read, "<max_eth_<=_0.02>"
    assert_includes close_template.read, "bin/rails aerodrome:live_emergency_close"
    assert_includes close_template.read, "check current mainnet ETH"
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
