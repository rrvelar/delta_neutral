# Aerodrome Production Live Runner V1 First Run Report

## Scope

This report records the first VPS Production Live Runner V1 run. It is documentation only. It does not enable live trading, add execution paths, change `.env`, or approve unattended 24/7 operation.

## Why This Run Matters

Production Live Runner V1 is the first supervised Aerodrome mode that can intentionally leave a valid ETH hedge open after clean duration completion. Earlier canary and observation modes closed the ETH hedge at the end of the run. This run tested the V1 leave-position-open behavior under explicit one-off gates, small caps, and runtime safety checks.

## Previous Testing Milestones

Before this run, the system had passed:

- first mainnet live micro-run.
- 15-minute, 30-minute, and 3-hour live observation windows.
- finalization hardening and 15-minute finalization retest.
- VPS deployment and readiness checks.
- VPS 15-minute live observation.
- production canary runner.
- canary-aware runtime safety fix.
- VPS canary runtime-safety retest with runtime safety `PASS`, successful final close, final mainnet ETH nil, and `manual_action_required=false`.

## V1 Gates Used

Evidence from VPS logs:

- task: `bin/rails aerodrome:production_live_run`
- mode: production live V1
- duration: 3600 seconds
- interval: 300 seconds
- `AERODROME_PRODUCTION_LIVE_LEAVE_POSITION_OPEN=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_ERROR=true`
- `AERODROME_PRODUCTION_LIVE_CLOSE_ON_SIGNAL=true`
- max short ETH: `0.02`
- max short notional USD: `50`
- leverage: `1`

The runner remained manually launched only. No scheduler, UI button, or background live automation was used.

## Loop Summary

- iterations: 12
- rebalances count: 1
- stop reason: `duration complete`
- final status: `success`

The run completed its configured duration without triggering error, signal, or runtime-safety stop conditions.

## Rebalance Summary

The run created one WETH-side rebalance. The USDC side was not used.

The ETH hedge remained within configured caps during the run:

- final ETH short size: about `-0.0101`
- max short ETH: `0.02`
- max short notional USD: `50`

## Runtime Safety Summary

Runtime safety stayed healthy during iterations:

- `runtime_safety_status=PASS`
- `runtime_safety_blockers=[]`
- `runtime_safety_warnings=[]`

This confirmed that the production live runtime safety path accepts a known valid in-cap ETH hedge as intended state during a supervised live run.

## Final Leave-Position-Open Result

The clean duration completion path worked:

- final ETH position confirmed: true
- final ETH short size: about `-0.0101`
- `position_left_open=true`
- `manual_action_required=false`
- final status: `success`

The runner intentionally did not close on duration completion because leave-position-open mode was enabled and the final ETH position was confirmed within caps.

## Post-Run Close And Readback

After the run, mainnet ETH position was later verified nil. A subsequent `live_emergency_close` returned noop because ETH position was already nil. Testnet ETH position was also nil.

This means the run's leave-position-open behavior worked, and the later operator-managed readback/cleanup ended with no mainnet or testnet ETH short.

## Final Safe Env State

Persistent safe env after the run:

- `AERODROME_HEDGE_ENABLED=false`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_APPROVED=false`
- `HYPERLIQUID_TESTNET=true`

## What Was Proven

- Production Live Runner V1 can complete a 1-hour supervised run.
- `leave_position_open=true` can leave an in-cap ETH hedge open on clean duration completion.
- Runtime safety can remain `PASS` while a valid ETH hedge is open.
- USDC remained unsupported and unused.
- The final output correctly reported `position_left_open=true`, `final_position_confirmed=true`, and `manual_action_required=false`.
- Post-run readback later verified mainnet ETH nil.
- Persistent env was restored to safe defaults.

## What Was Not Proven

- This does not prove unattended 24/7 operation is safe.
- This does not prove larger caps or higher leverage are safe.
- This does not prove leave-position-open behavior across restarts or process crashes.
- This does not prove all Hyperliquid network/API failure modes are handled.
- This does not approve systemd/cron live execution.

## Remaining Risks

- A valid open ETH hedge is now an expected state during approved production live runs, but generic safe-mode watchdog logic still treats unexpected mainnet ETH as a blocker.
- Monitoring must distinguish approved open-position state from unsafe stale/open positions.
- Hyperliquid readback can fail or become ambiguous.
- Any successful USDC rebalance remains a critical incident.
- Any failed WETH/ETH row requires review before another run.

## Next Recommended Stage

The next stage should be approved-open-position monitoring/watchdog work. The goal is to let operators mark a known valid open ETH hedge as intended state during a supervised production live period, while preserving strict blockers for unexpected ETH shorts, cap breaches, failed WETH/ETH rows, USDC activity, unknown readback, and stale/manual-action logs.
