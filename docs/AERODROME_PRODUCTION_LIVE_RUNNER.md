# Aerodrome Production Live Runner V1

## Scope

`bin/rails aerodrome:production_live_run` is the first supervised leave-position-open runner for the Aerodrome WETH/ETH hedge. It is live-order capable only when explicit one-off gates are supplied. It is not enabled by default, not scheduled, not a daemon, and not unattended 24/7 operation.

## Required Gates

The runner refuses unless all production live gates are set:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_PRODUCTION_LIVE_ENABLED=true`
- `AERODROME_PRODUCTION_LIVE_CONFIRM=I_UNDERSTAND_THIS_RUNS_PRODUCTION_LIVE_HEDGE`
- `AERODROME_PRODUCTION_LIVE_DURATION_SECONDS` configured and `<= 21600`
- `AERODROME_PRODUCTION_LIVE_INTERVAL_SECONDS` configured and `>= 180`
- `AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL=true`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MAX_SHORT_ETH <= 0.02`
- `AERODROME_MAX_SHORT_NOTIONAL_USD <= 50`
- `AERODROME_MIN_ORDER_NOTIONAL_USD >= 10`
- live emergency close gates present and valid.

Default persistent env must remain disabled, paused, not live-approved, and testnet outside an explicitly approved supervised run.

## Runtime Behavior

The runner takes a file lock at `storage/aerodrome_production_live/run.lock` and writes JSONL events to `storage/aerodrome_production_live/*.jsonl`.

Each iteration runs:

- `PositionSyncJob.perform_now(position.id)`
- `HedgeSyncJob.perform_now(hedge.id)`
- read-only mainnet ETH position readback
- production-live runtime safety check

The live runner never opens/closes USDC directly and does not call `set_leverage` directly. Hedge execution remains inside the existing `HedgeSyncJob` and `HyperliquidService` path.

## Leave-Position-Open Rule

On clean duration completion, V1 leaves the ETH hedge open by design. Success requires final readback to confirm either:

- an ETH position exists and remains within configured caps, or
- target short is zero and final ETH position is nil.

The operator must run `bin/rails aerodrome:production_live_status` after every run and verify the final state independently.

## Error And Signal Rule

If the run stops because of an error, blocker, failed WETH/ETH rebalance, cap breach, unexpected USDC rebalance, readback failure, inactive/missing position, env mismatch, emergency close gate mismatch, or `SIGINT`/`SIGTERM`, the runner attempts the manually gated live emergency close when close-on-error/signal gates are true. Success then requires final ETH nil.

If final readback cannot confirm the ETH state, status is `close_unknown` and `manual_action_required=true`.

## Status And Stop Plan

- `bin/rails aerodrome:production_live_status` is read-only. It reports lock state, latest log, latest final status, current mainnet ETH position, safe env values, and manual-action state.
- `bin/rails aerodrome:production_live_stop_plan` is read-only. It prints operator stop/close steps and never closes positions.

Manual emergency close remains a separate explicitly gated task.

## Not Approved

This runner is not an unattended live service. Do not add systemd, cron, or UI start controls for it without a separate review. Future unattended/systemd live service and larger limits require separate approval and implementation.
