# Aerodrome 3-Hour Live Observation Report

This report records local operator evidence from a controlled supervised Aerodrome to Hyperliquid mainnet 3-hour live observation window. It is documentation only. It does not enable live trading, does not change environment variables, does not add execution tasks, and does not approve continuous unattended live operation.

## Scope

- Aerodrome WETH/USDC position only.
- Hyperliquid mainnet ETH short only.
- Supervised 3-hour observation window with manual gates.
- Thirty-six observation iterations.
- Gated live emergency close at finish.
- Hardened final close/readback finalization.
- No USDC hedge.
- No continuous/background automation.

## Date And Log Context

Operator log evidence:

- JSONL log path: `storage/aerodrome_live_observation/20260510060157-63f690ea.jsonl`
- Observation duration: `10800` seconds.
- Observation interval: `300` seconds.
- Iteration count: `36`.
- First rebalance in this window: `ShortRebalance #188`, `rebalanced_at` around `2026-05-10 02:02:08 EDT`.

The JSONL path is historical evidence. Do not treat it as a command or a reusable live procedure.

## Preconditions And Gates

The observation window was run with manual live gates:

- `HYPERLIQUID_TESTNET=false`
- `AERODROME_LIVE_APPROVED=true`
- `AERODROME_HEDGE_ENABLED=true`
- `AERODROME_HEDGE_PAUSED=false`
- `AERODROME_LIVE_OBSERVATION_ENABLED=true`
- observation confirmation valid: `true`
- duration seconds: `10800`
- interval seconds: `300`
- `AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH=true`
- max leverage: `1`
- max short ETH: `0.02`
- max short notional USD: `50`
- live emergency close enabled: `true`
- live emergency close confirmation valid: `true`
- live emergency close max ETH: `0.025`

These values were temporary observation gates. Persistent app env was restored to the safe disabled state after the run.

## Observation Loop Summary

The observation loop completed thirty-six iterations:

- Iteration 1 opened a tiny WETH/ETH hedge.
- Iterations 2 through 36 produced no new `ShortRebalance` rows.
- USDC side was skipped.
- No errors were recorded in the observation JSONL.
- Actual ETH short remained within the configured max cap.

## ShortRebalance #188

Iteration 1 created:

- `ShortRebalance #188`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size=0.011`
- `status=success`
- `message=nil`
- `rebalanced_at` around `2026-05-10 02:02:08 EDT`

This proved only a tiny live mainnet WETH-side ETH short open during a manually gated 3-hour observation window.

## Final Emergency Close

The live observation finished with the gated live emergency close:

- ETH position before close: `size=-0.011`
- attempt 1 submitted explicit close size: `0.011`
- ETH position after close: `nil`
- final close status: `success`
- final position: `nil`
- final position confirmed: `true`
- final readback attempts included success with position `nil`
- manual action required: `false`
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

- A supervised 3-hour mainnet observation window can run under explicit manual gates.
- The WETH/ETH side can open a tiny mainnet ETH short through the existing hedge loop.
- The USDC side was skipped.
- No extra rebalances occurred during iterations 2 through 36.
- Actual ETH short stayed within the configured cap.
- Hardened finalization and the live emergency close closed the ETH short at finish.
- Final mainnet ETH readback was nil and confirmed.
- `manual_action_required=false` was reported.
- The app was returned to disabled, paused, not-live-approved safe state.

## What Was Not Proven

- Continuous unattended live operation was not proven.
- Larger sizing was not proven.
- Production supervised mode was not implemented or proven.
- Watchdog, alerting, healthcheck, log retention, VPS/uptime, and stop/close procedures were not proven.
- Multiple long windows without manual review between them were not proven.
- Behavior during high volatility, stale position data, partial fills, network ambiguity, or API outages was not proven.
- Emergency close reliability under repeated mainnet failures was not proven.
- USDC hedging remains unsupported and intentionally skipped.

## Remaining Risks

- Mainnet market orders can lose money.
- Hyperliquid API, SDK, DNS, or network behavior can fail or return ambiguous responses.
- Aerodrome amounts and prices can move during an observation window.
- Emergency close may fail and require manual intervention.
- A successful 3-hour observation window does not validate scaling or unattended operation.
- Operator mistakes in live gates or persistent env restoration remain a live risk.

## Next Recommended Stage

Do not scale immediately. Do not enable continuous unattended live operation.

The next stage should be production supervised mode planning, not larger sizing. That plan should cover watchdog behavior, alerts, healthchecks, log retention, VPS/uptime expectations, runbook ownership, and clear stop/close rules before any longer or more operationally ambitious live run is approved.
