# Aerodrome Operator Runbook

This runbook is for read-only Aerodrome Slipstream verification on Base. It is not approval to enable live hedge execution.

## Current Architecture Summary

- Existing production behavior remains Uniswap V3 LP monitoring plus Hyperliquid hedge execution.
- `AerodromeSlipstreamService` is a read-only JSON-RPC client for selected Aerodrome Slipstream position manager and factory addresses.
- `AerodromeSlipstreamDryRun` wraps the service for manual token-id verification without database writes.
- Aerodrome monitor-only sync is gated by `AERODROME_READ_ONLY_ENABLED=true` and explicit token ids.
- Monitor-only sync stores verified computed token amounts in existing `Position` amount fields.
- Monitor-only USD valuation preview is available only for pools with the configured USDC quote token; unsupported pairs keep USD prices nil.
- Monitor-only hedge preview is available only for configured WETH/USDC positions and never executes orders.
- Manual hedge proposals are local database records only. They can suggest a short ETH amount/notional for an Aerodrome WETH/USDC monitor-only position, retain local history/status, and show local safety-limit results, but they do not create `Hedge` records, do not call Hyperliquid, and do not place orders.
- The Rails UI displays Aerodrome positions as monitor-only, including safety labels and display-only hedge preview status.
- `HedgeSyncJob` skips Aerodrome positions while `AERODROME_HEDGE_ENABLED=false`, which is the default.
- If `AERODROME_HEDGE_ENABLED=true`, Aerodrome positions may enter the existing `HedgeSyncJob` path only for testnet rehearsal when `HYPERLIQUID_TESTNET=true`, an explicit `Hedge` exists, and persisted asset/amount/price data is complete. The Aerodrome hedge gate supports only the ETH/WETH side; USDC and all other symbols are skipped and never hedged. This reuses `HyperliquidService` unchanged and adds no new execution path.

## Implemented

- Read-only Aerodrome position fetches for explicit token ids.
- Read-only amount0/amount1 math using verified Aerodrome Slipstream `TickMath` and `LiquidityAmounts` formulas.
- Monitor-only `WalletSyncJob` and `PositionSyncJob` persistence for verified computed token amounts.
- Monitor-only USD valuation preview for configured-USDC pools.
- Read-only Aerodrome PnL snapshots from persisted token amounts and USD prices.
- Monitor-only hedge preview for configured WETH/USDC pools.
- Manual, non-executing hedge proposal records for configured WETH/USDC monitor-only positions.
- Manual proposal lifecycle and recent-history UI with draft/reviewed/rejected/expired statuses.
- Local proposal safety-limit checks for optional maximum short ETH, maximum short notional, maximum LP value, and maximum stale percent.
- UI/dashboard visibility for Aerodrome monitor-only positions.
- Manual dry-run task: `bin/rails aerodrome:dry_run`.
- Config verification task: `bin/rails aerodrome:verify_config`.
- Read-only pre-live readiness task: `bin/rails aerodrome:pre_live_check`.
- Read-only AERO rewards discovery task: `bin/rails aerodrome:rewards_check`.
- First live micro-run planning runbook: `docs/AERODROME_FIRST_LIVE_MICRO_RUN.md`.
- First live micro-run evidence report: `docs/AERODROME_FIRST_LIVE_MICRO_RUN_REPORT.md`.
- Mocked tests for dry-run and config verification.
- Documentation for limitations, rollback, and pre-live audit.

## Not Implemented

- Live trading.
- First live micro-run execution task.
- Automatic live emergency close. The live emergency close task is manual-only and blocked by default.
- Aerodrome hedge execution by default.
- Any new Aerodrome-specific Hyperliquid order path.
- Hyperliquid hedge preview execution.
- Proposal execution. Proposal review is only a local status change and is not order approval.
- Automatic use of reviewed proposals for any trading workflow.
- Enforced trading risk management. Proposal safety limits are local review gates only and do not execute, size, or submit trades.
- USD valuation for non-USDC pools.
- Aerodrome fee PnL. Aerodrome snapshot fees remain zero until a separate fee-read task is implemented.
- Staking/gauge/escrow discovery.
- Multi-manager automatic discovery.
- UI for Aerodrome-specific metadata.

