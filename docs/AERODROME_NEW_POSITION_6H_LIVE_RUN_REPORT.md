# Aerodrome New Position 6H Live Run Report

## Scope

This report records a supervised 6-hour production live run for the new direct Aerodrome Slipstream WETH/USDC position. It is historical audit documentation only. It does not enable live trading, approve unattended operation, add an order path, or change any runtime behavior.

## New Position Details

- Aerodrome Slipstream token id: `70184676`
- Position manager: `0x827922686190790b37229fd06084350e74485b72`
- Factory: `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`
- Hedge target: `1.0`
- Web/dashboard: remained running during the live run for operator PnL/status monitoring.

Setup fixes required before the first real-position runs:

- The direct Slipstream NFT required the current Aerodrome position manager and factory addresses above.
- Ownership handling had to account for `ownerOf` and gauge/custody wallet behavior, so the operator verifies the expected wallet/custody path before treating synced position data as live-run evidence.
- These remain deployment/operator checks; no private keys or secrets are recorded in this document.

## Caps Used

- `AERODROME_MAX_SHORT_ETH=0.55`
- `AERODROME_MAX_SHORT_NOTIONAL_USD=1300`
- `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.60`
- `AERODROME_MIN_ORDER_NOTIONAL_USD=10`
- `AERODROME_MAX_LEVERAGE=1`
- volatility guard enabled.

These are supervised production-live caps for `production_live_run`, not the micro caps used by observation, canary, or target-step tooling. They do not approve larger caps.

## Live Run Evidence

- Task: `aerodrome:production_live_run`
- Duration: `21600` seconds
- Interval: `300` seconds
- Iterations: `72`
- Final status: `success`
- Stop reason: `duration complete`
- Final ETH position: about `-0.3973`
- `final_position_confirmed=true`
- `position_left_open=true`
- `manual_action_required=false`
- `errors=[]`

The successful duration-complete result means Production Live Runner V1 intentionally left the in-cap ETH hedge open by design. That is supervised production behavior, not unattended 24/7 approval.

## Rebalance #201

`ShortRebalance #201` opened the WETH-side hedge:

- asset: `WETH`
- old short size: `0.0`
- new short size: `0.3973`
- status: `success`

USDC remained unsupported and was not used as a hedge side.

## Runtime Safety

Runtime safety stayed `PASS` during the run:

- `runtime_safety_status=PASS`
- no runtime safety blockers recorded.
- no runtime safety warnings recorded.
- actual ETH short remained within `0.55 ETH` and `$1300` caps.
- no unexpected USDC rebalance was reported.

## Volatility Guard Behavior

The volatility guard was enabled. It allowed the initial WETH hedge open and later evaluated potential natural rebalance opportunities.

Important observation: additional natural rebalances did not execute even when some `proposed_delta_usd` values exceeded `$10`. The likely reason is that `hedge.tolerance=0.05` kept the relative deviation too small for `Hedge#needs_rebalance?` to trigger. This is protective anti-churn behavior and should not be changed casually.

Changing this behavior requires a separate rebalance policy review covering tolerance, minimum notional, expected fee/slippage, volatility guard interaction, and operator alerting. This report does not recommend changing tolerance.

## Approved-Open And Watchdog Behavior

After the clean duration-complete run:

- approved-open monitoring should report `approved` while the ETH hedge remains open and within caps/tolerance.
- `production_live_status` should remain `PASS` for the approved open position.
- `watchdog_alerts` should be `WARN` or `PASS`, not `BLOCKED`, with blockers empty when the only open ETH is the approved in-cap hedge.

The generic production readiness check remains strict safe-mode evidence. Watchdog is approved-open-aware and should treat this in-cap left-open hedge as monitored state, not an emergency by itself.

## Manual Close And Readback

Emergency close remains separate, manual, and gated. It is not run automatically by the watchdog or by the duration-complete production live runner path.

For this 6-hour run, the operator evidence says the emergency close was or will be executed manually after verification. Final post-close evidence should confirm:

- before close: ETH short about `-0.3973`
- close submitted through the manually gated `aerodrome:live_emergency_close`
- after close: mainnet ETH readback `nil`
- persistent safe env restored.

If exact close attempt logs are not yet attached to this report, treat post-close nil verification as a required operator checklist item before any next live run.

## Final Safe State

Persistent safe env remains:

- `AERODROME_HEDGE_ENABLED=false`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_APPROVED=false`
- `HYPERLIQUID_TESTNET=true`

After the manual close, mainnet ETH should be verified nil and testnet ETH should remain nil.

## Proven

- The new direct Aerodrome position `70184676` can run a 6-hour supervised production live window.
- A real 1x WETH hedge opened successfully at about `0.3973 ETH`.
- Runtime safety stayed `PASS` through `72` iterations.
- The web/dashboard can remain online during the live run for operator monitoring.
- Production Live Runner V1 can intentionally leave a valid in-cap ETH hedge open on clean duration completion.
- Approved-open/watchdog monitoring is the intended post-run monitoring path while ETH remains open.

## Not Proven

- Unattended 24/7 operation.
- Automatic restart/adopt operation without operator supervision.
- Automatic emergency close by watchdog.
- Larger caps than `0.55 ETH` / `$1300`.
- Rebalance policy changes for lower tolerance or more frequent natural rebalances.
- High-volatility behavior beyond guard skip decisions.
- USDC hedging; USDC remains unsupported.

## Remaining Risks

- Any Hyperliquid readback ambiguity can still require manual UI/API verification.
- A left-open hedge requires active operator awareness until it is manually closed or intentionally adopted by a later run.
- Tolerance and min-notional behavior can prevent small natural rebalances; changing that may increase churn, fees, slippage, and operational risk.
- Approved-open monitoring depends on current readback and JSONL history integrity.
- Longer runs can expose VPS, Docker, network, or alerting issues not covered by this 6-hour window.

## Next Recommended Stage

The next stage can be another longer supervised production run on token id `70184676` with web/dashboard online, approved-open monitoring active, watchdog alerts observed, backups before/after, and manual emergency close readiness.

Before changing rebalance frequency, run a separate rebalance policy review. That review should compare tolerance, min order notional, expected Hyperliquid fees/slippage, volatility guard cooldowns, and the desired anti-churn behavior.

Unattended 24/7 operation still requires a separate design and approval covering restart/adopt rules, watchdog escalation, alert delivery, process supervision, and final-close guarantees.
