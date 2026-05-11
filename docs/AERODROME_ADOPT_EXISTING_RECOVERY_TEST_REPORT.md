# Aerodrome Adopt-Existing Recovery Test Report

## Scope

This report records the VPS supervised production v1 adopt-existing recovery workflow test. The test verified that a production live run can intentionally leave an approved ETH hedge open, and a later supervised run can adopt that open hedge only when the explicit adopt gate is set and approved-open monitoring validates it.

This is audit documentation only. It does not enable live trading, add automation, or approve unattended 24/7 operation.

## Why This Test Matters

Production Live Runner V1 can leave an ETH hedge open on clean duration completion. A VPS restart, SSH disconnect, container restart, or operator handoff may require a follow-up supervised run to continue monitoring/rebalancing the already-open hedge. The normal safe-mode readiness check is intentionally strict and blocks open mainnet ETH, so the runner needs a narrow adopt-existing path that accepts only a known approved, in-cap ETH short.

## Step A: Open And Leave ETH Hedge

Step A ran `production_live_run` and opened the WETH hedge:

- `ShortRebalance #198`: WETH `0.0 -> 0.011`, status `success`
- runtime safety: `PASS`
- volatility guard: allowed the initial rebalance
- final status: `success`
- `position_left_open=true`
- `manual_action_required=false`

The run intentionally left the ETH short open as approved production live state.

## Step B: Adopt Existing Hedge

Step B ran `production_live_run` with:

- `AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true`

The runner adopted the existing approved ETH short:

- adopted position: ETH size about `-0.0109`
- start warning: `mainnet ETH is approved open hedge and is being adopted`
- runtime safety: `PASS`
- final status: `success`
- stop reason: `duration complete`
- final position: confirmed
- `position_left_open=true`
- `manual_action_required=false`

This confirms the adopt-existing path works only after approved-open monitoring validates the open ETH hedge.

## Volatility Guard Evidence

During Step B, the rebalance guard skipped an unnecessary rebalance because the last rebalance was within the configured `600` second minimum interval. This is expected behavior: after a recent successful rebalance, a redundant hedge sync should be skipped instead of forcing another order.

## Watchdog And Approved-Open Evidence

After Step B:

- `production_live_status`: `PASS`
- watchdog: `WARN`, not `BLOCKED`
- blockers: none

The warning state was expected because approved-open monitoring recognized the ETH hedge as intended state, while strict readiness remains safe-mode evidence.

## Manual Close And Final Safe State

The operator then manually closed the ETH short through the gated emergency close flow. Final state:

- mainnet ETH readback: `nil`
- testnet ETH position: `nil`
- persistent safe env restored:
  - `AERODROME_HEDGE_ENABLED=false`
  - `AERODROME_HEDGE_PAUSED=true`
  - `AERODROME_LIVE_APPROVED=false`
  - `HYPERLIQUID_TESTNET=true`

Latest post-close watchdog status was `WARN` only because:

- approved open hedge was no longer open;
- acknowledged failed row `#182` remains historical warning;
- fees remain `WARN` for known staked-NFT fee-read limitation.

Blockers were none.

## What Was Proven

- Production Live Runner V1 can leave an ETH hedge open on clean completion.
- A later supervised production live run can adopt that open ETH hedge only with `AERODROME_PRODUCTION_LIVE_ADOPT_EXISTING_ETH_SHORT=true`.
- Non-adopt mode remains strict and should block an already-open ETH position.
- Approved-open monitoring correctly validates the current ETH hedge before adoption.
- Strict readiness mainnet-ETH-non-nil blocker can be suppressed only for approved adopt-existing state.
- Volatility guard can skip an unnecessary rebalance after a recent rebalance.
- Manual emergency close returned mainnet ETH to nil.

## What Was Not Proven

- Unattended restart/adoption was not proven.
- Multi-hour adopt-existing sessions were not proven.
- Behavior during high volatility, partial fills, API outages, or stale Aerodrome data was not proven.
- Automatic close or automatic recovery was not implemented.
- USDC remains unsupported.

## Remaining Risks

- Hyperliquid readback can fail or become delayed.
- Approved-open JSONL state can become stale and must be compared with current readback.
- Volatility guard thresholds may need further tuning.
- Operator error remains possible when using one-off live gates.
- Emergency close must remain available and manually gated.

## Next Recommended Stage

The next stage can be either:

- a longer supervised production session with approved-open/adopt-existing monitoring active, or
- an explicit unattended/restart design that is reviewed separately.

Do not add unattended scheduling, automatic adoption, or automatic close behavior without a separate implementation and approval.