## Run Tests

```bash
bin/rake
```

Expected result: tests and RuboCop pass with no failures or offenses.

## Required Env Vars

Use placeholders here; do not paste secrets into docs:

```env
BASE_RPC_URL=BASE_RPC_URL_PLACEHOLDER
AERODROME_SLIPSTREAM_POSITION_MANAGER=POSITION_MANAGER_ADDRESS_PLACEHOLDER
AERODROME_SLIPSTREAM_FACTORY=FACTORY_ADDRESS_PLACEHOLDER
AERODROME_SLIPSTREAM_TOKEN_IDS=TOKEN_ID_PLACEHOLDER
AERODROME_USDC_ADDRESS=BASE_USDC_ADDRESS_PLACEHOLDER
AERODROME_WETH_ADDRESS=BASE_WETH_ADDRESS_PLACEHOLDER
AERODROME_VOTER_ADDRESS=
AERODROME_AERO_TOKEN_ADDRESS=
AERODROME_REWARDS_ENABLED=false
AERODROME_MAX_SHORT_ETH=
AERODROME_MAX_SHORT_NOTIONAL_USD=
AERODROME_MAX_LEVERAGE=1
AERODROME_MAX_LP_VALUE_USD=
AERODROME_MAX_PROPOSAL_STALE_PERCENT=0.5
AERODROME_READ_ONLY_ENABLED=false
AERODROME_HEDGE_ENABLED=false
AERODROME_HEDGE_PAUSED=true
AERODROME_LIVE_APPROVED=false
AERODROME_REQUIRE_HYPERLIQUID_TESTNET=true
```

No private keys are required for Aerodrome dry-run or config verification.

## Verify Config

Static validation only, no RPC:

```bash
bin/rails aerodrome:verify_config
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:verify_config
```

Read-only RPC checks:

```bash
CHECK_RPC=true bin/rails aerodrome:verify_config
```

`CHECK_RPC=true` uses only `eth_chainId` and `eth_getCode`. It does not use `eth_sendTransaction` or `eth_sendRawTransaction`.

## Run Dry-Run

Human-readable output:

```bash
bin/rails aerodrome:dry_run TOKEN_IDS=5016
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:dry_run TOKEN_IDS=5016
```

The task de-duplicates repeated token ids and prints a note. Blank token ids are rejected because the task requires at least one explicit id.

## Run Pre-Live Readiness Check

Human-readable output:

```bash
bin/rails aerodrome:pre_live_check
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:pre_live_check
```

Optional read-only Hyperliquid readback:

```bash
CHECK_HYPERLIQUID=true bin/rails aerodrome:pre_live_check
```

The pre-live check is read-only. It performs no DB writes, places no orders, and does not call Hyperliquid execution methods such as `open_short`, `close_short`, `set_leverage`, `market_order`, `market_close`, or `update_leverage`. With `CHECK_HYPERLIQUID=true`, it only reads `get_position("ETH")` and reports the current ETH short state. The report includes `AERODROME_LIVE_APPROVED` state. Passing this check is not permission for live trading; live remains blocked by default and requires a separate future approval/change.

After any testnet soak, run:

```bash
CHECK_HYPERLIQUID=true bin/rails aerodrome:pre_live_check
```

If an ETH short remains open, run the testnet-only emergency close:

```bash
bin/rails aerodrome:testnet_emergency_close
```

JSON output is available with:

```bash
FORMAT=json bin/rails aerodrome:testnet_emergency_close
```

The emergency close task refuses to run unless `HYPERLIQUID_TESTNET=true` and `AERODROME_LIVE_APPROVED=false`. It retries explicit ETH close/readback after transient Hyperliquid testnet API/DNS failures and never touches USDC. Live close/emergency procedures must be separate future work; live remains disabled.

