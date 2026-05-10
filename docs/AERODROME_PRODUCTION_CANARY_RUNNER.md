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
   - canary-aware runtime safety check
7. Records iteration state, heartbeat, runtime safety status/blockers/warnings, new `ShortRebalance` rows, errors, and PnL snapshot id.
8. Traps `SIGINT`/`SIGTERM`, records the signal, stops the loop, and attempts final close.

The generic `aerodrome:watchdog_check` remains a persistent safe-mode monitor. It is intentionally strict when the normal persistent env is disabled/paused/not-approved/testnet, and it should block if a mainnet ETH short exists in that safe state. During an explicitly gated production canary, a tiny mainnet ETH short is expected after the first WETH hedge opens. The canary runner therefore uses `AerodromeCanaryRuntimeSafetyCheck` during the loop instead of the generic watchdog.

Canary runtime safety is read-only. It allows the expected live canary state only when the live canary gates remain set, the ETH short is within `AERODROME_MAX_SHORT_ETH` and `AERODROME_MAX_SHORT_NOTIONAL_USD`, the position and hedge remain active, emergency close gates remain present, and the short is ETH/WETH only.

## Stop Conditions

The runner stops and goes to final close if:

- any failed WETH rebalance appears.
- actual ETH short exceeds max.
- mainnet ETH readback fails during an iteration.
- `PositionSyncJob` or `HedgeSyncJob` raises.
- current position becomes inactive/missing.
- unexpected successful USDC rebalance appears.
- canary runtime safety returns `BLOCKED`.
- `SIGINT` or `SIGTERM` is received.

Runtime safety blocks on cap breaches, missing readback, failed WETH/ETH rebalances during the run, any successful USDC rebalance, inactive/missing position or hedge, env gate mismatch, emergency close gate mismatch, or a previous canary final log with `manual_action_required=true` or non-nil final position.

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

## VPS Canary #190 Note

The first VPS production canary behaved safely but stopped early because the generic safe-mode watchdog saw an expected live canary ETH short and returned `BLOCKED`. `ShortRebalance #190` opened a WETH hedge from `0.0` to `0.0108` ETH, the final emergency close succeeded, `final_position_confirmed=true`, `manual_action_required=false`, and final mainnet ETH was nil. This was a watchdog/canary-context mismatch, not approval to weaken persistent monitoring. Repeat canary runs require fresh readiness/preflight checks and explicit manual approval.

## VPS Runtime Safety Retest

After adding canary-aware runtime safety, a VPS production canary retest ran for 1 hour and passed. Iterations reported `runtime_safety_status="PASS"`, `runtime_safety_blockers=[]`, and `runtime_safety_warnings=[]`. The expected in-cap ETH short was not blocked during the canary. Final close started at `2026-05-10T12:13:45-04:00`, closed `0.0106` ETH on attempt 1, completed at `2026-05-10T12:13:59-04:00`, and final mainnet ETH readback was nil with `manual_action_required=false`.

This confirms the canary/runtime-safety split for this retest only. The generic watchdog remains strict for persistent safe monitoring. This is not approval for unattended 24/7 operation; the next stage requires explicit operator approval.

## Production Live Runner V1

`docs/AERODROME_PRODUCTION_LIVE_RUNNER.md` documents the next supervised stage. Unlike the canary, the production live runner can leave the ETH hedge open on clean duration completion, but only under explicit one-off gates with small caps, `AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN=true`, close-on-error/signal gates, and live emergency close gates. USDC remains unsupported. It is not scheduled and not unattended 24/7 operation.
