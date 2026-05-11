# Aerodrome Approved Open Position Monitoring

## Scope

Approved open position monitoring is read-only. It does not place orders, close positions, approve new live runs, or weaken emergency close gates.

## Purpose

Production Live Runner V1 can intentionally leave a valid ETH hedge open after clean duration completion. The generic watchdog remains strict for persistent safe mode and should block unexpected mainnet ETH positions. Approved open position monitoring distinguishes a known valid open ETH hedge from an unexpected stale/open position.

`aerodrome:production_supervised_readiness` remains strict safe-mode evidence. It can report `BLOCKED` when mainnet ETH is open because readiness is designed to prove the default disabled/paused/not-approved/testnet state. `aerodrome:watchdog_check` is approved-open-aware: if the approved-open detector validates the current ETH short as in-cap and matching, the readiness nil-position blocker is warning-only. Other readiness blockers still block.

## Approval Source

An open ETH hedge is approved only when the latest `storage/aerodrome_production_live/*.jsonl` finish event has:

- `status="success"`
- `stop_reason="duration complete"`
- `position_left_open=true`
- `final_position` present
- `final_position_confirmed=true`
- `manual_action_required=false`
- no errors
- `final_position.asset="ETH"`
- final/current size within max ETH and notional caps.

If these conditions are not met, an open mainnet ETH position remains a watchdog blocker.

## Current Position Checks

When current mainnet ETH exists and an approved open log exists, monitoring verifies:

- asset is ETH.
- current short size is within max ETH cap.
- current notional is within max notional cap.
- current size is within `AERODROME_APPROVED_OPEN_POSITION_SIZE_TOLERANCE_ETH` of the approved final size.

Current Hyperliquid readback is authoritative for whether ETH is currently open. A prior approved-open `final_position` in JSONL history is evidence of what the runner left open at finish time, not permanent proof that the position still exists.

If current ETH is nil while an approved open log exists, the watchdog warns instead of blocking because nil is safe. Operators should inspect whether the hedge was manually closed. Future production live runs may proceed after fresh preflight if all other gates pass.

If current readback is unavailable, mismatched, out of tolerance, or out of caps, the watchdog blocks and requires operator action.

## Adopt-Existing Production Runs

`AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true` is the only mode that may start a production live run while ETH is already open. It is allowed only when approved-open monitoring reports `approved`, the current ETH short is within caps/tolerance, `manual_action_required=false`, and the approved-open detector has no blockers.

`aerodrome:production_supervised_readiness` remains strict safe-mode evidence and can still report a blocker because mainnet ETH is not nil. During an approved adopt-existing start, the runner suppresses only that expected ETH-non-nil readiness blocker and turns it into a warning. Any unrelated readiness blocker, out-of-caps ETH, mismatch, unavailable readback, or manual-action state blocks the run. Emergency close remains manual and gated.

## Blockers

The watchdog still blocks:

- open ETH with no approved production live log.
- open ETH above caps.
- open ETH outside size tolerance.
- unknown or failed readback.
- failed/unacknowledged WETH rows.
- any successful USDC rebalance.
- logs with `manual_action_required=true`.
- unconfirmed or failed production live finishes.

Emergency close remains separate and manually gated.

## Stale Lock Handling

`aerodrome:production_live_status` distinguishes an active lock from a stale lock file. A lock file with a finished latest JSONL run is `stale_finished` and warning-only. Before removing it manually, verify no production live process is running, inspect the latest log, run current mainnet ETH readback, and confirm whether emergency close is needed. The watchdog/status tasks do not close positions.

## VPS Retest

The approved-open watchdog/readiness integration retest passed on VPS and is recorded in `docs/AERODROME_APPROVED_OPEN_WATCHDOG_VPS_RETEST_REPORT.md`. A 360 second production live run left an ETH short around `-0.0093` open by design, `approved_open_position` reported `approved`, `production_live_status` reported `PASS`, and `watchdog_alerts` returned `WARN` with no blockers because the open ETH was approved and within caps. The operator then ran the separately gated live emergency close, which closed ETH to nil. This remains supervised production mode only, not unattended 24/7 approval.

## Next Stage

This is supervised production monitoring only. It is not unattended 24/7 approval. Future work may add an explicit archive/acknowledgment workflow for approved-open logs that are later manually closed.
