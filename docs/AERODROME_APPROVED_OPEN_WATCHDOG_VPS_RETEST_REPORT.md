# Aerodrome Approved-Open Watchdog VPS Retest Report

## Scope

This report records the VPS retest of approved-open-position monitoring after watchdog/readiness integration was made approved-open-aware. It is historical evidence only. It does not enable live trading, approve unattended operation, or add any execution path.

## Why This Retest Was Needed

Production Live Runner V1 can intentionally leave an ETH hedge open after clean duration completion. The normal production readiness check is strict safe-mode evidence and reports blocked when mainnet ETH is open. After approved-open monitoring was added, watchdog still inherited that strict readiness blocker and returned `BLOCKED` even when `approved_open_position=approved`.

The fix made watchdog suppress only the strict readiness nil-position blocker when the approved-open detector validates the current ETH short as expected and within caps. Readiness remains strict, and unrelated readiness blockers still block.

## Previous Issue Summary

Before the fix:

- `production_live_status` showed a valid approved-open ETH hedge.
- `approved_open_position` reported `approval_status="approved"`.
- `watchdog_alerts` still returned `BLOCKED`.
- The confusing blocker was `Production supervised readiness has no blockers: BLOCKED`.

## Fix Summary

The watchdog now reports explicit readiness fields:

- `readiness_status`
- `readiness_blockers`
- `readiness_warnings`
- `readiness_blockers_suppressed_due_approved_open`

If the only readiness blocker is the expected strict-safe-mode ETH-open blocker and approved-open monitoring validates the current ETH hedge, watchdog reports warning/monitoring state instead of blocked. It still blocks on failed WETH, successful USDC, unknown readback, cap mismatch, manual action, or unrelated readiness blockers.

## Production Live Run Evidence

The VPS approved-open retest ran `production_live_run` with:

- duration: 360 seconds
- interval: 180 seconds
- `leave_position_open=true`
- `close_on_error=true`
- iterations: 2
- rebalances count: 1
- final status: `success`
- final ETH position existed and was left open by design
- final ETH size around `-0.0093`
- `final_position_confirmed=true`
- `position_left_open=true`
- `manual_action_required=false`

## Approved-Open Evidence

`aerodrome:approved_open_position` reported:

- approved: true
- approval status: `approved`
- approved final position: ETH around `-0.0093`
- current mainnet ETH position matched and was within caps
- blockers: none

## Production Live Status Evidence

`aerodrome:production_live_status` reported:

- status: `PASS`
- lock exists: false
- approved open position: true
- approval status: `approved`
- `manual_action_required=false`

## Watchdog Alerts Evidence

`aerodrome:watchdog_alerts` reported:

- status: `WARN`, not `BLOCKED`
- blockers: none
- `approved_open_position=approved`
- warning included: `production readiness is strict safe-mode; approved open ETH is monitored by approved-open detector`

This proves the approved-open ETH hedge was treated as monitored state rather than an emergency while still preserving the strict readiness signal.

## Manual Close Evidence

After the retest, the operator manually ran the gated live emergency close with explicit one-off gates:

- ETH position before close: around `-0.0093`
- attempt 1 submitted size `0.0093`
- ETH position after close: nil
- final status: `success`
- final Hyperliquid mainnet readback after close: nil

## Final Safe State

Persistent env was restored to safe defaults:

- `AERODROME_HEDGE_ENABLED=false`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_APPROVED=false`
- `HYPERLIQUID_TESTNET=true`

Testnet ETH position was nil.

## What Was Proven

- Production Live Runner V1 can leave a small ETH hedge open by design on clean completion.
- Approved-open detector correctly recognized the open ETH hedge as approved and in caps.
- `production_live_status` correctly reported approved-open state and no stale lock.
- `watchdog_alerts` no longer blocks solely because strict readiness sees approved-open ETH.
- Emergency close remains separate, manually gated, and successfully closed the ETH short.

## What Was Not Proven

- This does not prove unattended 24/7 operation.
- This does not prove restart/adopt-existing behavior across process crashes.
- This does not prove larger size limits, higher leverage, or USDC hedging.
- This does not replace manual operator supervision or independent Hyperliquid readback.

## Remaining Risks

- Hyperliquid/API readback can fail or be delayed.
- Approved-open state depends on JSONL history and current readback staying consistent.
- A process crash while ETH is open still requires conservative operator review.
- Emergency close remains manual and must be ready before any longer run.

## Next Recommended Stage

The next stage can be either:

- a longer supervised `production_live_run` with approved-open monitoring active, or
- explicit design of restart/adopt-existing workflow before longer leave-position-open windows.

Either path requires fresh preflight/readiness review, explicit one-off gates, operator supervision, and manual emergency close readiness.
