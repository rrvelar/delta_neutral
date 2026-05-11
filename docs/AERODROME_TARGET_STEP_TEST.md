# Aerodrome Target-Step Rebalance Test

## Scope

`bin/rails aerodrome:production_target_step_test` is a strictly gated live-capable test for verifying one controlled WETH hedge rebalance up and one controlled rebalance down without waiting for market movement.

It is not enabled by default, not scheduled, not unattended automation, and not a UI action.

## Required Gates

The task refuses unless all one-off gates are set:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_TARGET_STEP_TEST_ENABLED=true`
- `AERODROME_TARGET_STEP_TEST_CONFIRM=I_UNDERSTAND_THIS_RUNS_LIVE_TARGET_STEP_REBALANCE_TEST`
- `AERODROME_TARGET_STEP_TEST_UP_TARGET` configured
- `AERODROME_TARGET_STEP_TEST_DOWN_TARGET` configured
- `AERODROME_TARGET_STEP_TEST_RESTORE_TARGET=true`
- `AERODROME_TARGET_STEP_TEST_CLOSE_ON_FINISH=true`
- `AERODROME_REBALANCE_VOLATILITY_GUARD_ENABLED=true`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MAX_SHORT_ETH <= 0.02`
- `AERODROME_MAX_SHORT_NOTIONAL_USD <= 50`
- `AERODROME_MIN_ORDER_NOTIONAL_USD >= 10`
- live emergency close gates present and valid.

Do not lower `AERODROME_MIN_ORDER_NOTIONAL_USD` below `10`.

## Behavior

The test refuses to start if mainnet ETH is already open. It saves the original hedge target, verifies that the configured up/down targets are `> 0` and `<= 0.02`, and verifies that each step stays inside max ETH and max notional caps based on the current WETH amount and price.

For each step:

- temporarily writes `hedge.target` to the step target;
- runs `PositionSyncJob.perform_now(position.id)`;
- calculates proposed target/current/delta;
- runs `AerodromeRebalanceVolatilityGuard`;
- runs `HedgeSyncJob.perform_now(hedge.id)` only when the guard allows it;
- records new WETH `ShortRebalance` rows in JSONL.

If the guard blocks, the task skips that rebalance. A skipped rebalance is intentional safety behavior and is preferable to forcing a trade during sharp movement.

The task always attempts to restore the original hedge target and always runs the separately gated live emergency close at finish. Final success requires the target restored, final ETH readback confirmed nil, and `manual_action_required=false`.

## Logs

JSONL logs are written to:

```text
storage/aerodrome_target_step_test/*.jsonl
```

Events include `start`, `target_changed`, `guard_check`, `rebalance_attempt`, `rebalance_result`, `target_restored`, `final_close_start`, `final_close_done`, and `finish`.

## Safety

The task never supports USDC. Emergency close remains separate and manually gated. This does not approve unattended 24/7 operation or larger limits.

## VPS Test Result

The VPS controlled target-step rebalance test passed and is documented in `docs/AERODROME_TARGET_STEP_REBALANCE_TEST_REPORT.md`. The task stepped the target from `0.01` to `0.015` and back to `0.01`. The volatility guard allowed both steps. `ShortRebalance #196` moved WETH from `0.0` to about `0.0153`, and `ShortRebalance #197` moved WETH from about `0.0153` to about `0.0102`; both succeeded. The target was restored to `0.01`, final ETH was nil, and `manual_action_required=false`.

The previous 5-hour production live run did not rebalance more often because the largest observed delta was about `$6.31`, below `AERODROME_MIN_ORDER_NOTIONAL_USD=10`. That was expected safety behavior.
