# Aerodrome Production Operator Commands

## Scope

This command pack is for supervised production v1 operation on the VPS. It provides safer operator wrappers around existing read-only checks, backups, and copy/paste templates.

The VPS is the production runtime. The Mac mini is the development and operator station. GitHub is the source of truth for code. VPS `storage/` is the source of truth for production data and JSONL run history.

These scripts do not enable live trading by default, do not schedule the live runner, do not add UI controls, and do not weaken emergency close gates.

Run these scripts from `/opt/delta_neutral` on the VPS host. The VPS host does not need Ruby installed. Rails commands are executed inside the Docker Compose `web` container through `docker compose -f docker-compose.prod.yml exec -T web ...`.

## Command Summary

`bin/vps-production-status`

- read-only;
- runs production readiness, production live status, approved-open monitoring, watchdog alerts, and mainnet ETH readback;
- does not close positions and does not place orders.

`bin/vps-production-backup`

- creates a timestamped `storage/` archive;
- defaults to `/root/delta_neutral_backups`;
- can use `BACKUP_DIR=/path`;
- excludes nested storage backups and macOS AppleDouble files;
- does not print secrets.

If an earlier bad backup was written inside `storage/backups` and grew large, delete it manually only after confirming a good backup exists under `/root/delta_neutral_backups`.

`bin/vps-production-open-run-template`

- prints a supervised `production_live_run` command template only;
- does not execute the command;
- prints a Docker Compose command for the `web` container, not a host Ruby command;
- includes placeholders for duration, interval, max ETH, max notional, and leave-position-open mode;
- operator must copy/paste manually inside `tmux` after preflight and review.

`bin/vps-production-close-template`

- prints a gated `live_emergency_close` command template only;
- does not execute the close;
- prints a Docker Compose command for the `web` container, not a host Ruby command;
- operator must check current mainnet ETH first.

`bin/vps-production-post-run-check`

- read-only;
- runs mainnet ETH readback, production live status, approved-open monitoring, watchdog alerts, and safe env check;
- does not close positions and does not place orders.

`bin/vps-production-tail-latest-log`

- read-only;
- tails the latest production live JSONL log and latest app log if present;
- does not call Hyperliquid.

## Required Operator Pattern

Before a supervised run:

1. Pull/deploy the intended GitHub revision on the VPS.
2. `cd /opt/delta_neutral`.
3. Run `bin/vps-production-status`.
4. Run `bin/vps-production-backup`.
5. Confirm mainnet ETH state and approved-open state.
6. Print the command with `bin/vps-production-open-run-template`.
7. Copy/paste only after manual review and explicit approval.

After a supervised run:

1. Run `bin/vps-production-post-run-check`.
2. Run `bin/vps-production-backup`.
3. Inspect watchdog output.
4. If ETH is intentionally approved-open, keep monitoring.
5. If ETH is unexpected, unsafe, or out of caps, use the separate manually gated emergency close template.

## VPS Restart

After a VPS restart:

1. Run `bin/vps-production-status`.
2. Check mainnet ETH readback.
3. Check `aerodrome:production_live_status`.
4. Check `aerodrome:approved_open_position`.
5. Decide manually whether to continue monitoring, adopt in a separately approved future flow, or close with the gated emergency close.

A restart is not approval to start a new live run.

## SSH Disconnect

Run supervised live commands inside `tmux`. If SSH disconnects:

1. Reconnect.
2. Reattach to `tmux`.
3. Run `bin/vps-production-tail-latest-log`.
4. Run `bin/vps-production-status`.
5. Check mainnet ETH immediately.

If the run is unknown, BLOCKED, or manual action is required, do not start another run. Inspect logs and close manually only through the gated emergency close if needed.

## BLOCKED Handling

If any command reports `BLOCKED`:

1. Do not start a new live run.
2. Inspect blockers.
3. Check mainnet ETH directly.
4. If ETH is open and unsafe/unexpected, use the separate manually gated emergency close or close manually in Hyperliquid UI.
5. Do not clear logs, delete history, or rerun live until the blocker is understood.

Watchdog and approved-open monitoring are read-only. They do not close positions.

## Never Do

- Never run live from the Mac and VPS at the same time.
- Never schedule `production_live_run` without a separate implementation and approval.
- Never let watchdog close positions.
- Never bypass emergency close gates.
- Never store secrets in docs, shell history, tickets, or git.
