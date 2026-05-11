# Aerodrome New Position First Live Run Report

## Scope

This report records the first real supervised 1x production hedge run for the new direct Aerodrome Slipstream WETH/USDC position. It is historical audit evidence only. It does not enable live trading, approve unattended operation, or add any execution path.

## New Position

- Aerodrome Slipstream token id: `70184676`
- Position manager: `0x827922686190790b37229fd06084350e74485b72`
- Factory: `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`
- Synced WETH amount: about `0.391` to `0.396`
- Synced USDC amount: about `902` to `904`
- Hedge target: `1.0`

The position manager and factory config had to be updated because this direct Slipstream NFT was read through the Aerodrome position manager/factory pair above. The sync succeeded only after those deployment addresses were supplied explicitly. This keeps deployment-specific Aerodrome assumptions out of code and preserves the existing env-configured verification model.

The wallet/ownership check remains operationally important: for direct positions, `ownerOf(tokenId)` should correspond to the expected operator wallet or an expected custody/staking address before relying on the position for live hedging. No private keys or wallet secrets are recorded here.

## Caps Used

- `AERODROME_MAX_SHORT_ETH=0.55`
- `AERODROME_MAX_SHORT_NOTIONAL_USD=1300`
- `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=0.60`
- `AERODROME_MAX_LEVERAGE=1`
- `AERODROME_MIN_ORDER_NOTIONAL_USD=10`

These caps are inside the Production Live Runner V1 supervised production tier and above the micro canary/observation/target-step caps. They are still small supervised-production limits, not approval to scale further.

## Live Run Evidence

- Task: `aerodrome:production_live_run`
- Duration: `1800` seconds
- Interval: `300` seconds
- Log path: `/rails/storage/aerodrome_production_live/20260511061531-efded24a.jsonl`
- Iterations: `6`
- Rebalances count: `1`
- `leave_position_open=true`
- `close_on_error=true`
- Final status: `success`
- Stop reason: `duration complete`
- `final_position_confirmed=true`
- `position_left_open=true`
- `manual_action_required=false`

## Rebalance #200

`ShortRebalance #200` opened the WETH-side hedge:

- asset: `WETH`
- old short size: `0.0`
- new short size: `0.3912`
- status: `success`

USDC remained unsupported and was not used as a hedge side.

## Volatility Guard

The volatility guard behaved as intended:

- initial rebalance was allowed;
- later small rebalance was skipped because the previous successful rebalance was within the configured `600` second minimum-rebalance interval.

The skip was expected risk control, not a failure. The guard did not close positions and did not bypass emergency close.

## Approved-Open And Watchdog

After clean duration completion:

- approved-open monitoring reported `approved`;
- `production_live_status` reported `PASS`;
- `watchdog_alerts` reported `WARN`, not `BLOCKED`;
- watchdog blockers were empty.

The warning state is expected because strict production readiness remains safe-mode evidence, while approved-open monitoring recognizes the in-cap ETH short as intended state after a successful leave-position-open run.

## Manual Close

The operator later ran the separately gated live emergency close:

- before position: about `-0.3912 ETH`
- attempt 1 submitted size: `0.3912`
- after position: `nil`
- final status: `success`

Final mainnet ETH readback was nil.

## Final Safe State

Persistent env was restored safe after the run:

- `AERODROME_HEDGE_ENABLED=false`
- `AERODROME_HEDGE_PAUSED=true`
- `AERODROME_LIVE_APPROVED=false`
- `HYPERLIQUID_TESTNET=true`
- testnet ETH position: nil

The web/dashboard should remain running during production live runs so the operator can monitor PnL and status through the SSH tunnel.

## Proven

- The new token id `70184676` can be synced with the configured Aerodrome position manager/factory.
- A supervised 1x WETH-side hedge opened successfully at real production size within `0.55 ETH` / `$1300` caps.
- `ShortRebalance #200` recorded the successful `0.3912 ETH` hedge open.
- Runtime safety stayed `PASS`.
- Approved-open monitoring recognized the intentional open ETH hedge.
- Watchdog produced `WARN` with no blockers rather than false `BLOCKED`.
- Manual gated emergency close closed the hedge to nil.
- Safe persistent env was restored.

## Not Proven

- Unattended 24/7 production operation.
- Larger caps than the reviewed production tier.
- Multi-day restart and process-supervision behavior.
- High-volatility rebalance behavior at larger size.
- USDC hedging; USDC remains unsupported.
- Automatic close by watchdog; emergency close remains separate and manual.

## Remaining Risks

- Hyperliquid/API readback failures can still create operator ambiguity and require manual verification.
- Aerodrome position sync depends on correct manager/factory and wallet/ownership assumptions.
- Approved-open monitoring depends on current readback and JSONL log integrity.
- Longer runtime can expose VPS, SSH, Docker, or network issues not covered by a 30-minute run.
- Any increase in notional or autonomy needs separate review.

## Next Stage

The next stage can be a longer supervised production run on token id `70184676` with approved-open monitoring active, dashboard/web kept online, backups before and after, and explicit operator approval. The alternative next stage is explicit unattended-design work covering restart/adopt rules, watchdog escalation, alert delivery, process supervision, and final-close guarantees.