## Run Live Emergency Close

The live emergency close task is live-order capable but blocked by default. It is manual-only, closes ETH only, never opens positions, never touches USDC, never calls `set_leverage`, and never calls Aerodrome contracts:

```bash
bin/rails aerodrome:live_emergency_close
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:live_emergency_close
```

It refuses unless `HYPERLIQUID_TESTNET=false`, `AERODROME_LIVE_APPROVED=true`, `AERODROME_HEDGE_PAUSED=true`, `AERODROME_LIVE_EMERGENCY_CLOSE_ENABLED=true`, `AERODROME_LIVE_EMERGENCY_CLOSE_MAX_ETH` is configured, and `AERODROME_LIVE_EMERGENCY_CLOSE_CONFIRM=I_UNDERSTAND_THIS_CLOSES_LIVE_ETH_SHORT`. It reads the current ETH position, blocks if size exceeds the max, closes only ETH with explicit `close_short(asset: "ETH", size: current_short)`, and retries/readbacks until ETH is closed or attempts are exhausted. This task must be tested/read-reviewed before the first live micro-run. It is not live approval.

## Run Live Preflight Check

The first-live preflight is read-only and is not permission to trade:

```bash
bin/rails aerodrome:live_preflight_check
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:live_preflight_check
```

Optional read-only Hyperliquid mainnet readback:

```bash
CHECK_HYPERLIQUID=true bin/rails aerodrome:live_preflight_check
```

The live preflight expects mainnet-mode configuration while trading remains disabled: `HYPERLIQUID_TESTNET=false`, `AERODROME_LIVE_APPROVED=false`, `AERODROME_HEDGE_ENABLED=false`, and `AERODROME_HEDGE_PAUSED=true`. It performs no DB writes, places no orders, and does not call `open_short`, `close_short`, `set_leverage`, `market_order`, `market_close`, or `update_leverage`. PASS is not live approval. The first live micro-run requires a separate manual procedure, and a separate live emergency close procedure must be ready before first live. Live remains disabled by default.

## Acknowledge Reviewed Failed Rebalance

Failed `ShortRebalance` rows must not be deleted. If a failed WETH/ETH row is reviewed, has `old_short_size=0` and `new_short_size=0`, and mainnet readback confirms no ETH position exists, it can be acknowledged with:

```bash
bin/rails aerodrome:acknowledge_failed_rebalance
```

Required env gates:

```bash
AERODROME_ACK_FAILED_REBALANCE_ID=<short_rebalance_id>
AERODROME_ACK_FAILED_REBALANCE_CONFIRM=I_CONFIRM_MAINNET_ETH_POSITION_IS_NIL_AND_FAILURE_REVIEWED
```

The task performs no orders and no Hyperliquid execution methods. It reads mainnet `get_position("ETH")` only and appends `[operator_acknowledged_no_open_position]` to the failed row message if eligible. It does not change status to success, does not change sizes, and does not delete history. Acknowledgment is not live approval; repeat live micro-run attempts still require fresh preflight and separate manual approval.

## First Live Micro-Run Runbook

The first-live micro-run plan is documentation only:

```bash
docs/AERODROME_FIRST_LIVE_MICRO_RUN.md
```

This runbook does not enable live trading, does not change env values, does not add a first-live execution task, and does not provide an executable live command. It defines required preconditions, tiny operator-defined risk caps, manual stop/backup/preflight/readback steps, and stop conditions. The gated live emergency close task must be tested/read-reviewed before any live micro-run. Dashboard rewards and fees remain read-only estimates and are not execution approval. The current default remains disabled, paused, and not live-approved.

The first live micro-run is complete and documented in `docs/AERODROME_FIRST_LIVE_MICRO_RUN_REPORT.md`. The retry recorded `ShortRebalance #183`, which opened a tiny mainnet ETH short (`new_short_size=0.011`) from the Aerodrome WETH side while USDC was skipped. The gated live emergency close then closed the ETH short and final mainnet ETH readback was nil. This is not approval for continuous live operation. The next stage should be a separately planned small live observation window or controlled one-cycle run, not immediate scaling.

