# Aerodrome First Live Micro-Run Runbook

This document is a planning runbook only. It does not enable live trading, does not change environment variables, does not add an execution task, and does not authorize a live run.

The first live micro-run has completed and is recorded in `docs/AERODROME_FIRST_LIVE_MICRO_RUN_REPORT.md`. `ShortRebalance #183` successfully opened a tiny mainnet ETH short from the Aerodrome WETH side, the USDC side was skipped, and the gated live emergency close successfully closed the short. Final mainnet ETH position was nil. This milestone is not approval for continuous live operation, and the default state remains disabled, paused, and not live-approved.

Current safe production state remains:

```bash
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
HYPERLIQUID_TESTNET=true
```

## Verified Inputs

Sources checked on 2026-05-10:

- Hyperliquid exchange endpoint docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint`
  - Verified exchange endpoint actions are signed order/transfer operations.
  - Verified `vaultAddress` is used for vault/subaccount execution contexts.
  - Verified some actions support `expiresAfter`.
- Hyperliquid nonces and API wallets docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets`
  - Verified API wallets are signing wallets only.
  - Verified account data must be queried by master/subaccount address, not the agent/API wallet address.
- Hyperliquid sub-account docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/trading/sub-accounts`
  - Verified subaccounts share master fee tiers and API wallet capacity is account/subaccount related.
- Hyperliquid info endpoint docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint`
  - Verified read-only user/subaccount/vault state queries exist.
- Hyperliquid order type docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/trading/order-types`
  - Verified market orders execute immediately at current market price.
- Aerodrome Slipstream `INonfungiblePositionManager.sol`: `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol`
  - Verified `positions(tokenId)` is read-only and `collect` is a separate write/payable method.
- Aerodrome Slipstream `ICLGauge.sol`: `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/gauge/interfaces/ICLGauge.sol`
  - Verified staked CL positions receive emissions instead of fees, and reward/withdraw/claim behavior is separate from this runbook.
- Local code:
  - `HedgeSyncJob` gates Aerodrome execution behind `AERODROME_HEDGE_ENABLED`, `AERODROME_HEDGE_PAUSED`, `AERODROME_LIVE_APPROVED`, readiness checks, risk limits, and ETH/WETH-only filtering.
  - `AerodromeLivePreflightCheck` is read-only and requires live-mode env to remain disabled/paused during preflight.
  - `AerodromeTestnetEmergencyClose` is testnet-only.
  - `AerodromeLiveEmergencyClose` is live-order capable but blocked by default and only closes ETH when all manual emergency gates pass.

## Preconditions

First live micro-run is forbidden unless all are true:

- `git status --short` is clean.
- Latest `bin/rake` passes.
- Database/storage backup is created and restorable.
- Dashboard is healthy and current Aerodrome position data is fresh.
- `bin/rails aerodrome:pre_live_check` passes.
- `CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check` passes in mainnet read-only mode.
- Hyperliquid mainnet readback shows no existing ETH short for the account/subaccount that will be used.
- A live emergency close procedure exists, is documented, and has been tested/read-reviewed separately. `bin/rails aerodrome:live_emergency_close` is live-order capable and must remain blocked unless its explicit manual gates are set.
- Operator manually confirms risk, limits, target hedge, account address, API wallet setup, and emergency-close responsibility.
- No seed phrase or main wallet private key is stored in git or pasted into logs. Prefer an approved API wallet where possible.

## First-Live Env Values To Apply Manually Later

Do not apply these values as part of this document. This is the intended shape of a future manual first-live configuration only:

```bash
HYPERLIQUID_TESTNET=false
AERODROME_LIVE_APPROVED=true
AERODROME_HEDGE_ENABLED=true
AERODROME_HEDGE_PAUSED=false
AERODROME_MAX_LEVERAGE=1
AERODROME_MAX_SHORT_ETH=<operator-defined tiny ETH cap>
AERODROME_MAX_SHORT_NOTIONAL_USD=<operator-defined tiny USD cap>
AERODROME_MIN_ORDER_NOTIONAL_USD=10
AERODROME_REWARDS_ENABLED=true
AERODROME_AERO_USD_VALUATION_ENABLED=true
AERODROME_FEES_ENABLED=true
```

`AERODROME_LIVE_APPROVED=true` is not enough by itself. `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, complete persisted Aerodrome data, explicit `Hedge`, configured risk limits, ETH/WETH-only exposure, and Hyperliquid mainnet mode are still required.

## Micro-Run Size

The first run should be intentionally tiny and operator-defined. A conservative example is:

- max short notional: 20-50 USD
- max short ETH: consistent with that notional at current ETH price
- leverage: 1 only
- minimum order notional: 10 USD

This is not financial advice. The operator must choose limits and accept that a live order can lose money.

## Manual Sequence

This is a conceptual sequence only. Do not paste or run a live command from this section.

