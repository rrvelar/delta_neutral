# Aerodrome Watchdog Scheduler

This document describes a safe scheduler foundation for periodic Aerodrome watchdog alert checks. It does not enable live trading, does not close positions, does not start live observation windows, and does not replace the manually gated emergency close procedure.

## What Runs

The scheduler should run only:

```bash
bin/aerodrome-watchdog-tick
```

The script changes into the app directory and runs:

```bash
bin/rails aerodrome:watchdog_alerts
```

`aerodrome:watchdog_alerts` is read-only. It reports watchdog status and optionally sends gated email alerts. It does not call live observation, emergency close, Hyperliquid order methods, or Aerodrome transactions.

## Scheduler Readiness Check

Run:

```bash
bin/rails aerodrome:watchdog_scheduler_check
FORMAT=json bin/rails aerodrome:watchdog_scheduler_check
```

The check is read-only and verifies:

- `aerodrome:watchdog_alerts` task exists.
- production supervised readiness task exists.
- alert env state and redacted email recipient.
- safe persistent env remains disabled, paused, not approved, and testnet.
- mainnet ETH position is nil by read-only Hyperliquid readback.
- latest observation summary is safe.

## Frequency

Recommended frequency is every 5 minutes during production supervised monitoring. More frequent polling should be separately reviewed because it increases readback/API traffic without closing positions automatically.

## Local Mac Usage

Manual tick:

```bash
bin/aerodrome-watchdog-tick
```

Dry-run test:

```bash
AERODROME_ALERTS_ENABLED=false AERODROME_ALERTS_DELIVERY=dry_run bin/aerodrome-watchdog-tick
```

Email delivery test without live trading:

```bash
AERODROME_ALERTS_ENABLED=true \
AERODROME_ALERTS_DELIVERY=email \
AERODROME_ALERT_EMAIL_RECIPIENT=operator@example.com \
AERODROME_ALERT_EMAIL_MIN_SEVERITY=warn \
bin/aerodrome-watchdog-tick
```

SMTP must be configured separately through the app's Rails Action Mailer SMTP environment variables. This sends only watchdog alert email; it does not close or open positions.

Scheduled email delivery deduplicates repeated identical alerts using:

```bash
storage/aerodrome_watchdog_alerts/state.json
```

Defaults:

```bash
AERODROME_ALERT_EMAIL_COOLDOWN_SECONDS=1800
AERODROME_ALERT_EMAIL_REPEAT_BLOCKED_SECONDS=300
```

Warnings repeat only after the cooldown unless the alert fingerprint changes. Blocked alerts repeat on the shorter blocked interval. Dry-run mode does not write alert state. To reset state after operator review:

```bash
rm storage/aerodrome_watchdog_alerts/state.json
```

## Docker Compose

Run one tick from the host:

```bash
docker compose exec web bin/aerodrome-watchdog-tick
```

If the production service name is not `web`, replace it with the correct app container name. The command should run in the existing app container so it uses the same Rails environment and configured env file.

## systemd Timer Template

These are operator-reviewed templates. Confirm paths, user, compose command, and environment handling before installing.

`/etc/systemd/system/aerodrome-watchdog.service`:

```ini
[Unit]
Description=Aerodrome watchdog alert tick

[Service]
Type=oneshot
WorkingDirectory=/opt/delta_neutral
ExecStart=/opt/delta_neutral/bin/aerodrome-watchdog-tick
```

`/etc/systemd/system/aerodrome-watchdog.timer`:

```ini
[Unit]
Description=Run Aerodrome watchdog alert tick every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true
Unit=aerodrome-watchdog.service

[Install]
WantedBy=timers.target
```

Enable only after dry-run validation:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now aerodrome-watchdog.timer
```

Disable:

```bash
sudo systemctl disable --now aerodrome-watchdog.timer
```

Logs:

```bash
journalctl -u aerodrome-watchdog.service
journalctl -u aerodrome-watchdog.timer
```

## Cron Alternative

Example:

```cron
*/5 * * * * cd /opt/delta_neutral && bin/aerodrome-watchdog-tick >> log/aerodrome-watchdog.log 2>&1
```

Cron does not provide the same unit state as systemd timers. Confirm shell, PATH, env loading, and log rotation before relying on it.

## Safe Env Expectations

Outside an explicitly approved supervised live run:

```bash
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

Alert defaults:

```bash
AERODROME_ALERTS_ENABLED=false
AERODROME_ALERTS_DELIVERY=dry_run
AERODROME_ALERT_EMAIL_MIN_SEVERITY=warn
```

## On WARN

Review the warning and fix the underlying read-only issue before another live window. Common warnings include stale PnL snapshot, unavailable rewards, unavailable fees, missing observation log, or missing email recipient while email mode is selected.

## On BLOCKED

Treat `BLOCKED` as immediate operator attention:

1. Stop any supervised live run.
2. Read mainnet ETH position independently.
3. If ETH remains open, use the separate manually gated live emergency close procedure or close manually in Hyperliquid UI.
4. Verify mainnet ETH nil.
5. Restore safe env defaults.
6. Preserve logs.
7. Do not start another live window until the blocker is reviewed.

The scheduler does not auto-close positions. Emergency close remains separate and manually gated.

For VPS deployment details, Docker Compose startup, secure env transfer, firewalling, backups, rollback, and incident response, see `docs/VPS_PRODUCTION_DEPLOYMENT.md`. The VPS phase starts with read-only dashboard/watchdog only; live observation on the VPS requires separate manual preflight and explicit gates.
