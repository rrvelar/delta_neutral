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
bin/vps-backup-storage
```

The helper writes to `storage/backups/storage-<timestamp>.tar.gz` and does not print secrets.

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

Manual live emergency close, only when explicitly gated:

```bash
# DO NOT RUN FROM THIS DOC. Emergency procedure reference only.
docker compose -f docker-compose.prod.yml exec web bin/rails aerodrome:live_emergency_close
```

The watchdog scheduler must never run either live command.

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
