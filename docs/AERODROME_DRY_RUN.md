# Aerodrome Slipstream Dry Run

The Aerodrome dry-run tooling performs a read-only check of explicit Aerodrome Slipstream position NFT token ids on Base. It is intended for manual verification before any production sync or hedge integration.

## What It Does

- Reads explicit token ids from `TOKEN_IDS` or `AERODROME_SLIPSTREAM_TOKEN_IDS`.
- Uses `AerodromeSlipstreamService` to call read-only JSON-RPC `eth_call` methods.
- Prints owner, manager, factory, pool, token metadata, tick range, current tick, liquidity, and raw owed-token fields.
- Returns `amount0_raw` and `amount1_raw` as partial/deferred because amount math is not implemented yet.
- Handles individual token errors and continues building the report.

## What It Does Not Do

- Does not write to the database.
- Does not create or update `Position`, `Hedge`, `PnlSnapshot`, or `ShortRebalance` records.
- Does not run `WalletSyncJob`, `PositionSyncJob`, or `HedgeSyncJob`.
- Does not call `HyperliquidService`.
- Does not sign transactions or require private keys.
- Does not place orders, approve tokens, transfer NFTs, swap, collect fees, or hedge.
- Does not make Aerodrome positions hedge-ready.

## Safety Guarantees

The task prints this banner on every human-readable run:

```text
READ-ONLY DRY RUN — no DB writes, no trades, no hedges.
```

Every result includes:

- `database_write: false`
- `hedge_enabled: false`
- `amount0_raw: nil`
- `amount1_raw: nil`
- `partial_data_reason`

## Required Env Vars

Use read-only configuration only:

```env
BASE_RPC_URL=BASE_RPC_URL_PLACEHOLDER
AERODROME_SLIPSTREAM_POSITION_MANAGER=POSITION_MANAGER_ADDRESS_PLACEHOLDER
AERODROME_SLIPSTREAM_FACTORY=FACTORY_ADDRESS_PLACEHOLDER
```

No private keys are required. Do not add private keys for this task.

## Run With Token IDs

Pass token ids explicitly:

```bash
bin/rails aerodrome:dry_run TOKEN_IDS=5016
```

Or use the optional env var:

```bash
AERODROME_SLIPSTREAM_TOKEN_IDS=5016 bin/rails aerodrome:dry_run
```

Multiple token ids are comma-separated:

```bash
bin/rails aerodrome:dry_run TOKEN_IDS=5016,12345
```

## JSON Output

Use JSON for saving or diffing reports:

```bash
FORMAT=json bin/rails aerodrome:dry_run TOKEN_IDS=5016
```

## Compare Against Aerodrome UI And BaseScan

For each token id:

1. Open the position in the Aerodrome UI.
2. Open the configured position manager and token id on BaseScan.
3. Compare `owner_address`, `token0_address`, `token1_address`, `tick_spacing`, `tick_lower`, `tick_upper`, `liquidity`, `pool_address`, `current_tick`, `tokens_owed0_raw`, and `tokens_owed1_raw`.
4. Record the RPC URL host, block context if available from the RPC provider, and any differences in `docs/AERODROME_SLIPSTREAM_VERIFICATION.md` or a follow-up verification log.

## Confirm No DB Writes

Before and after a dry-run, you can check counts:

```bash
bin/rails runner 'puts({ positions: Position.count, hedges: Hedge.count, snapshots: PnlSnapshot.count, rebalances: ShortRebalance.count })'
```

The counts should not change from the dry-run.

## Confirm Hyperliquid Was Not Touched

The dry-run code path does not instantiate `HyperliquidService` and does not require:

- `HYPERLIQUID_PRIVATE_KEY`
- `HYPERLIQUID_WALLET_ADDRESS`

You can also run without those variables in a local shell when only using the dry-run task.

## Expected Partial Fields

These fields are expected to be partial:

- `amount0_raw`
- `amount1_raw`
- normalized decimal amounts
- USD valuation
- advanced uncollected fee calculations beyond `tokensOwed0` and `tokensOwed1`
- hedge readiness

Amount math remains deferred because the exact Slipstream formula, rounding, and comparison against known Aerodrome UI/BaseScan values must be verified first. Hedge integration remains disabled because amount math, USD pricing, fee strategy, and monitor-only behavior are not fully verified.

## Rollback And Safety Notes

- Remove or ignore `AERODROME_SLIPSTREAM_TOKEN_IDS` to stop manual dry-runs.
- Keep `AERODROME_HEDGE_ENABLED=false`.
- Do not copy secrets into docs or command output.
- Do not use private RPC URLs in shared logs.
- Dry-run failures should be treated as verification blockers, not as reasons to guess contract behavior.
