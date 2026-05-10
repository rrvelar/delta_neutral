# Aerodrome Live Observation Window Report

This report records local operator evidence from a controlled Aerodrome to Hyperliquid mainnet live observation window. It is documentation only. It does not enable live trading, does not change environment variables, does not add execution tasks, and does not approve continuous unattended live operation.

## Scope

- Aerodrome WETH/USDC position only.
- Hyperliquid mainnet ETH short only.
- Controlled observation window with manual gates.
- Five observation iterations.
- Gated live emergency close at finish.
- No USDC hedge.
- No continuous/background automation.

## Date And Log Context

Operator log evidence:

- JSONL log path: `storage/aerodrome_live_observation/20260510030941-85bcd4e0.jsonl`
- Observation duration: `900` seconds.
- Observation interval: `180` seconds.
- Iteration count: `5`.
- First live observation rebalance: `ShortRebalance #184`, `rebalanced_at=2026-05-09 23:09:52 EDT`.

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
- max short ETH: `0.015`
- max short notional USD: `40`
- live emergency close enabled: `true`
- live emergency close confirmation valid: `true`
- live emergency close max ETH: `0.02`

These values were temporary observation gates. Persistent app env was restored to the safe disabled state after the run.

## Observation Loop Summary

The observation loop completed five iterations:

- Iteration 1 opened a tiny WETH/ETH hedge.
- Iterations 2 through 5 produced no new `ShortRebalance` rows.
- USDC side was skipped.
- No errors were recorded in the observation JSONL.
- Actual ETH short remained within the configured max cap.

## ShortRebalance #184

Iteration 1 created:

- `ShortRebalance #184`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size=0.0109`
- `status=success`
- `message=nil`
- `rebalanced_at=2026-05-09 23:09:52 EDT`

This proved only a tiny live mainnet WETH-side ETH short open during a manually gated observation window.

## Final Emergency Close

The live observation finished with the gated live emergency close:

- ETH position before close: `size=-0.0109`
- attempt 1 submitted explicit close size: `0.0109`
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

- A controlled 15-minute mainnet observation window can run under explicit manual gates.
- The WETH/ETH side can open a tiny mainnet ETH short through the existing hedge loop.
- The USDC side was skipped.
- No extra rebalances occurred during iterations 2 through 5.
- The live emergency close closed the ETH short at finish.
- Final mainnet and testnet ETH readbacks were nil.
- The app was returned to disabled, paused, not-live-approved safe state.

## What Was Not Proven

- Continuous unattended live operation was not proven.
- Larger sizing was not proven.
- Longer observation windows were not proven.
- Multiple live observation windows in sequence were not proven.
- Behavior during high volatility, stale position data, partial fills, network ambiguity, or API outages was not proven.
- Emergency close reliability under repeated mainnet failures was not proven.
- USDC hedging is still unsupported and intentionally skipped.

## Remaining Risks

- Mainnet market orders can lose money.
- Hyperliquid API, SDK, DNS, or network behavior can fail or return ambiguous responses.
- A later supervised 1-hour observation exposed exactly this finalization risk: SSL/readback failures occurred during finish/final close/readback, manual readback found an open `-0.011 ETH` short, and the manual gated live emergency close was required to close it.
- Observation finalization now records final close/readback errors, retries final readback, and reports `close_unknown`/`failed` with manual action required unless final mainnet ETH is confirmed nil. Further live windows should wait until this hardening is retested.
- Finalization hardening was later retested successfully in a supervised 15-minute live window, recorded in `docs/AERODROME_15M_FINALIZATION_RETEST_REPORT.md`. Final close status was `success`, final mainnet ETH position was `nil`, and `manual_action_required=false`.
- Aerodrome amounts and prices can move during an observation window.
- Emergency close may fail and require manual intervention.
- A successful 15-minute window does not validate scaling or unattended operation.
- Operator mistakes in live gates or persistent env restoration remain a live risk.

## Next Recommended Stage

Do not scale immediately. Do not enable continuous unattended live operation.

The next stage should be separately planned, with fresh approval and conservative constraints. Reasonable next steps are another controlled one-cycle run or a small live observation window with similarly tiny caps, fresh preflight, current backup, and emergency close readiness. Any scaling of size, duration, or automation requires a separate approval and safety review.

A later controlled 30-minute live observation window has also passed and is recorded in `docs/AERODROME_30M_LIVE_OBSERVATION_REPORT.md`. `ShortRebalance #185` opened a tiny mainnet ETH short (`0.0111`), iterations 2 through 10 created no additional rebalances, the gated live emergency close closed the short, and final mainnet ETH position was nil. This still is not approval for continuous unattended live operation or scaling.

The live observation guard now allows a separately approved supervised 1-hour window, but it remains a one-off manual tool. Close-on-finish and emergency close gates are still mandatory, and risk caps remain unchanged at max `0.02` ETH, max `$50` notional, and `1x` leverage unless a future review explicitly changes them.

The post-hardening 15-minute finalization retest passed, but it is still not approval for continuous unattended live operation. Any next stage should be separately planned with fresh preflight, backup, tiny caps, and emergency close readiness.
