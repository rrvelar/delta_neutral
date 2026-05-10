# Aerodrome 30-Minute Live Observation Report

This report records local operator evidence from a controlled Aerodrome to Hyperliquid mainnet 30-minute live observation window. It is documentation only. It does not enable live trading, does not change environment variables, does not add execution tasks, and does not approve continuous unattended live operation.

## Scope

- Aerodrome WETH/USDC position only.
- Hyperliquid mainnet ETH short only.
- Controlled 30-minute observation window with manual gates.
- Ten observation iterations.
- Gated live emergency close at finish.
- No USDC hedge.
- No continuous/background automation.

## Date And Log Context

Operator log evidence:

- JSONL log path: `storage/aerodrome_live_observation/20260510033339-f73ede36.jsonl`
- Observation duration: `1800` seconds.
- Observation interval: `180` seconds.
- Iteration count: `10`.
- First rebalance in this window: `ShortRebalance #185`, `rebalanced_at=2026-05-09 23:33:49 EDT`.

The JSONL path is historical evidence. Do not treat it as a command or a reusable live procedure.

## Preconditions And Gates

The observation window was run with manual live gates:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_LIVE_OBSERVATION_ENABLED=true`
- observation confirmation valid: `true`
- `AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH=true`
- max leverage: `1`
- max short ETH: `0.02`
- max short notional USD: `50`
- live emergency close enabled: `true`
- live emergency close confirmation valid: `true`
- live emergency close max ETH: `0.025`

These values were temporary observation gates. Persistent app env was restored to the safe disabled state after the run.

## Observation Loop Summary

The observation loop completed ten iterations:

- Iteration 1 opened a tiny WETH/ETH hedge.
- Iterations 2 through 10 produced no new `ShortRebalance` rows.
- USDC side was skipped.
- No errors were recorded in the observation JSONL.
- Actual ETH short remained within the configured max cap.

## ShortRebalance #185

Iteration 1 created:

- `ShortRebalance #185`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size=0.0111`
- `status=success`
- `message=nil`
- `rebalanced_at=2026-05-09 23:33:49 EDT`

This proved only a tiny live mainnet WETH-side ETH short open during a manually gated 30-minute observation window.

## Final Emergency Close

The live observation finished with the gated live emergency close:

- ETH position before close: `size=-0.0111`
- attempt 1 submitted explicit close size: `0.0111`
- ETH position after close: `nil`
- final close status: `success`
- final mainnet ETH position: `nil`
- errors: `[]`

The close touched ETH only. USDC was not touched.

## Final Safety State

Final operator checks showed:

- current Hyperliquid mainnet ETH position: `nil`
- current Hyperliquid testnet ETH position: `nil`
- backup created after observation.
- persistent app env restored to:
  - `AERODROME_HEDGE_ENABLED=false`
  - `AERODROME_HEDGE_PAUSED=true`
  - `AERODROME_LIVE_APPROVED=false`
  - `HYPERLIQUID_TESTNET=true`

## What Was Proven

- A controlled 30-minute mainnet observation window can run under explicit manual gates.
- The WETH/ETH side can open a tiny mainnet ETH short through the existing hedge loop.
- The USDC side was skipped.
- No extra rebalances occurred during iterations 2 through 10.
- The live emergency close closed the ETH short at finish.
- Final mainnet and testnet ETH readbacks were nil.
- The app was returned to disabled, paused, not-live-approved safe state.

## What Was Not Proven

- Continuous unattended live operation was not proven.
- Larger sizing was not proven.
- Observation windows longer than 30 minutes were not proven.
- Multiple live observation windows without manual review between them were not proven.
- Behavior during high volatility, stale position data, partial fills, network ambiguity, or API outages was not proven.
- Emergency close reliability under repeated mainnet failures was not proven.
- USDC hedging is still unsupported and intentionally skipped.

## Remaining Risks

- Mainnet market orders can lose money.
- Hyperliquid API, SDK, DNS, or network behavior can fail or return ambiguous responses.
- A later supervised 1-hour observation exposed finalization ambiguity from Hyperliquid SSL/readback errors during finish/final close/readback. Manual readback found an open `-0.011 ETH` short, and the manual gated live emergency close was required and succeeded.
- Observation finalization now treats an unconfirmed final close/readback as `close_unknown` or `failed`, records final readback attempts, and requires manual action when final ETH is unknown or open. More live windows should be avoided until this hardening is retested.
- Aerodrome amounts and prices can move during an observation window.
- Emergency close may fail and require manual intervention.
- A successful 30-minute window does not validate scaling or unattended operation.
- Operator mistakes in live gates or persistent env restoration remain a live risk.

## Next Recommended Stage

Do not scale immediately. Do not enable continuous unattended live operation.

The next stage should be separately planned with fresh approval and conservative constraints. Reasonable next steps are a controlled one-cycle run or another bounded observation window with current backup, fresh preflight, tiny caps, and emergency close readiness. Any increase in size, duration, or automation requires a separate approval and safety review.

The observation guard now permits a separately approved supervised 1-hour window. This does not change the hard risk caps: max `0.02` ETH, max `$50` notional, `1x` leverage, close-on-finish, and mandatory emergency close gates still apply unless a future safety review explicitly changes them. A 1-hour run is not continuous unattended live operation.
