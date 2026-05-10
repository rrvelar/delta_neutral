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

## Next Stage

This is supervised production monitoring only. It is not unattended 24/7 approval. Future work may add an explicit archive/acknowledgment workflow for approved-open logs that are later manually closed.