## Live Observation Window

`bin/rails aerodrome:live_observation_window` is a strictly gated one-off live observation tool. It is live-order capable but blocked by default. It is not background automation and does not add UI live controls. It refuses to run unless explicit observation gates, live hedge gates, tiny max short limits, close-on-finish, and live emergency close gates are all present. Duration is capped at 1800 seconds, interval must be at least 60 seconds, `AERODROME_LIVE_OBSERVATION_CLOSE_ON_FINISH=true` is mandatory, and `AERODROME_MAX_LEVERAGE` must be `1`.

The task records JSONL events under `storage/aerodrome_live_observation/`, runs one iteration at a time for the configured short window, stops on failed rebalances or max-short breaches, and attempts the existing gated live emergency close at the end if an ETH short exists. Success requires final mainnet ETH position to be nil. Live remains disabled by default, and any observation window requires separate manual approval. Next scaling requires another explicit approval and should not follow automatically from one successful window.

## Run AERO Rewards Check

The AERO rewards check is read-only and does not claim rewards:

```bash
bin/rails aerodrome:rewards_check
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:rewards_check
```

This task discovers the configured Aerodrome position, attempts read-only `Voter.gauges(pool)` gauge discovery when `AERODROME_VOTER_ADDRESS` is configured, and attempts read-only CL gauge reward reads for a depositor address plus token id. For staked Slipstream NFTs, the stored/owner wallet can be the gauge. Set `AERODROME_REWARDS_DEPOSITOR_ADDRESS` to the real staking wallet to read earned rewards in that case. When the override is blank, the check falls back to `position.wallet.address`. It reports `position_wallet_address`, compatibility `wallet_address`, `depositor_address`, `depositor_source`, and `gauge_address`; the gauge address must never be used as the depositor fallback. `not_staked` means the token id was not found for that depositor in the discovered CL gauge. It performs no DB writes, sends no transactions, claims nothing, and does not use private keys. AERO rewards are discovery-only. AERO USD valuation is read-only and requires a configured verified source: either `AERODROME_AERO_USD_MANUAL_PRICE` or enabled on-chain valuation with `AERODROME_AERO_USDC_POOL_ADDRESS`. The verified Base AERO/USDC Slipstream CL pool for this read path is `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1` with token0 USDC `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` and token1 AERO `0x940181a94a35a4569e4529a3cdfb74e38fd98631`. Unclaimed rewards are displayed as estimates only.

Recommended production reward valuation configuration:

```bash
AERODROME_AERO_USD_VALUATION_ENABLED=true
AERODROME_AERO_USDC_POOL_ADDRESS=0xbe00ff35af70e8415d0eb605a286d8a45466a4c1
AERODROME_AERO_USD_MANUAL_PRICE=
```

If on-chain valuation is unavailable, leave `AERODROME_AERO_USD_VALUATION_ENABLED=false` and use `AERODROME_AERO_USD_MANUAL_PRICE` only as an explicit operator-provided fallback. Manual price values can go stale and remain estimates.

## Run Aerodrome LP Fees Check

The Aerodrome LP fees check is read-only and does not collect fees:

```bash
bin/rails aerodrome:fees_check
```

JSON output:

```bash
FORMAT=json bin/rails aerodrome:fees_check
```

The check reads the active Aerodrome Slipstream position token id and, for unstaked positions where the source is safe, reads `NonfungiblePositionManager.positions(tokenId)` `tokensOwed0` and `tokensOwed1`. It converts the raw amounts using verified token decimals and values WETH/USDC fees from persisted token prices. It performs no DB writes, sends no transactions, does not call `collect`, and does not use private keys.

