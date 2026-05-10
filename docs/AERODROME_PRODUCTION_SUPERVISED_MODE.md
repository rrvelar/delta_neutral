# Aerodrome Production Supervised Mode

This document defines the next operational stage after the successful 3-hour supervised live observation window. It is documentation and read-only readiness tooling guidance. It does not enable live trading, does not add unattended automation, and does not approve larger size.

## Definition

Production supervised mode is a manually approved, actively watched live operation window for the Aerodrome WETH/USDC hedge path. It uses the existing gated Aerodrome HedgeSyncJob path, existing HyperliquidService, and existing live emergency close tooling.

Production supervised mode is not:

- unattended 24/7 automation.
- a daemon that runs live by default.
- approval to scale size.
- approval to hedge USDC.
- permission to remove `AERODROME_HEDGE_PAUSED`, `AERODROME_HEDGE_ENABLED`, `AERODROME_LIVE_APPROVED`, or emergency close gates.

## Current Evidence

Local operator evidence shows:

- testnet open/rebalance/close passed.
- first mainnet micro-run passed.
- 15-minute and 30-minute live observations passed.
- a 1-hour observation exposed finalization/readback ambiguity.
- finalization hardening was implemented.
- 15-minute finalization retest passed.
- 3-hour supervised live observation passed.
- final mainnet ETH position was nil.
- persistent safe env was restored after each run.

This evidence supports planning production supervised mode. It does not approve unattended live operation.

## Safe Defaults

Persistent app env must remain safe unless a manually approved supervised window is actively running:

```text
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

Do not store seed phrases in env. Do not commit secrets. Prefer API-wallet operation over main wallet private keys where supported by the operator setup.

## Required Live Gates

Any supervised live window still requires explicit one-off live gates:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- live observation confirmation phrase.
- `AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH=true`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MAX_SHORT_ETH<=0.02`
- `AERODROME_MAX_SHORT_NOTIONAL_USD<=50`
- live emergency close enabled.
- live emergency close confirmation phrase.
- live emergency close max ETH greater than or equal to max short ETH.

These gates are temporary for a supervised run. Restore safe defaults immediately after the run.

## Required Preflight Sequence

Before a supervised production run:

1. Confirm `git status --short` is clean.
2. Run `bin/rake`.
3. Create a backup.
4. Confirm dashboard health: active Aerodrome position, current PnL snapshot, rewards/fees status, and latest rebalance history.
5. Run `bin/rails aerodrome:pre_live_check`.
6. Run `CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check` in mainnet read-only mode.
7. Run `bin/rails aerodrome:production_supervised_readiness`.
8. Run `bin/rails aerodrome:watchdog_check`.
9. Confirm mainnet ETH position is nil.
10. Confirm testnet ETH position is nil.
11. Confirm latest observation JSONL ended with final position nil and `manual_action_required=false`.
12. Confirm live emergency close gates are ready but not persistently armed outside the supervised window.

Passing readiness is not permission to run live. A human operator must still explicitly approve the run.

## Required Backup Sequence

Before a run:

- create a database/application backup.
- record git SHA. Production container deployments should set `APP_GIT_SHA=$(git rev-parse --short HEAD)` at build/deploy time because `.git` may not exist inside the image.
- record env gate plan without secrets.
- record latest mainnet/testnet ETH readback.

After a run:

- create a post-run backup.
- archive the observation JSONL log.
- record final mainnet/testnet ETH readback.
- restore safe env defaults.

## Required Final Close Sequence

Every supervised run must end with close-on-finish enabled. Success requires:

- final close status `success`.
- final mainnet ETH position `nil`.
- `final_position_confirmed=true`.
- `manual_action_required=false`.
- no unexpected USDC rebalance.

If final close is unknown or failed, run the live emergency close procedure if gates and max ETH allow it. If readback remains unavailable, stop and escalate to manual Hyperliquid account inspection.

## Stop And Close Rules

Stop the bot and close or verify closure if any of these occur:

- mainnet ETH short exceeds configured max.
- any failed WETH rebalance appears.
- Hyperliquid readback is unavailable after retries.
- final close status is not `success`.
- `manual_action_required=true`.
- mainnet ETH position cannot be read.
- Aerodrome position sync repeatedly fails.
- current Aerodrome position becomes inactive or missing.
- env gates mismatch expected supervised-run values.
- unexpected USDC rebalance appears.
- process receives `SIGINT` or `SIGTERM` during a live run.

