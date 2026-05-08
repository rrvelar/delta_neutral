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
- `HedgeSyncJob` skips Aerodrome positions; Aerodrome exposure is not fed into hedge logic.

## Implemented

- Read-only Aerodrome position fetches for explicit token ids.
- Read-only amount0/amount1 math using verified Aerodrome Slipstream `TickMath` and `LiquidityAmounts` formulas.
- Monitor-only `WalletSyncJob` and `PositionSyncJob` persistence for verified computed token amounts.
- Monitor-only USD valuation preview for configured-USDC pools.
- Monitor-only hedge preview for configured WETH/USDC pools.
- Manual, non-executing hedge proposal records for configured WETH/USDC monitor-only positions.
- Manual proposal lifecycle and recent-history UI with draft/reviewed/rejected/expired statuses.
- Local proposal safety-limit checks for optional maximum short ETH, maximum short notional, maximum LP value, and maximum stale percent.
- UI/dashboard visibility for Aerodrome monitor-only positions.
- Manual dry-run task: `bin/rails aerodrome:dry_run`.
- Config verification task: `bin/rails aerodrome:verify_config`.
- Mocked tests for dry-run and config verification.
- Documentation for limitations, rollback, and pre-live audit.

## Not Implemented

- Live trading.
- Aerodrome hedge execution.
- Hyperliquid hedge preview execution.
- Proposal execution. Proposal review is only a local status change and is not order approval.
- Automatic use of reviewed proposals for any trading workflow.
- Enforced trading risk management. Proposal safety limits are local review gates only and do not execute, size, or submit trades.
- USD valuation for non-USDC pools.
- Advanced uncollected fee calculations.
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
AERODROME_MAX_SHORT_ETH=
AERODROME_MAX_SHORT_NOTIONAL_USD=
AERODROME_MAX_LP_VALUE_USD=
AERODROME_MAX_PROPOSAL_STALE_PERCENT=0.5
AERODROME_READ_ONLY_ENABLED=false
AERODROME_HEDGE_ENABLED=false
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
- They do not require `HYPERLIQUID_PRIVATE_KEY` or `HYPERLIQUID_WALLET_ADDRESS`.
- Inspect recent logs for `HyperliquidService`, `open_short`, `close_short`, `set_leverage`, `transfer_to_subaccount`, and `withdraw_from_subaccount`; none should be associated with Aerodrome dry-run commands.

## Logs To Inspect

- `log/development.log` for local dry-run errors.
- Search terms:
  - `Aerodrome`
  - `aerodrome:dry_run`
  - `aerodrome:verify_config`
  - `HyperliquidService`
  - `HedgeSyncJob`

Always check timestamps to avoid stale log entries.

## When Not To Proceed

Do not proceed beyond dry-run if:

- `bin/rake` fails.
- `aerodrome:verify_config` fails.
- `CHECK_RPC=true` returns the wrong chain id.
- manager or factory `eth_getCode` returns `0x`.
- dry-run returns an error for the token id.
- owner, pool, token, tick, or liquidity values disagree with Aerodrome UI/BaseScan.
- USD valuation for an unsupported pair or fee behavior is still needed for the next step.
- hedge preview differs from the operator's manual WETH amount/notional check.

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
- [ ] Aerodrome positions remain disabled for hedging by default.
- [ ] Manual proposal workflow reviewed operationally; stale or blocked proposals are regenerated/rejected before review and review remains non-executing.
- [ ] Mocked tests cover all RPC paths.
- [ ] Manual dry-run matches Aerodrome UI/BaseScan for real positions.
- [ ] `bin/rake` passes.

## Stop And Rollback

See `docs/AERODROME_ROLLBACK.md`.
