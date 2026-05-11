# Aerodrome Rebalance Volatility Guard

## Scope

`AerodromeRebalanceVolatilityGuard` is a read-only guard used before live rebalance attempts in production runner flows. It is disabled by default. When disabled, it returns `pass` / `allowed=true` and preserves existing production runner behavior.

## Configuration

The guard is controlled by env configuration in `.env.example`:

- `AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED=false`
- `AERODROME_REBALANCE_MAX_MOVE_BPS_PER_INTERVAL=100`
- `AERODROME_REBALANCE_MAX_MOVE_BPS_WINDOW=250`
- `AERODROME_REBALANCE_VOLATILITY_WINDOW_SECONDS=900`
- `AERODROME_REBALANCE_VOLATILITY_COOLDOWN_SECONDS=600`
- `AERODROME_REBALANCE_MAX_PRICE_DIVERGENCE_BPS=100`
- `AERODROME_REBALANCE_MIN_SECONDS_BETWEEN_REBALANCES=600`

## Guard Rules

When enabled, the guard can skip a rebalance when:

- per-interval price movement exceeds the configured bps threshold;
- movement over the configured time window exceeds the configured bps threshold;
- Hyperliquid mark price and Aerodrome LP/position price diverge above the configured bps threshold;
- required price readback is unavailable;
- the last successful rebalance happened too recently;
- cooldown is active after a volatility breach.

The guard only decides whether a rebalance should be attempted. It does not close positions, does not place orders, and does not bypass emergency close behavior. Emergency close remains separate and manually gated.

## Production Runner Use

`AerodromeProductionLiveRunner` runs the guard before `HedgeSyncJob.perform_now`. If the guard blocks, the runner records `rebalance_skipped_by_volatility_guard` and continues unless another runtime safety blocker exists.

`AerodromeProductionTargetStepTest` requires the guard to be enabled. A blocked target-step rebalance is recorded and the task restores the original target and closes any ETH at finish.
