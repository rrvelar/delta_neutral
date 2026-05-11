# Aerodrome Target-Step Rebalance Test Report

## Scope

This report records the VPS controlled target-step rebalance test for the Aerodrome WETH hedge on Hyperliquid. The test was live-capable, explicitly gated, supervised, and designed to prove one rebalance up and one rebalance down without relying on normal market movement.

This report is audit documentation only. It does not enable live trading, does not approve unattended operation, and does not add any execution path.

## Why The Test Was Needed

A prior 5-hour VPS `production_live_run` completed successfully with one WETH hedge opened and approved-open monitoring working. During that run, price moved, but no extra rebalance occurred because the largest observed delta was approximately:

- `delta_eth`: `0.0027139 ETH`
- `delta_usd`: `$6.31`

That was below `AERODROME_MIN_ORDER_NOTIONAL_USD=10`, so the runner correctly avoided creating another small rebalance. The target-step test was needed to intentionally produce rebalance deltas above the minimum order notional while keeping caps small and supervised.

## Target-Step Parameters

- task: `aerodrome:production_target_step_test`
- original target: `0.01`
- up target: `0.015`
- down target: `0.01`
- restore target: `true`
- close on finish: `true`

## Volatility Guard Results

The volatility guard allowed both steps.

Up guard:

- status: `pass`
- allowed: `true`
- proposed_delta_eth: `0.01534037906291424`
- proposed_delta_usd: `35.9808644179381529825658432`
- warning: Hyperliquid mark price unavailable; divergence check skipped

Down guard:

- status: `pass`
- allowed: `true`
- proposed_delta_eth: `0.00507976595554028`
- proposed_delta_usd: `11.9153655556567973300621256`
- price_move_bps: `0.6485688232060865313625572549765`
- window_move_bps: `0.6485688232060865313625572549765`
- price_divergence_bps: `0.22369125170532060027285129604366`

## Rebalance Evidence

Two WETH rebalance rows were created successfully:

- `ShortRebalance #196`: WETH `0.0 -> 0.0153`, status `success`
- `ShortRebalance #197`: WETH `0.0153 -> 0.0102`, status `success`

The USDC side was not part of the test.

## Target Restoration

The task restored the hedge target after the test:

- target restored: `true`
- hedge target after test: `0.01`

## Final Close And Readback

The final close/readback completed safely:

- final ETH position: `nil`
- final_position_confirmed: `true`
- manual_action_required: `false`
- final status: `success`
- mainnet ETH after test: `nil`

## What Was Proven

- The controlled target-step task can produce a WETH rebalance up when the proposed delta exceeds the minimum order notional.
- The controlled target-step task can produce a WETH rebalance down when the proposed delta exceeds the minimum order notional.
- The volatility guard can allow controlled steps under calm conditions.
- The original hedge target was restored after the test.
- The final emergency close/readback path returned ETH to nil.
- The earlier 5-hour run’s lack of extra rebalance was explained by the `$10` minimum order notional, not by a failed rebalance path.

## What Was Not Proven

- Behavior during sharp pump/dump conditions was not proven.
- Behavior when the volatility guard blocks a live step was not proven on VPS.
- Behavior with partial fills, Hyperliquid API degradation, RPC degradation, or stale Aerodrome position data was not proven.
- USDC hedge behavior remains unsupported for Aerodrome.
- This does not prove unattended 24/7 operation is safe.

## Remaining Risks

- Hyperliquid readback or order submission can fail during future live runs.
- Aerodrome position data can become stale during volatile markets.
- A rebalance that is correct at decision time can become stale before execution.
- Guard thresholds may need tuning after more supervised runs.
- Manual emergency close must remain available before any further live tests.

## Next Recommended Stage

The next stage should remain supervised production operation. Reasonable next work is either:

- another bounded `production_live_run` with volatility guard enabled and approved-open monitoring active, or
- a separately reviewed blocked-guard VPS test scenario.

Do not scale limits, add unattended scheduling, or treat this as 24/7 approval without separate design and review.