The dashboard only runs the fee check when `AERODROME_FEES_ENABLED=true`; otherwise it shows fees as not configured/unavailable instead of fake zero. If the NFT is staked in a CL gauge, the check reports fees as unavailable instead of showing a fake zero. Aerodrome CL gauge staking is documented as receiving emissions instead of fees, so staked-position fee readback needs a separate verified procedure before being displayed as a number. Unclaimed fees are estimates until collected and are separate from realized PnL. Collecting fees is not implemented. Live remains disabled.

## Manual Verification For One Token ID


1. Run `bin/rails aerodrome:verify_config`.
2. Run `CHECK_RPC=true bin/rails aerodrome:verify_config`.
3. Run `FORMAT=json bin/rails aerodrome:dry_run TOKEN_IDS=TOKEN_ID_PLACEHOLDER`.
4. Open the Aerodrome UI for the same token id.
5. Open BaseScan for the configured position manager and token id.
6. Compare:
   - owner address;
   - pool address;
   - token0/token1 addresses;
   - token symbols and decimals;
   - tick spacing;
   - tick lower and upper;
   - current tick from pool `slot0`;
   - liquidity;
   - computed `amount0_raw` and `amount1_raw`;
   - supported USDC-pool `token0_price_usd`, `token1_price_usd`, and `total_value_usd`;
   - WETH/USDC hedge preview `suggested_short_amount` and `suggested_short_notional_usd`;
   - `tokensOwed0` and `tokensOwed1`.

If any value differs, stop and record the discrepancy in `docs/AERODROME_SLIPSTREAM_VERIFICATION.md` or a follow-up verification log.

## UI Display

Aerodrome positions appear in the dashboard and position pages with:

- `Aerodrome Slipstream` DEX label.
- Base chain and token id when available.
- Monitor-only, no-orders, hedge-disabled, and Hyperliquid-not-called safety labels.
- Persisted amounts, USD prices, and estimated LP value when available.
- Read-only PnL snapshots when both Aerodrome amounts and USD prices are available. The snapshot pool PnL uses `asset0_amount * asset0_price_usd + asset1_amount * asset1_price_usd - entry_value_usd`; if `entry_value_usd` is missing, the first compatible Aerodrome snapshot sets it as the baseline. Hedge PnL and fees remain zero for Aerodrome snapshots in this task.
- A read-only Aerodrome hedge status card when an explicit `Hedge` record exists. It shows target/tolerance, target ETH short, execution gate env state, mode labels, and the latest WETH/ETH rebalance from local history only. Actual ETH short readback is disabled by default and is not queried from Hyperliquid on the dashboard.
- A read-only PnL baseline card showing `entry_value_usd`, current pooled value, and pool delta from entry. Dashboard PnL baseline starts from `entry_value_usd`, which may be set by the first Aerodrome snapshot unless manually set earlier.
- A read-only AERO Rewards section. When `AERODROME_REWARDS_ENABLED=true`, it runs the read-only rewards check and shows status, staked state, claimable AERO amount, AERO USD price/source when configured, claimable AERO USD estimate, depositor address/source, gauge address, and token id. If config or RPC is unavailable, the page shows unavailable without crashing.
- A read-only Aerodrome LP Fees section. If the verified fee read is available, it shows fee0/fee1 amounts, symbols, and USD estimate. If the position is staked or fee readback is unavailable, it shows unavailable instead of fake zero. Collecting fees is not implemented.
- Explicit PnL totals for Aerodrome: Total PnL excluding rewards/fees, Total PnL including unclaimed AERO rewards estimate, and Total PnL including unclaimed AERO rewards plus unclaimed LP fees estimate when both USD estimates are available. Unclaimed rewards and fees are not realized until claimed/collected.
- Display-only hedge preview for configured WETH/USDC data, or a clear unavailable reason.
- Latest manual hedge proposal when present, including suggested side, asset, amount, notional, status, execution flags, Hyperliquid-called flag, and computed current/stale status.
- Compact recent proposal history for the position, including proposal id, status, hedge asset/side, suggested amount/notional, generated/reviewed timestamps, `execution_enabled`, and `hyperliquid_called`.
- Local proposal safety status: `PASSED`, `WARNINGS`, or `BLOCKED`.
- Checked safety limits, failures, and warnings. Missing safety limits are warnings, not failures.
- A `Generate Manual Hedge Proposal` action that creates or updates a local draft record only. The action is labeled manual proposal only, no orders, no Hyperliquid, and execution disabled.
- `Regenerate Manual Hedge Proposal` updates the latest draft proposal or creates a new draft if no draft exists. Stale proposals should be regenerated before manual review.
- `Mark Reviewed` and `Reject` proposal actions. These only update local proposal status and timestamps; review/rejection is not execution. Blocked proposals cannot be marked reviewed and must not be used for execution.
- The Aerodrome position refresh action is labeled `Refresh Read-only Data` and states that it updates on-chain LP data only, with no orders, no Hyperliquid, and no hedge execution.

