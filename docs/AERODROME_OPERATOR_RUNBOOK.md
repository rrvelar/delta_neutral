# Aerodrome Operator Runbook

This runbook is for read-only Aerodrome Slipstream verification on Base. It is not approval to enable live hedge execution.

## Current Architecture Summary

- Existing production behavior remains Uniswap V3 LP monitoring plus Hyperliquid hedge execution.
- `AerodromeSlipstreamService` is a read-only JSON-RPC client for selected Aerodrome Slipstream position manager and factory addresses.
- `AerodromeSlipstreamDryRun` wraps the service for manual token-id verification without database writes.
- Aerodrome monitor-only sync is gated by `AERODROME_READ_ONLY_ENABLED=true` and explicit token ids.
- `HedgeSyncJob` skips Aerodrome positions; Aerodrome exposure is not fed into hedge logic.

## Implemented

- Read-only Aerodrome position fetches for explicit token ids.
- Read-only amount0/amount1 math using verified Aerodrome Slipstream `TickMath` and `LiquidityAmounts` formulas.
- Manual dry-run task: `bin/rails aerodrome:dry_run`.
- Config verification task: `bin/rails aerodrome:verify_config`.
- Mocked tests for dry-run and config verification.
- Documentation for limitations, rollback, and pre-live audit.

## Not Implemented

- Live trading.
- Aerodrome hedge execution.
- USD valuation.
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
   - `tokensOwed0` and `tokensOwed1`.

If any value differs, stop and record the discrepancy in `docs/AERODROME_SLIPSTREAM_VERIFICATION.md` or a follow-up verification log.

## Confirm No DB Writes

Before and after dry-run:

```bash
bin/rails runner 'puts({ positions: Position.count, hedges: Hedge.count, snapshots: PnlSnapshot.count, rebalances: ShortRebalance.count })'
```

Counts should be unchanged.

## Confirm Hyperliquid Was Not Touched

- Dry-run and config verification do not instantiate `HyperliquidService`.
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
- USD valuation or fee behavior is still needed for the next step.

## Future Hedge Integration Checklist

- [ ] Hyperliquid remains untouched until a later explicit task.
- [x] Amount0/amount1 math implemented from trusted Aerodrome Slipstream sources.
- [ ] Amount0/amount1 math compared against Aerodrome UI/BaseScan for real positions.
- [ ] USD valuation source verified.
- [ ] Advanced fee strategy decided and tested.
- [ ] Staked/gauge position behavior verified or explicitly excluded.
- [ ] Manager/factory deployment strategy approved.
- [ ] Aerodrome positions remain disabled for hedging by default.
- [ ] Mocked tests cover all RPC paths.
- [ ] Manual dry-run matches Aerodrome UI/BaseScan for real positions.
- [ ] `bin/rake` passes.

## Stop And Rollback

See `docs/AERODROME_ROLLBACK.md`.
