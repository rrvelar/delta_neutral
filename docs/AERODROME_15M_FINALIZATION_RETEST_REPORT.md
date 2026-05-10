# Aerodrome 15-Minute Finalization Retest Report

This report records local operator evidence from a supervised Aerodrome to Hyperliquid mainnet finalization retest after observation finalization hardening. It is documentation only. It does not enable live trading, does not change environment variables, does not add execution tasks, and does not approve continuous unattended live operation.

## Scope

- Aerodrome WETH/USDC position only.
- Hyperliquid mainnet ETH short only.
- Supervised 15-minute observation window with manual gates.
- Five observation iterations.
- Hardened final close/readback finalization.
- Gated live emergency close at finish.
- No USDC hedge.
- No continuous/background automation.

## Why This Retest Was Needed

A supervised 1-hour live observation window previously exposed finalization/readback ambiguity. During finish/final close/readback, Hyperliquid SSL/readback errors occurred:

- `Faraday::SSLError: SSL_connect unexpected eof while reading`
- `Faraday::SSLError: SSL_read: record layer failure`

The observation task aborted during finalization. Manual mainnet readback then showed an open `-0.011 ETH` short. The separately gated `aerodrome:live_emergency_close` was run manually and succeeded, closing ETH to nil.

## Hardening Summary

Observation finalization was hardened so final close/readback failures are not surfaced as raw task crashes. The task now records final close/readback errors, retries final readback, includes `final_readback_attempts` and `manual_action_required` in output/JSONL, and only reports `success` when final mainnet ETH is confirmed nil.

## Retest Gates

Operator log evidence:

- JSONL log path: `storage/aerodrome_live_observation/20260510053407-5d37177d.jsonl`
- Observation duration: `900` seconds.
- Observation interval: `180` seconds.
- Iteration count: `5`.
- Max short ETH: `0.015`
- Max short notional USD: `40`
- `AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH=true`
- `AERODROME_LIVE_OBSERVATION_FINAL_READBACK_ATTEMPTS=5`
- `AERODROME_LIVE_OBSERVATION_FINAL_READBACK_SLEEP_SECONDS=10`
- live emergency close gates were present.

The JSONL path is historical evidence. Do not treat it as a command or a reusable live procedure.

## Observation Loop Summary

The retest completed five iterations:

- A tiny WETH/ETH hedge was opened during the run.
- `ShortRebalance #187` was created.
- USDC side was skipped.
- Final live emergency close succeeded.
- Final mainnet ETH position was nil.

## ShortRebalance #187

The retest created:

- `ShortRebalance #187`
- `asset=WETH`
- `old_short_size=0.0`
- `new_short_size` was around the tiny target short opened during the run.
- `status=success`

This proves only a tiny live mainnet WETH-side ETH short open during a supervised finalization retest.

## Final Emergency Close

The retest finished with hardened finalization and gated live emergency close:

- final close status: `success`
- final mainnet ETH position: `nil`
- manual action required: `false`
- final status: `success`

The close touched ETH only. USDC was not touched.

## Final Safety State

Final operator checks showed:

- current Hyperliquid mainnet ETH position: `nil`
- current Hyperliquid testnet ETH position: `nil`
- backup created after the successful 15-minute finalization retest.
- persistent app env restored to:
  - `AERODROME_HEDGE_ENABLED=false`
  - `AERODROME_HEDGE_PAUSED=true`
  - `AERODROME_LIVE_APPROVED=false`
  - `HYPERLIQUID_TESTNET=true`

## What Was Proven

- Hardened observation finalization can complete a supervised 15-minute mainnet retest.
- Final close status was `success`.
- Final mainnet ETH position was confirmed nil.
- `manual_action_required=false` was reported.
- The WETH/ETH side can still open and close a tiny mainnet ETH short under manual gates.
- USDC was skipped.
- Persistent app env was returned to disabled, paused, not-live-approved safe state.

## What Was Not Proven

- Continuous unattended live operation was not proven.
- Larger sizing was not proven.
- Longer post-hardening observation windows were not proven.
- Repeated live windows without manual review were not proven.
- Behavior during repeated Hyperliquid API, DNS, SSL, or readback failures was not proven.
- Emergency close reliability under every mainnet failure mode was not proven.
- USDC hedging remains unsupported and intentionally skipped.

## Remaining Risks

- Mainnet market orders can lose money.
- Hyperliquid API, SDK, DNS, or network behavior can fail or return ambiguous responses.
- Aerodrome amounts and prices can move during an observation window.
- Emergency close may still fail and require manual intervention.
- A successful 15-minute finalization retest does not validate scaling or unattended operation.
- Operator mistakes in live gates or persistent env restoration remain a live risk.

## Next Recommended Stage

Do not scale immediately. Do not enable continuous unattended live operation.

The next stage should be separately planned with fresh approval and conservative constraints. Any additional live observation should use fresh preflight, current backup, tiny caps, emergency close readiness, and explicit post-run verification that mainnet and testnet ETH positions are nil.

The live observation guard now allows a separately approved supervised 3-hour window, but it is still a one-off manual tool and not continuous unattended operation. It still requires explicit one-off env gates, close-on-finish, final readback retries, live emergency close gates, max `0.02` ETH, max `$50` notional, and `1x` leverage unless a future review changes those caps. For any 3-hour run, prefer interval >= 300 seconds, actively watch the run, and verify final mainnet ETH is nil. Next scaling requires separate review.