The UI preview, manual proposal system, and safety-limit checks do not call RPC, do not call `HyperliquidService`, do not create `Hedge` records, and do not enable order execution. Manual proposals are local records only. They are still NOT READY FOR LIVE HEDGE INTEGRATION, and `AERODROME_HEDGE_ENABLED` remains false/default-off.

Aerodrome LP fee read is not implemented yet. The dashboard keeps Aerodrome LP fees at zero and labels them as a future task.

AERO reward claiming and staking are not implemented. Rewards are not realized PnL until claimed/sold and must not be faked. AERO USD valuation requires a configured/verified price source. Live remains disabled.

When `AERODROME_HEDGE_ENABLED=false` or unset, `HedgeSyncJob` skips Aerodrome hedges before constructing `HyperliquidService`. Testnet rehearsal requires `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true`. Hyperliquid mainnet Aerodrome hedge processing skips before `HyperliquidService` unless `AERODROME_LIVE_APPROVED=true`; missing `AERODROME_LIVE_APPROVED` behaves false. `AERODROME_LIVE_APPROVED=true` is not enough by itself: `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, all readiness/risk gates, and WETH/ETH-only filtering are still required. Production live must keep `AERODROME_HEDGE_ENABLED=false` and `AERODROME_HEDGE_PAUSED=true` until a separate future first-live procedure is approved.

`AERODROME_HEDGE_PAUSED` is a local kill switch and defaults to paused when missing. To run testnet rehearsal, an operator must explicitly set `AERODROME_HEDGE_PAUSED=false` in addition to `AERODROME_HEDGE_ENABLED=true` and `HYPERLIQUID_TESTNET=true`. Live trading is still not approved; live use requires `AERODROME_LIVE_APPROVED=true` plus a separate future checklist/change and first-live procedure.

With both rehearsal flags enabled and the kill switch unpaused, `HedgeSyncJob` first requires an active Aerodrome position with both assets, both persisted amounts, both persisted USD prices, and an explicit hedge record. Incomplete data is skipped before `HyperliquidService` construction. Complete data is filtered to ETH/WETH exposure only before it is passed into the existing hedge loop; USDC is explicitly skipped and cannot create a hedge order. Optional pre-live limits (`AERODROME_MAX_SHORT_ETH`, `AERODROME_MAX_SHORT_NOTIONAL_USD`, `AERODROME_MAX_LEVERAGE`) block Aerodrome before the order path when exceeded; missing max limits are not enforced. Existing tolerance checks, failure records, circuit breaker behavior, subaccount logic, margin handling, and order methods are reused unchanged for the supported ETH/WETH side. Operators must complete testnet/manual verification and a separate pre-live checklist before considering live use.

The first Aerodrome testnet hedge rehearsal confirmed that the WETH/ETH open path could submit a tiny testnet short and that the USDC side was skipped. The close path then exposed a false-success bug: SDK `market_close` logged `No open position to close for ETH` for an API-wallet/master-account short, while `HedgeSyncJob` still recorded a successful `ShortRebalance` with `new_short_size=0`. The close path now passes the known `current_short` size and submits an explicit opposite market order instead of relying on SDK position discovery. Do not trust successful close rebalances created before this close-path fix as proof that a Hyperliquid short was closed.

The explicit close retest encountered `SSL_read: unexpected eof while reading`; the ETH short remained open and the app correctly recorded failure. Network ambiguity can happen after either open or close orders, including cases where the order executes but the client receives an SSL/read exception. `HedgeSyncJob` now reconciles ambiguous order errors by fetching actual Hyperliquid position state and recording the actual final short size. If the actual size is within tolerance of the intended target, the rebalance is recorded as success with a reconciliation message; otherwise it is recorded as failed. Explicit API rejections, such as minimum-order failures, remain failed. Live remains blocked until open and close reconciliation retests pass on testnet.

The 10h testnet soak also showed unnecessary order churn. Same-size rounded target rebalances are skipped, and non-zero rebalances now use delta-only sizing: increasing a short opens only the additional size, decreasing a short closes only the excess size, and full close is reserved for `target_short == 0`. This reduces fees, slippage, and order/API risk. Live remains disabled.

A 1h delta-only soak showed most target changes produced tiny deltas below Hyperliquid's minimum order notional, which created failed rows and tripped the circuit breaker. Aerodrome non-close deltas below `AERODROME_MIN_ORDER_NOTIONAL_USD` now skip without order submission or failed `ShortRebalance` rows. Missing `AERODROME_MIN_ORDER_NOTIONAL_USD` defaults to 10. Close-to-zero bypasses the failed-rebalance circuit breaker so final cleanup closes are still attempted and reconciled truthfully. Live remains disabled.

A subsequent testnet soak showed final close can fail from Hyperliquid testnet DNS/API availability, leaving a testnet ETH short open until manual close. Use `CHECK_HYPERLIQUID=true bin/rails aerodrome:pre_live_check` after every soak, and if ETH remains open, use `bin/rails aerodrome:testnet_emergency_close`. This is testnet-only tooling and is not a live emergency procedure.

The first live micro-run attempted a tiny mainnet ETH hedge (`target_short_eth=0.0111`, about $25.80 notional). Hyperliquid readback showed no ETH position before or after, and the rebalance failed with `String does not have #dig method` because the SDK/API returned a non-Hash order response. `HyperliquidService` now treats non-Hash and unknown order response shapes as explicit `OrderError` failures with sanitized previews instead of Ruby method errors. Do not retry live until live preflight is rerun and a separate explicit manual approval is given.

