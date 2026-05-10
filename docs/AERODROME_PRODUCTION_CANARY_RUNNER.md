# Aerodrome Production Canary Runner

This document describes the supervised Aerodrome production canary runner. It is closer to real bot operation than the observation window because it repeatedly runs `PositionSyncJob` and `HedgeSyncJob` over a bounded window, records heartbeats, watches stop conditions, and performs mandatory final close. It is not unattended 24/7 operation.

## What It Is

Task:

```bash
bin/rails aerodrome:production_canary_run
FORMAT=json bin/rails aerodrome:production_canary_run
```

The task is live-order capable only when explicit one-off gates are present. By default it is blocked.

## Required Gates

All must be true/configured:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_PRODUCTION_CANARY_ENABLED=true`
- `AERODROME_PRODUCTION_CANARY_CONFIRM=I_UNDERSTAND_THIS_RUNS_SUPERVISED_LIVE_CANARY`
- `AERODROME_PRODUCTION_CANARY_DURATION_SECONDS`
- `AERODROME_PRODUCTION_CANARY_INTERVAL_SECONDS`
- `AERODROME_PRODUCTION_CANARY_CLOSE_ON_FINISH=true`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MAX_SHORT_ETH` configured and `<= 0.02`
- `AERODROME_MAX_SHORT_NOTIONAL_USD` configured and `<= 50`
- `AERODROME_MIN_ORDER_NOTIONAL_USD` configured and `>= 10`
- live emergency close gates present and valid.

Hard limits:

- duration max: 21600 seconds.
- interval min: 180 seconds.
- close-on-finish is mandatory for this phase.
- emergency close max ETH must be at least `AERODROME_MAX_SHORT_ETH`.

Future leave-position-open mode requires separate approval and implementation.

## Runtime Behavior

The runner:

1. Takes a single-instance file lock at `storage/aerodrome_production_canary/run.lock`.
2. Refuses if mainnet ETH position exists before start.
3. Refuses if unacknowledged failed WETH rows or successful USDC rows exist.
4. Refuses if production supervised readiness has unexpected blockers.
5. Writes JSONL events under `storage/aerodrome_production_canary/*.jsonl`.
6. Each iteration runs:
   - `PositionSyncJob.perform_now(position.id)`
   - `HedgeSyncJob.perform_now(hedge.id)`
   - read-only mainnet ETH readback
   - watchdog check
7. Records iteration state, heartbeat, new `ShortRebalance` rows, errors, and PnL snapshot id.
8. Traps `SIGINT`/`SIGTERM`, records the signal, stops the loop, and attempts final close.

## Stop Conditions

The runner stops and goes to final close if:

- any failed WETH rebalance appears.
- actual ETH short exceeds max.
- mainnet ETH readback fails during an iteration.
- `PositionSyncJob` or `HedgeSyncJob` raises.
- current position becomes inactive/missing.
- unexpected successful USDC rebalance appears.
- watchdog returns `BLOCKED`.
- `SIGINT` or `SIGTERM` is received.

## Finalization

`AERODROME_PRODUCTION_CANARY_CLOSE_ON_FINISH=true` is mandatory. At finish, the runner attempts the gated live emergency close if an ETH short exists or is likely open. It reports:

- `success` only when final mainnet ETH is confirmed nil.
- `close_unknown` when final readback cannot confirm nil.
- `failed` when ETH remains open, close fails, or stop conditions occurred.
- `manual_action_required=true` when final state is unknown/open/failed.

Emergency close remains a separate manually gated service reused by the runner. The runner never touches USDC directly and does not call `set_leverage` directly; order behavior remains inside existing `HedgeSyncJob` and `HyperliquidService`.

## Output

Human output includes:

- banner and live-order-capable warning.
- duration, interval, and caps.
- log path.
- iteration count.
- rebalance count.
- stop reason.
- final close status.
- final mainnet ETH position.
- `manual_action_required`.
- final status.

JSON output includes the same fields plus `database_write`, `orders_enabled`, and `hyperliquid_execution`.

## Operational Rule

A production canary run is supervised only. It is not background automation and must not be scheduled by systemd/cron. Watchdog scheduling remains read-only and must not run this task.