1. Stop web/jobs so the normal recurring scheduler cannot race the run.
2. Create and verify a backup of SQLite/Solid Queue storage and any deployment state needed for rollback.
3. Confirm `git status --short` is clean and `bin/rake` passed on the exact revision being used.
4. Run the normal read-only health checks:
   - `bin/rails aerodrome:pre_live_check`
   - `CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check`
5. Confirm Hyperliquid mainnet readback shows no existing ETH short on the intended account/subaccount.
6. Prepare a one-off live environment with explicit first-live overrides and tiny risk caps.
7. Run exactly one `HedgeSyncJob` for the explicit Aerodrome hedge id.
8. Immediately read Hyperliquid mainnet ETH position and account state.
9. Restore safe env/web state:
   - `AERODROME_HEDGE_ENABLED=false`
   - `AERODROME_HEDGE_PAUSED=true`
   - `AERODROME_LIVE_APPROVED=false`
10. Monitor logs, dashboard, ShortRebalance history, and Hyperliquid position state.
11. If anything unexpected occurs, close manually or use the separately verified live emergency close procedure. Do not rely on the testnet-only emergency close task.

## Live Emergency Close Procedure

`bin/rails aerodrome:live_emergency_close` exists only as an emergency close tool. It is live-order capable but blocked by default. It closes ETH only and never opens positions, never touches USDC, never calls `set_leverage`, and never calls Aerodrome contracts.

It refuses unless all gates are set:

```bash
HYPERLIQUID_TESTNET=false
AERODROME_LIVE_APPROVED=true
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED=true
AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM=I_UNDERSTAND_THIS_CLOSES_LIVE_ETH_SHORT
AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH=<operator-defined max close size>
```

Optional retry controls:

```bash
AERODROME_LIVE_CLOSE_RETRY_ATTEMPTS=5
AERODROME_LIVE_CLOSE_RETRY_SLEEP_SECONDS=10
```

The live emergency close tool must be tested/read-reviewed before any first-live micro-run. Its existence is not approval to trade and not approval to leave live gates enabled.

Example command shape, intentionally commented and incomplete:

```bash
# DO NOT RUN - TEMPLATE ONLY
# HYPERLIQUID_TESTNET=false \
# AERODROME_LIVE_APPROVED=true \
# AERODROME_HEDGE_ENABLED=true \
# AERODROME_HEDGE_PAUSED=false \
# AERODROME_MAX_LEVERAGE=1 \
# AERODROME_MAX_SHORT_ETH=... \
# AERODROME_MAX_SHORT_NOTIONAL_USD=... \
# bin/rails runner 'HedgeSyncJob.perform_now(HEDGE_ID)'
```

## Risk Checklist

- Live orders can lose money.
- Hyperliquid API, DNS, network, or SDK behavior can fail or return ambiguous results.
- A market order can partially execute, execute at worse price than expected, or fail.
- Aerodrome position amounts and prices can change during the run.
- Testnet success does not guarantee mainnet behavior.
- The bot uses market-order behavior through the existing Hyperliquid path; market orders execute immediately at the current market price.
- Hyperliquid API wallets are signing wallets only; readback must use the actual master/subaccount address.
- Subaccount/vault execution uses `vaultAddress`; confirm account mode before the run.
- The live emergency close procedure must be ready before any first-live run and must be blocked again after use.
- Never use a seed phrase in env.
- Never commit `.env`, private keys, wallet secrets, API secrets, screenshots of secrets, or logs containing secrets.
- Dashboard rewards and fees are read-only estimates and are not execution approval.

## Stop Conditions

Do not proceed if any of these are true:

- `bin/rake` fails.
- `git status --short` is dirty.
- Preflight is blocked or warning is not understood.
- Preflight is blocked by a failed WETH rebalance after the last close that has not been reviewed and explicitly acknowledged.
- Live readback cannot confirm no existing ETH short.
- Risk caps are missing, parse incorrectly, or are larger than the intended tiny first-live run.
- `AERODROME_HEDGE_PAUSED` is not known to be restored to true after the run.
- Live emergency close is not ready, not reviewed, or not blocked by default.
- Operator cannot monitor the run continuously.

## Rollback / Safe State

The safe state after the micro-run must be restored immediately:

```bash
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
```

Then run:

```bash
CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check
```

If an ETH short remains open unexpectedly, use the gated live emergency close procedure or close manually. Do not use `aerodrome:testnet_emergency_close` on mainnet.

## Failed No-Position Acknowledgment

Failed `ShortRebalance` records from live attempts must not be deleted. If a reviewed WETH/ETH failure has `old_short_size=0`, `new_short_size=0`, and mainnet readback confirms `get_position("ETH") = nil`, an operator may acknowledge that specific row with `bin/rails aerodrome:acknowledge_failed_rebalance` using the required id and confirmation env values. The task appends `[operator_acknowledged_no_open_position]` to the row message only; it does not change status, sizes, or history.

This acknowledgment is only for reviewed zero-size failures where no mainnet ETH position exists. It is not live approval, does not permit trading, and does not replace a fresh preflight plus separate manual approval before any repeat micro-run.
