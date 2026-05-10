# Aerodrome First Live Micro-Run Report

This report records local operator evidence from the first Aerodrome to Hyperliquid mainnet micro-run. It is documentation only. It does not enable live trading, does not change environment variables, does not add execution tasks, and does not approve continuous live operation.

## Date And Scope

Evidence was recorded from operator logs around `ShortRebalance #182` and `ShortRebalance #183`. The successful open rebalance was recorded at `2026-05-09 22:46:09.646081 EDT`.

Scope:

- Aerodrome WETH/USDC position only.
- Hyperliquid mainnet ETH short only.
- One manual live micro-run retry with a tiny target.
- One manually gated live emergency close.
- No continuous live automation.
- No USDC hedge.

## Safety State Before Run

The persistent safe production state was restored after the run and remains the required default:

```text
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

The live micro-run itself required temporary manual live gates outside persistent safe state. Those historical values are not commands and must not be reused without a separate fresh procedure.

## Failed First Attempt

The first live attempt failed before the response-validation hardening:

- `ShortRebalance #182`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size=0.0`
- `status=failed`
- message included `Attempted rebalance to 0.0111 ETH: String does not have #dig method`

Mainnet ETH position was verified nil after this failed attempt. The row was preserved and later acknowledged by appending:

```text
[operator_acknowledged_no_open_position]
```

The failure history was not deleted, rewritten as success, or removed from the audit trail.

## Successful Open

The retry used a tiny target:

- `target=0.01`
- WETH amount: `1.108741661191614`
- WETH price: `2326.04295495`
- target short: `0.011 ETH`
- target notional: `25.58647250445 USD`
- before ETH position: `nil`
- job: one manual `HedgeSyncJob` run for `hedge_id=1`
- USDC side: skipped

Result:

- `ShortRebalance #183`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size=0.011`
- `status=success`
- `message=nil`
- `rebalanced_at=2026-05-09 22:46:09.646081 EDT`

After-open Hyperliquid readback:

- size: `-0.011 ETH`
- entry price: approximately `2325.3`
- position value: approximately `25.5761`
- margin used: approximately `25.5761`

## Live Emergency Close

The gated live emergency close was run manually with all required gates:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED=true`
- exact confirmation phrase present
- max close ETH: `0.02`

Close evidence:

- ETH position before close: `size=-0.011`
- attempt 1 submitted explicit close size: `0.011`
- ETH position after close: `nil`
- final status: `success`

The close touched ETH only. USDC was not touched.

## Final Verification

Final operator checks showed:

- current Hyperliquid mainnet ETH position: `nil`
- current Hyperliquid testnet ETH position: `nil`
- persistent app env restored to safe disabled state:
  - `AERODROME_HEDGE_ENABLED=false`
  - `AERODROME_HEDGE_PAUSED=true`
  - `AERODROME_LIVE_APPROVED=false`
  - `HYPERLIQUID_TESTNET=true`
- backup created after the successful first live micro-run.

## What Was Proven

- The Aerodrome WETH/ETH side can enter the existing hedge loop under explicit manual live gates.
- The USDC side was skipped during the live micro-run.
- A tiny mainnet ETH short was opened and recorded as `ShortRebalance #183`.
- Hyperliquid readback showed the expected tiny ETH short after open.
- The gated live emergency close successfully closed the tiny ETH short.
- Final mainnet and testnet ETH readbacks were nil.
- The app was returned to disabled, paused, not-live-approved safe state.

## What Was Not Proven

- Continuous live operation was not proven.
- Multi-cycle live rebalancing was not proven.
- Larger position sizing was not proven.
- Live behavior under network errors, partial fills, volatile markets, or stale Aerodrome data was not proven.
- Live emergency close reliability across repeated failures was not proven.
- USDC hedging was not tested or supported; USDC remains intentionally skipped.
- AERO rewards, LP fees, and dashboard estimates are not execution approval.

## Remaining Risks

- Mainnet market orders can lose money.
- Hyperliquid API, SDK, DNS, or network behavior can fail or return ambiguous responses.
- Aerodrome position amounts and prices can change between readback and order submission.
- Emergency close may fail or require manual intervention.
- The first successful run was intentionally tiny and does not validate scaling.
- Operator error in environment gates can still create live risk.

## Next Recommended Stage

Do not scale immediately. Do not enable continuous live automation.

The next stage should be a separately planned small live observation window or controlled one-cycle run with:

- fresh `bin/rake` pass;
- clean git status;
- current backup;
- read-only preflight and live preflight;
- confirmed nil mainnet ETH position before start;
- tiny operator-defined risk caps;
- live emergency close ready and gated;
- explicit manual approval for that single stage only.