Proposal freshness is display-only. A proposal is shown as stale when the current WETH amount or suggested notional differs by more than 0.5%, when the position is inactive, or when the proposal is rejected/expired. Stale status does not trigger any automated action.

Proposal safety limits are display/local-review gates only. If a limit env var is blank, that limit is shown as not configured and produces a warning. If a configured limit is exceeded, the proposal is shown as `BLOCKED`, and the UI prevents marking it reviewed.

## Confirm No DB Writes

Before and after dry-run:

```bash
bin/rails runner 'puts({ positions: Position.count, hedges: Hedge.count, snapshots: PnlSnapshot.count, rebalances: ShortRebalance.count })'
```

Counts should be unchanged.

## Confirm Hyperliquid Was Not Touched

- Dry-run and config verification do not instantiate `HyperliquidService`.
- Hedge preview also does not instantiate `HyperliquidService`; it computes only a local theoretical short amount.
- Manual hedge proposal generation and review do not instantiate `HyperliquidService`; they create/read/update local proposal records only.
- Proposal history/stale status display does not instantiate `HyperliquidService`; it compares local proposal rows with local persisted position values.
- Proposal safety-limit checks do not instantiate `HyperliquidService`; they compare local proposal values with optional local env limits.
- Aerodrome hedges do not instantiate `HyperliquidService` while `AERODROME_HEDGE_ENABLED=false` or when local readiness checks fail.
- Aerodrome hedges do not instantiate `HyperliquidService` when `HYPERLIQUID_TESTNET` is missing or false, even if `AERODROME_HEDGE_ENABLED=true`.
- If `AERODROME_HEDGE_ENABLED=true`, `HYPERLIQUID_TESTNET=true`, and readiness checks pass, Aerodrome uses the existing `HedgeSyncJob` and `HyperliquidService` code path for ETH/WETH only; no Aerodrome-specific execution path exists, and the USDC side is never hedged.
- They do not require `HYPERLIQUID_PRIVATE_KEY` or `HYPERLIQUID_WALLET_ADDRESS`.
- Inspect recent logs for `HyperliquidService`, `open_short`, `close_short`, `set_leverage`, `transfer_to_subaccount`, and `withdraw_from_subaccount`; none should be associated with Aerodrome dry-run commands.

