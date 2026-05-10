# Aerodrome VPS Canary Runtime Safety Retest Report

## Scope

This report records the VPS production canary retest after adding canary-aware runtime safety. It is documentation only. It does not enable live trading, add execution paths, change `.env`, or approve unattended operation.

## Why This Retest Was Needed

The first VPS production canary run behaved safely but ended with `status="failed"` because the generic safe-mode watchdog returned `BLOCKED` during an expected live canary state. During a canary, a small in-cap mainnet ETH short is expected after the WETH hedge opens. The persistent watchdog is designed for safe monitoring after env is restored to disabled/paused/not-approved/testnet, so it correctly treats an unexpected mainnet ETH short as unsafe in that mode.

## #190 Failure Summary

The prior VPS canary created `ShortRebalance #190`:

- asset: `WETH`
- old short size: `0.0`
- new short size: `0.0108`
- status: `success`
- canary stop reason: generic watchdog `BLOCKED`
- final close: success
- final mainnet ETH position: nil
- `manual_action_required=false`

This was a watchdog/canary context mismatch. It was not a Hyperliquid close failure, and it was not approval to weaken the normal persistent watchdog.

## Runtime Safety Fix Summary

The canary runner now uses canary-aware runtime safety during live canary iterations. The generic watchdog remains strict for persistent safe monitoring.

Canary runtime safety allows the expected live canary state only when:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- live canary gates remain valid
- emergency close gates remain valid
- ETH short size is within `AERODROME_MAX_SHORT_ETH`
- ETH notional is within `AERODROME_MAX_SHORT_NOTIONAL_USD`
- position and hedge remain active

It still blocks failed WETH/ETH rebalances, successful USDC rebalances, cap breaches, readback failures, inactive or missing position/hedge state, gate mismatch, or previous canary final logs with `manual_action_required=true` or a non-nil final position.

## VPS Retest Evidence

VPS production canary retest evidence from operator logs:

- duration: 1 hour
- runtime safety did not block the expected in-cap live ETH short
- iterations included `runtime_safety_status="PASS"`
- `runtime_safety_blockers=[]`
- `runtime_safety_warnings=[]`
- stop reason: `duration complete`
- finish status: `success`

## Final Close Evidence

Final close evidence from operator logs:

- final close started: `2026-05-10T12:13:45-04:00`
- final close completed: `2026-05-10T12:13:59-04:00`
- before position size: `-0.0106 ETH`
- close attempt 1 submitted size: `0.0106`
- after position: nil
- final position: nil
- final position confirmed: true
- `manual_action_required=false`
- final mainnet ETH readback after run: nil

## Final Safety State

The retest finished with final mainnet ETH nil and no manual action required. Persistent env should remain restored to the normal safe state outside an explicitly approved run:

- `AERODROME_HEDGE_ENABLED=false`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_APPROVED=false`
- `HYPERLIQUID_TESTNET=true`

## What Was Proven

- Canary-aware runtime safety no longer blocks an expected in-cap ETH short during a live canary.
- Runtime safety reports `PASS` with no blockers or warnings during the healthy canary state.
- Final close completed successfully after the canary.
- Final mainnet ETH was confirmed nil.
- The generic watchdog can remain strict for persistent safe monitoring.

## What Was Not Proven

- This does not prove unattended 24/7 operation is safe.
- This does not prove larger ETH or notional caps are safe.
- This does not prove leave-position-open mode is safe.
- This does not prove all Hyperliquid network/API failure modes are handled.
- This does not approve changing persistent safe env defaults.

## Remaining Risks

- Hyperliquid readback or order submission can still fail during live operation.
- Aerodrome position data can change between syncs.
- Unexpected failed WETH/ETH rows still require review.
- Any successful USDC rebalance remains a critical incident.
- Final close must remain mandatory for this canary phase.

## Next Recommended Stage

The next stage should be either a longer supervised canary or production supervised mode planning with explicit operator approval. It should keep the same small caps unless a separate review approves changes, and it must keep final close and emergency close gates in place.
