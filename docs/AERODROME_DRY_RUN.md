# Aerodrome Slipstream Dry Run

The Aerodrome dry-run tooling performs a read-only check of explicit Aerodrome Slipstream position NFT token ids on Base. It is intended for manual verification before any production sync or hedge integration.

## What It Does

- Reads explicit token ids from `TOKEN_IDS` or `AERODROME_SLIPSTREAM_TOKEN_IDS`.
- Uses `AerodromeSlipstreamService` to call read-only JSON-RPC `eth_call` methods.
- Prints owner, manager, factory, pool, token metadata, tick range, current tick, liquidity, and raw owed-token fields.
- Computes `amount0_raw` and `amount1_raw` with the verified Aerodrome Slipstream `TickMath` and `LiquidityAmounts` formulas.
- Prints decimal display amounts when token decimals are available.
- Shows monitor-only USD valuation preview for pools that include the configured USDC quote token.
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
- `amount_math_deferred: false` when every token has computed raw amounts
- `amount0_raw`
- `amount1_raw`
- `amount0_decimal`
- `amount1_decimal`
- `math_source`
- `verification_status`
- `token0_price_usd`, `token1_price_usd`, and `total_value_usd` when valuation is supported
- `valuation_status`, `valuation_source`, and `valuation_reason`

Human output also repeats:

- `NO DB WRITES`
- `NO HYPERLIQUID`
- `NO HEDGES`
- `AMOUNT MATH DEFERRED` only when amount math is actually partial; otherwise `AMOUNT MATH VERIFIED`.

## Required Env Vars

Use read-only configuration only:

```env
BASE_RPC_URL=BASE_RPC_URL_PLACEHOLDER
AERODROME_SLIPSTREAM_POSITION_MANAGER=POSITION_MANAGER_ADDRESS_PLACEHOLDER
AERODROME_SLIPSTREAM_FACTORY=FACTORY_ADDRESS_PLACEHOLDER
AERODROME_USDC_ADDRESS=BASE_USDC_ADDRESS_PLACEHOLDER
```

No private keys are required. Do not add private keys for this task.

`AERODROME_USDC_ADDRESS` is optional for raw position reads. Without it, USD valuation preview is marked unsupported and price fields remain nil. Do not hardcode this value from memory; verify it from a trusted source before using it locally.

## Verify Config

Static validation only. This checks required values and address format without RPC:

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

With `CHECK_RPC=true`, the task calls only:

- `eth_chainId`
- `eth_getCode` for the configured position manager
- `eth_getCode` for the configured factory

It does not call `eth_sendTransaction`, `eth_sendRawTransaction`, jobs, or Hyperliquid.

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

Blank token ids are rejected if no valid token id remains. Duplicate token ids are de-duplicated and reported as notes.

## JSON Output

Use JSON for saving or diffing reports:

```bash
FORMAT=json bin/rails aerodrome:dry_run TOKEN_IDS=5016
```

JSON output is intended for saving and diffing. It includes the same safety fields as human-readable output.

## Common Errors

Missing token ids:

```text
Aerodrome dry-run requires explicit token ids.
```

Missing config:

```text
Missing BASE_RPC_URL
Missing AERODROME_SLIPSTREAM_POSITION_MANAGER
Missing AERODROME_SLIPSTREAM_FACTORY
```

Invalid address:

```text
Invalid AERODROME_SLIPSTREAM_POSITION_MANAGER address
Invalid AERODROME_SLIPSTREAM_FACTORY address
```

Wrong RPC chain:

```text
BASE_RPC_URL returned chain id ... expected 0x2105
```

Treat these as verification blockers.

## Troubleshooting

- Run `bin/rails aerodrome:verify_config` before dry-run.
- Run `CHECK_RPC=true bin/rails aerodrome:verify_config` if static config passes.
- Confirm placeholders were replaced locally, not in committed docs.
- Confirm token ids are comma-separated and not blank.
- Confirm the configured position manager corresponds to the token id being checked.
- Confirm the configured factory is paired with that manager.

## Compare Against Aerodrome UI And BaseScan

For each token id:

1. Open the position in the Aerodrome UI.
2. Open the configured position manager and token id on BaseScan.
3. Compare `owner_address`, `token0_address`, `token1_address`, `tick_spacing`, `tick_lower`, `tick_upper`, `liquidity`, `pool_address`, `current_tick`, `amount0_raw`, `amount1_raw`, `tokens_owed0_raw`, and `tokens_owed1_raw`.
4. For supported USDC pools, compare `token0_price_usd`, `token1_price_usd`, and `total_value_usd` against Aerodrome UI/BaseScan or another trusted operator-approved reference.
5. Record the RPC URL host, block context if available from the RPC provider, and any differences in `docs/AERODROME_SLIPSTREAM_VERIFICATION.md` or a follow-up verification log.

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

## Amount Math Status

Amount math is implemented for read-only dry-run output using:

- Aerodrome Slipstream `contracts/core/libraries/TickMath.sol`.
- Aerodrome Slipstream `contracts/periphery/libraries/LiquidityAmounts.sol`.
- Aerodrome Slipstream `contracts/core/libraries/FixedPoint96.sol`.
- Aerodrome Slipstream `contracts/core/libraries/FullMath.sol`.

The Ruby implementation preserves Solidity-style integer floor division. Raw values do not use Float arithmetic.

## USD Valuation Preview

USD valuation preview is implemented only for pools where one token address matches the configured `AERODROME_USDC_ADDRESS`. It uses pool `slot0.sqrtPriceX96`, token decimals, and the configured USDC quote token to compute relative price and assumes USDC is worth 1 USD for preview purposes. This is monitor-only and must still be compared manually against Aerodrome UI/BaseScan before operational use.

Unsupported pairs keep price fields nil and report `valuation_status: unsupported`. The code does not guess prices or infer USDC by symbol alone.

These fields remain partial or unresolved:

- USD valuation for non-USDC pools.
- Advanced uncollected fee calculations beyond `tokensOwed0` and `tokensOwed1`.
- Staking/gauge discovery.
- Hedge readiness.

Manual comparison against Aerodrome UI/BaseScan is still required before using the data operationally. Hedge integration remains disabled because USD pricing, fee strategy, and monitor-only behavior are not fully verified.

## Rollback And Safety Notes

- Remove or ignore `AERODROME_SLIPSTREAM_TOKEN_IDS` to stop manual dry-runs.
- Keep `AERODROME_HEDGE_ENABLED=false`.
- Do not copy secrets into docs or command output.
- Do not use private RPC URLs in shared logs.
- Dry-run failures should be treated as verification blockers, not as reasons to guess contract behavior.
- See `docs/AERODROME_ROLLBACK.md` for rollback details.