USDC must never be opened or closed by Aerodrome hedge logic.

## Emergency Close Escalation

The first response to an open ETH short after a supervised run is the gated live emergency close task. It is live-order capable and blocked by default. It closes ETH only, uses explicit size, and must never open positions or touch USDC.

Escalate manually if:

- emergency close fails.
- Hyperliquid readback remains unknown.
- ETH position remains open.
- network/API errors persist.
- actual ETH short exceeds max close cap.

## Operator Responsibilities

During production supervised mode, the operator must:

- actively watch logs and dashboard.
- keep Hyperliquid account UI/readback available.
- verify every rebalance row.
- verify no USDC rebalance appears.
- verify final mainnet ETH position nil.
- restore safe env defaults after the run.
- record incident notes for any warning, failure, or manual action.

## Alert Conditions

Alerting is required before any longer or semi-continuous operation. Future alert channels may include:

- email.
- Telegram.
- local log tail.
- VPS `systemd` journal.
- dashboard banner.

Alert events:

- run started.
- position opened.
- rebalance executed.
- failed rebalance.
- final close started.
- final close success.
- final close unknown or failed.
- mainnet ETH not nil after run.
- manual action required.
- RPC/API error streak.
- process crash.

`bin/rails aerodrome:watchdog_check` is read-only: it does not close positions, does not place orders, and does not call Hyperliquid execution methods. `bin/rails aerodrome:watchdog_alerts` is also read-only and formats watchdog output into dry-run/local alert messages with title, summary, blockers, warnings, and recommended actions. It does not send email or Telegram messages, does not close positions, and does not automate live operation. Blockers require operator action, and the emergency close remains a separate manually gated task.

## VPS And Runtime Setup

Recommended foundation before production supervised mode:

- stable VPS with enough disk, memory, and swap for Rails/Solid Queue.
- `systemd` unit with explicit env file handling and journal retention.
- no live gates in persistent env by default.
- log rotation for Rails logs and observation JSONL logs.
- monitored disk space.
- documented restart policy.
- clear operator access to Hyperliquid UI/API readback.
- backup and restore procedure tested.

Do not run as unattended 24/7 automation until watchdogs, alerting, and incident response have been tested.

## Log Retention

Retain:

- Rails logs for the run window.
- Solid Queue/job logs.
- observation JSONL logs.
- readiness/preflight output.
- final emergency close output.
- final mainnet/testnet ETH readback.

Observation JSONL logs should be archived with the run report.

## Restart Policy

For production supervised mode, restarts should be conservative:

- do not auto-restart into live gates without operator confirmation.
- after crash/restart, first run read-only readiness and Hyperliquid readback.
- if ETH position is open, follow emergency close escalation.
- do not resume live observation automatically.

## Incident Response

For any incident:

1. Stop the live process if still running.
2. Read mainnet ETH position.
3. If ETH short remains and gates allow, run live emergency close.
4. Verify mainnet ETH nil.
5. Restore safe env defaults.
6. Preserve logs and JSONL.
7. Create incident note.
8. Do not restart live operation until the cause is reviewed.

## Recovery Procedure

Recovery after failure requires:

- mainnet ETH nil or explicitly documented open-position handling.
- failed rebalance rows reviewed.
- failed zero-size no-position rows acknowledged only through the existing acknowledgment task.
- `bin/rake` passing.
- readiness checks passing.
- explicit manual approval for the next run.

Do not delete or rewrite `ShortRebalance` history.

## Staged Rollout Plan

1. Keep safe defaults.
2. Add/read `aerodrome:production_supervised_readiness`.
3. Use `aerodrome:watchdog_check` as read-only watchdog evidence.
4. Test alerting without orders.
5. Test crash/stop/final-close behavior under mocks.
6. Plan one supervised production-mode window with tiny caps.
7. Review logs and incident readiness before any longer duration.

Scaling duration, size, or autonomy requires a separate approval and safety review.

`APP_GIT_SHA` is metadata only. It helps readiness identify the deployed revision and does not enable live trading, orders, or any execution path.