## Logs To Inspect

- `log/development.log` for local dry-run errors.
- Search terms:
  - `Aerodrome`
  - `aerodrome:dry_run`
  - `aerodrome:verify_config`
  - `aerodrome:pre_live_check`
  - `HyperliquidService`
  - `HedgeSyncJob`

Always check timestamps to avoid stale log entries.

## When Not To Proceed

Do not proceed beyond dry-run if:

- `bin/rake` fails.
- `aerodrome:verify_config` fails.
- `aerodrome:pre_live_check` is `BLOCKED`.
- `CHECK_RPC=true` returns the wrong chain id.
- manager or factory `eth_getCode` returns `0x`.
- dry-run returns an error for the token id.
- owner, pool, token, tick, or liquidity values disagree with Aerodrome UI/BaseScan.
- USD valuation for an unsupported pair or fee behavior is still needed for the next step.
- hedge preview differs from the operator's manual WETH amount/notional check.
- any close-short rehearsal logs `No open position to close` while a short remains open on Hyperliquid.
- a close-short rehearsal records success locally but `get_position("ETH")` still shows an open short.
- an open or close rehearsal hits SSL/network ambiguity and the local `ShortRebalance` does not match the actual post-error Hyperliquid position size.

## Future Hedge Integration Checklist

- [ ] Hyperliquid remains untouched until a later explicit task.
- [x] Amount0/amount1 math implemented from trusted Aerodrome Slipstream sources.
- [ ] Amount0/amount1 math compared against Aerodrome UI/BaseScan for real positions.
- [x] USDC-pool valuation preview implemented for monitor-only use.
- [x] WETH/USDC hedge preview implemented for monitor-only use.
- [x] Manual local-only WETH/USDC hedge proposals implemented without execution.
- [x] Manual proposal history and stale-status display implemented without execution.
- [x] Local proposal safety-limit checks implemented without execution.
- [ ] USDC-pool valuation compared against Aerodrome UI/BaseScan for real positions.
- [ ] WETH/USDC hedge preview compared manually for real positions.
- [ ] Non-USDC USD valuation source verified.
- [ ] Advanced fee strategy decided and tested.
- [ ] Staked/gauge position behavior verified or explicitly excluded.
- [ ] Manager/factory deployment strategy approved.
- [x] Aerodrome positions remain disabled for hedging by default.
- [x] Controlled Aerodrome hedge-loop entry is behind `AERODROME_HEDGE_ENABLED=true` and local readiness checks.
- [ ] Fixed close-short path retested on Hyperliquid testnet after the false-success bug.
- [ ] Open/close reconciliation retested on Hyperliquid testnet after SSL ambiguity.
- [ ] Testnet/manual verification completed before any live Aerodrome hedge use.
- [ ] Manual proposal workflow reviewed operationally; stale or blocked proposals are regenerated/rejected before review and review remains non-executing.
- [ ] Mocked tests cover all RPC paths.
- [ ] Manual dry-run matches Aerodrome UI/BaseScan for real positions.
- [ ] `bin/rake` passes.

## Stop And Rollback

See `docs/AERODROME_ROLLBACK.md`.
