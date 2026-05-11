# VPS Production Deployment Foundation

This document prepares a VPS deployment foundation for Aerodrome production supervised mode. It does not approve live trading, does not enable live trading, and does not create unattended 24/7 live operation.

The first VPS phase is read-only dashboard plus watchdog alerts only. Live observation on VPS requires a separate manual preflight, explicit one-off gates, and active supervision.

## Prerequisites

- Ubuntu/Debian VPS or equivalent Linux host.
- SSH access with a non-root deploy user.
- Docker Engine and Docker Compose plugin.
- Firewall access to only the required ports.
- A secure way to transfer `.env.production`.
- Backups for `storage/`.
- Operator access to Hyperliquid UI/API readback.

Recommended OS packages:

```bash
sudo apt-get update
sudo apt-get install -y git curl ca-certificates gnupg ufw tar
```

Install Docker using Docker's official instructions for the target OS. Confirm:

```bash
docker --version
docker compose version
```

## Repository Setup

Clone:

```bash
git clone <REPO_URL> /opt/delta_neutral
cd /opt/delta_neutral
```

Update:

```bash
git fetch --all --tags
git checkout <reviewed-branch-or-tag>
git pull --ff-only
```

Set deploy metadata in `.env.production`:

```bash
APP_GIT_SHA=$(git rev-parse --short HEAD)
```

In Docker images where `.git` is unavailable, `APP_GIT_SHA` is the readiness metadata fallback.

## Production Env

Use `docs/templates/vps-production-env-template.txt` as a template. Transfer the real `.env.production` securely; do not paste secrets into shell history, docs, tickets, or git.

Safe defaults must remain:

```bash
HYPERLIQUID_TESTNET=true
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
AERODROME_ALERTS_ENABLED=false
AERODROME_ALERTS_DELIVERY=dry_run
AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED=false
AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM=
AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.025
```

Required secrets/config are filled only on the VPS:

- Rails master key / secret key.
- Hyperliquid API wallet key and wallet address.
- RPC URLs and The Graph key.
- SMTP settings only if email alerts are explicitly enabled.

## Storage Backup And Restore

The production compose file bind-mounts local `./storage` into the container at `/rails/storage`. This directory contains SQLite/Solid Queue/Solid Cache data and observation/watchdog files.

Create a backup:

```bash
bin/vps-production-backup
```

The helper writes to `/root/delta_neutral_backups/storage-<timestamp>.tar.gz` by default, can be overridden with `BACKUP_DIR=/path`, excludes `storage/backups` and macOS AppleDouble files, and does not print secrets. If one previous bad backup exists inside `storage/backups` and is huge, delete it manually only after confirming a good backup exists outside `storage`.

Restore concept:

```bash
docker compose -f docker-compose.prod.yml down
tar -xzf storage/backups/<backup>.tar.gz -C storage
docker compose -f docker-compose.prod.yml up -d
```

Review restore commands before use and keep off-host copies.

## Docker Compose Start

Build and start:

```bash
docker compose -f docker-compose.prod.yml build
docker compose -f docker-compose.prod.yml up -d
```

Inspect:

```bash
docker compose -f docker-compose.prod.yml ps
docker compose -f docker-compose.prod.yml logs -f web
```

The compose file exposes `43080:80`. For public access, put a reverse proxy/TLS layer in front of it. For private access, bind to localhost or firewall the port to trusted IPs only.

## Dashboard Exposure And Firewall

Options:

- SSH tunnel only: keep the dashboard private and access with an SSH tunnel.
- Reverse proxy with TLS: expose through Nginx/Caddy/Traefik and restrict access.
- Direct port exposure: not recommended except behind firewall allowlists.

Firewall baseline:

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow from <trusted-ip> to any port 43080 proto tcp
sudo ufw enable
```

Adjust for your reverse proxy and monitoring setup.

## Verification Commands

Verify safe env inside the running container:

```bash
docker compose -f docker-compose.prod.yml exec web env | grep -E 'AERODROME_HEDGE_ENABLED|AERODROME_HEDGE_PAUSED|AERODROME_LIVE_APPROVED|HYPERLIQUID_TESTNET'
```

Expected safe state:

```bash
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

Run readiness:

```bash
docker compose -f docker-compose.prod.yml exec web bin/vps-readiness-check
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:production_supervised_readiness
```

Run watchdog checks:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:watchdog_check
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:watchdog_alerts
docker compose -f docker-compose.prod.yml exec web bin/vps-watchdog-tick
```

Mainnet/testnet ETH nil should be verified through the readiness/watchdog readbacks and independently in the Hyperliquid UI before any future live run.

## Watchdog Scheduler

Install systemd templates only after dry-run validation:

```bash
sudo cp deploy/systemd/aerodrome-watchdog.service.example /etc/systemd/system/aerodrome-watchdog.service
sudo cp deploy/systemd/aerodrome-watchdog.timer.example /etc/systemd/system/aerodrome-watchdog.timer
sudo systemctl daemon-reload
sudo systemctl enable --now aerodrome-watchdog.timer
```

The timer runs every 5 minutes and executes:

```bash
docker compose -f docker-compose.prod.yml exec -T web bin/vps-watchdog-tick
```

It runs watchdog alerts only. It does not start live observation, does not run emergency close, and does not close positions.

Logs:

```bash
journalctl -u aerodrome-watchdog.service
journalctl -u aerodrome-watchdog.timer
docker compose -f docker-compose.prod.yml logs web
```

Disable:

```bash
sudo systemctl disable --now aerodrome-watchdog.timer
```

On `WARN`, review the warning before future live windows. On `BLOCKED`, treat it as immediate operator attention: stop any supervised run, read mainnet ETH independently, and use manually gated emergency close only if ETH remains open.

## Logs

Relevant locations:

- Docker logs: `docker compose -f docker-compose.prod.yml logs web`
- Rails logs inside storage/container depending on deployment mode.
- Observation logs: `storage/aerodrome_live_observation/*.jsonl`
- Watchdog alert state: `storage/aerodrome_watchdog_alerts/state.json`
- Backups: `storage/backups/*.tar.gz`
- systemd journal: `journalctl -u aerodrome-watchdog.service`

## Future Manual Live Commands

These are not deployment approval and must not be scheduled.

Read-only live preflight:

```bash
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:live_preflight_check
```

Manual live observation later, only after separate preflight and explicit gates:

```bash
# DO NOT RUN FROM THIS DOC. Historical/procedure reference only.
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:live_observation_window
```

Manual production canary later, only after separate preflight and explicit one-off gates:

```bash
# DO NOT RUN FROM THIS DOC. Supervised canary procedure reference only.
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:production_canary_run
```

During a production canary, the runner uses canary-aware runtime safety instead of the generic safe-mode watchdog. The generic watchdog remains strict for persistent monitoring and should still block any unexpected mainnet ETH position when the VPS env is restored to disabled/paused/not-approved/testnet. A small ETH short within configured canary caps is expected only inside an explicitly gated canary run. Any successful USDC rebalance, failed WETH/ETH row, cap breach, readback failure, missing emergency close gate, inactive position/hedge, or previous canary `manual_action_required=true` remains a blocker. A previous non-nil canary final position is warning-only when current ETH readback is nil.

The first VPS canary created `ShortRebalance #190`, opened a `0.0108` ETH WETH hedge, stopped because the generic watchdog treated that expected canary short as `BLOCKED`, and then closed successfully. Final mainnet ETH was nil. A repeat canary still requires fresh readiness/preflight and manual approval.

The VPS canary runtime-safety retest passed after the canary-aware check was added. The 1-hour retest reported runtime safety `PASS` with no blockers or warnings, allowed the expected in-cap ETH short during the canary, completed with `stop_reason="duration complete"`, closed `0.0106` ETH on the first final-close attempt, and ended with final mainnet ETH nil and `manual_action_required=false`. This does not approve unattended operation. A longer supervised canary or production supervised mode step still requires explicit operator approval.

Production live runner V1 is a later manually launched step, not a VPS background service. It may leave ETH open only after clean duration completion and requires `bin/rails aerodrome:production_live_status` after every run. Do not add a systemd live runner service, scheduler, or UI start control without a separate approval. Watchdog scheduling remains read-only and must not start production live runs.

Production live V1 now has a higher supervised cap tier than the micro tools. Canary, observation, and target-step runs stay capped at `0.02` ETH / `$50`, but `production_live_run` may use explicitly configured caps up to `0.75` ETH and `$2000` notional at `1x`. For the first real direct Slipstream position on VPS, use `AERODROME_MAX_SHORT_ETH=0.55`, `AERODROME_MAX_SHORT_NOTIONAL_USD=1300`, and `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.60`. The VPS deploy still does not approve unattended 24/7 operation, and any cap increase beyond this tier requires separate review.

The first VPS Production Live Runner V1 run passed: 3600 seconds, 300 second interval, 12 iterations, one WETH rebalance, runtime safety `PASS`, no blockers/warnings, no USDC use, and clean duration completion with `position_left_open=true`, `final_position_confirmed=true`, `manual_action_required=false`, and status `success`. Mainnet ETH was later verified nil and emergency close returned noop. Safe env was restored. This does not approve a VPS live service; approved-open-position monitoring/watchdog is the next required safety step.

For VPS reruns, do not treat an old non-nil production live `final_position` as permanent proof of an open hedge. Run current Hyperliquid readback. If current ETH is nil, the old approved-open state is warning-only and a new explicitly gated run can proceed after preflight. If current ETH exists, is mismatched/out of caps, or cannot be read, stop and resolve before starting another live run.

For an adopt-existing VPS run, set `AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true` only when the current ETH short is the approved open hedge from the latest successful production live run and remains within caps. Strict readiness remains safe-mode evidence; the runner suppresses only the expected mainnet-ETH-non-nil blocker for an approved adopt-existing start. Any unrelated readiness blocker, unavailable readback, out-of-caps ETH, mismatch, or `manual_action_required=true` blocks the run. Emergency close remains manual and gated.

The VPS adopt-existing recovery workflow passed and is documented in `docs/AERODROME_ADOPT_EXISTING_RECOVERY_TEST_REPORT.md`. Step A opened WETH hedge `#198` and left ETH open. Step B adopted the approved ETH short with the explicit adopt gate, finished successfully, and left the position open by design. The volatility guard skipped a redundant rebalance because the last rebalance was within `600` seconds. The operator later ran the gated manual close and final mainnet ETH readback was nil.

Approved open position monitoring is read-only and does not make the VPS a live daemon. It allows watchdog/status to recognize a known valid ETH hedge from the latest successful production live log as intended state only while it remains within caps/tolerance. Unexpected ETH, cap breaches, failed WETH, successful USDC, unknown readback, or manual-action logs still require operator attention and may require manually gated emergency close.

Production readiness is still a strict safe-mode check. During an approved-open monitoring period, watchdog may suppress only the readiness blocker caused by the expected open ETH hedge and will report the suppressed readiness fields. Any unrelated readiness blocker still requires operator action.

If `production_live_status` reports `lock_state=stale_finished`, do not assume a runner is active. Verify with process listings/system logs, inspect the latest production live JSONL finish event, run current mainnet ETH readback, and only then remove `storage/aerodrome_production_live/run.lock` if it is stale. Emergency close remains manual and gated.

The VPS target-step test is not part of the scheduler. `bin/rails aerodrome:production_target_step_test` is live-capable and must only be run manually with explicit one-off gates after preflight. It temporarily changes the hedge target, requires the volatility guard, restores the target, and closes ETH at finish. Watchdog scheduling remains read-only and must not run this task.

The VPS target-step rebalance test passed and is documented in `docs/AERODROME_TARGET_STEP_REBALANCE_TEST_REPORT.md`. The volatility guard allowed the controlled up/down steps, WETH rebalances `#196` and `#197` succeeded, the target was restored, and final mainnet ETH was nil. This is operational evidence for supervised target-step testing only; it does not approve unattended 24/7 operation or automatic VPS live scheduling.

Production operator wrappers are documented in `docs/AERODROME_PRODUCTION_OPERATOR_COMMANDS.md`:

- `bin/vps-production-status` for read-only status/readback/watchdog checks.
- `bin/vps-production-backup` for timestamped VPS storage backups.
- `bin/vps-production-open-run-template` for a copy/paste production live run template only.
- `bin/vps-production-close-template` for a copy/paste emergency close template only.
- `bin/vps-production-post-run-check` for read-only post-run verification.
- `bin/vps-production-tail-latest-log` for read-only log tailing.

Run these scripts from `/opt/delta_neutral` on the VPS host. The host does not need Ruby installed; Rails commands run inside Docker with `docker compose -f docker-compose.prod.yml exec -T web ...`. The VPS is the production runtime and VPS `storage/` is production data. The Mac mini remains a development/operator station. Never run live from Mac and VPS at the same time.

For production-supervised live runs, keep the web container running and launch `production_live_run` from the printed template as a one-off Docker Compose runner container. Keep the dashboard/PnL available through the SSH tunnel while the run is active. Do not stop `web` as normal production flow; stop it only for debug or emergency maintenance.

The VPS approved-open watchdog retest passed and is documented in `docs/AERODROME_APPROVED_OPEN_WATCHDOG_VPS_RETEST_REPORT.md`. A 360 second production live run left an in-cap ETH short around `-0.0093` open by design. Approved-open monitoring reported `approved`, status reported `PASS`, and watchdog alerts reported `WARN` rather than `BLOCKED` because strict readiness was the only suppressed safe-mode signal. The operator then manually closed ETH through the gated emergency close, and final mainnet readback was nil. Future VPS production live runs remain supervised and require explicit gates; unattended 24/7 operation is not approved.

Manual live emergency close, only when explicitly gated:

```bash
# DO NOT RUN FROM THIS DOC. Emergency procedure reference only.
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:live_emergency_close
```

The watchdog scheduler must never run these live commands.

## Rollback

1. Stop scheduled watchdog if needed:
   ```bash
   sudo systemctl disable --now aerodrome-watchdog.timer
   ```
2. Stop app:
   ```bash
   docker compose -f docker-compose.prod.yml down
   ```
3. Checkout previous reviewed tag/commit:
   ```bash
   git checkout <previous-reviewed-tag>
   ```
4. Restore storage backup if needed.
5. Rebuild and start:
   ```bash
   docker compose -f docker-compose.prod.yml build
   docker compose -f docker-compose.prod.yml up -d
   ```
6. Run readiness and watchdog checks.

Rollback does not approve live trading.

## Incident Response

If watchdog reports `BLOCKED`:

1. Stop any supervised live run.
2. Verify mainnet ETH position in Hyperliquid UI/readback.
3. If ETH remains open, use the separate manually gated live emergency close or close manually in Hyperliquid UI.
4. Verify mainnet ETH nil.
5. Restore safe env defaults.
6. Preserve Docker, Rails, systemd, observation, and watchdog logs.
7. Create an incident note.
8. Do not restart live observation until reviewed.

## Final Statement

VPS deployment is infrastructure preparation only. It does not approve live trading, does not enable unattended operation, and does not change the requirement for separate manual preflight, explicit gates, active supervision, and emergency close readiness before any future live observation.
