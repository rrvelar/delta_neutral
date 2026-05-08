# Aerodrome Slipstream Migration Plan

Date checked: 2026-05-08

Scope: audit and planning only. This document does not change application behavior, does not enable live trading, and does not introduce any Aerodrome contract integration.

## Non-Negotiable Guardrails

- Do not modify `HyperliquidService`.
- Do not modify Hyperliquid order execution.
- Do not enable live trading as part of the migration.
- Do not edit `.env` or commit secrets.
- Do not implement Aerodrome contract, ABI, address, or protocol details from memory.
- Any unverified Aerodrome-specific fact must stay env-configurable, fail safely with a clear error, and be documented as uncertain.
- Tests for Aerodrome RPC behavior must use mocked JSON-RPC responses only. Tests must not call real RPC.
- Hedge usage must stay disabled by default until a read-only monitor proves position discovery, amount math, fee math, and pricing.

## Current Uniswap-Specific Logic

| Area | File | Current assumption | Migration impact |
| --- | --- | --- | --- |
| Product description | `README.md`, `AGENTS.md` | App is described as monitoring Uniswap V3 CLP positions. | Update docs only after behavior is migrated and verified. |
| Required env vars | `.env.example`, `config/initializers/app_config.rb`, `README.md`, `AGENTS.md` | `UNISWAP_SUBGRAPH_URL` and `THEGRAPH_API_KEY` are required for position data. | Aerodrome RPC/indexer configuration should be separate and feature-gated. Do not remove existing vars until old path is deprecated. |
| Position discovery | `app/jobs/wallet_sync_job.rb` | Instantiates `UniswapService`, fetches subgraph positions by owner, uses `Dex.find_by!(name: "uniswap")`, deactivates missing positions. | Replace or branch by source/dex. Aerodrome discovery must account for one or more verified Slipstream position managers and Base-only chain scope. |
| Position data service | `app/services/uniswap_service.rb` | GraphQL schema has `positions`, `pool`, `token0`, `token1`, `depositedToken*`, `withdrawnToken*`, `collectedFeesToken*`, `derivedETH`, and `bundle.ethPriceUSD`. | New `AerodromeSlipstreamService` must not reuse this GraphQL contract unless a verified Aerodrome indexer exposes equivalent fields. Prefer direct RPC for read-only contract state when possible. |
| Price sync | `app/jobs/position_sync_job.rb` | Calls `uniswap.fetch_pool_data(position.pool_address)` and derives USD prices from subgraph token `derivedETH * bundle.ethPriceUSD`. | Aerodrome must define a verified pricing source. Pool sqrt price alone is not USD pricing unless combined with verified token/USD reference data. |
| Uncollected fees | `app/services/ethereum_service.rb`, `app/jobs/position_sync_job.rb` | Static-calls Uniswap V3 `NonfungiblePositionManager.collect((uint256,address,uint128,uint128))` at hardcoded Uniswap manager `0xC36442b4a4522E871399CD717aBDD847Ab11FE88`. | This is Uniswap-specific and must not be reused for Aerodrome until the Aerodrome manager address, signature, return values, and static-call behavior are verified. |
| Collected fees | `app/services/uniswap_service.rb`, `app/jobs/position_sync_job.rb` | Cumulative collected fees come from subgraph fields `collectedFeesToken0` and `collectedFeesToken1`; diff logic compares prior uncollected fee snapshots. | Aerodrome needs an explicitly verified collected-fee source. If unavailable, store `nil` or 0 with a documented limitation rather than infer from incompatible data. |
| Model comments | `app/models/position.rb`, `app/services/hyperliquid_service.rb` | Comments refer to Uniswap symbols and Uniswap subgraph prices. | Documentation cleanup only after behavior migration. |
| Seeds | `db/seeds.rb` | Seeds `dexes`: `uniswap`, `hyperliquid`. | Add `aerodrome_slipstream` or equivalent only with a migration/seed change in implementation phase. |
| Tests and stubs | `test/services/uniswap_service_test.rb`, `test/jobs/wallet_sync_job_test.rb`, `test/jobs/position_sync_job_test.rb`, `test/integration/wallet_sync_flow_test.rb`, `test/support/service_stubs.rb` | Mock The Graph responses and Uniswap fee RPC responses. | Add Aerodrome tests with mocked RPC/indexer responses. Keep existing Uniswap tests until the old path is intentionally removed. |
| Views/controllers | `app/views/positions/*`, `app/controllers/positions_controller.rb`, `app/controllers/dashboard_controller.rb`, `app/controllers/wallets_controller.rb` | Mostly source-agnostic display using `position.dex.name`, `pool_address`, asset amounts, and prices. | Likely minimal behavior change, but new metadata fields may need display after schema migration. |

## The Graph And Uniswap Subgraph Assumptions

The app currently assumes The Graph is the authoritative source for:

- Active wallet positions: `positions(where: { owner: $owner, liquidity_gt: "0" })`.
- NFT token id: `position.id`, mapped to `positions.external_id`.
- Pool address: `position.pool.id`, mapped to `positions.pool_address`.
- Token symbols: `token0.symbol`, `token1.symbol`.
- Net token amounts: `depositedToken* - withdrawnToken* + collectedFeesToken*`.
- Collected fees: `collectedFeesToken0`, `collectedFeesToken1`.
- Token decimals: `pool.token0.decimals`, `pool.token1.decimals`.
- USD pricing: `token.derivedETH * bundle.ethPriceUSD`.

Aerodrome must not assume any of those field names or semantics unless an Aerodrome-specific subgraph/indexer is verified. If no trusted indexer exists, the read-only service should derive the minimal state from verified contracts via mocked-in-test RPC calls and use a separate verified pricing source.

## Current Model Field Mapping

Fields that likely map cleanly:

| Existing field | Current meaning | Aerodrome Slipstream mapping |
| --- | --- | --- |
| `positions.user_id` | Position owner in the app. | Same. |
| `positions.wallet_id` | Wallet being synced. | Same, but Aerodrome should initially be Base-only. |
| `positions.dex_id` | Source DEX lookup. | Same, with a new Aerodrome Slipstream dex/source record. |
| `positions.external_id` | Uniswap position NFT token id. | Likely maps to Slipstream position NFT token id, after position-manager ownership is verified. |
| `positions.asset0`, `positions.asset1` | Token symbols used by UI and hedge sizing. | Same concept, but token addresses and decimals should be stored or fetched reliably. Symbols alone are not enough for protocol identity. |
| `positions.asset0_amount`, `positions.asset1_amount` | Current token amounts represented by the LP position. | Same output shape required by existing hedge sizing. Calculation method must be verified for Slipstream. |
| `positions.asset0_price_usd`, `positions.asset1_price_usd` | USD prices for portfolio value and snapshots. | Same output shape, but pricing source must be replaced or verified. |
| `positions.pool_address` | Pool contract address. | Same concept, but should be verified from factory/position manager and stored with chain/source metadata. |
| `positions.active` | Position currently found during sync. | Same. |
| `positions.entry_value_usd` | Baseline for pool unrealized PnL. | Same. |
| `pnl_snapshots.*amount`, `*price_usd`, `pool_unrealized` | Historical value snapshot. | Same if upstream amount/price math is verified. |
| `pnl_snapshots.collected_fees*`, `uncollected_fees*` | Fee tracking. | Same output shape, but source and semantics must be revalidated. |
| `hedges.target`, `hedges.tolerance` | Hedge target/tolerance over current token amount. | Same, no protocol dependency. |
| `short_rebalances.*` | Hyperliquid rebalance audit trail. | Same, no protocol dependency. |

Missing or weak fields likely needed:

| Missing field | Why needed |
| --- | --- |
| `source` or stricter `dex` naming | Avoid mixing Uniswap V3 and Aerodrome Slipstream positions that share NFT ids or pool addresses. |
| `chain_id` on `positions` or enforced through `wallet.network` | Aerodrome Slipstream target is Base; position identity should include chain. |
| `token0_address`, `token1_address` | Symbols are ambiguous. Contract calls and decimal lookup need addresses. |
| `token0_decimals`, `token1_decimals` | Fee and amount normalization should not depend on a transient pool-data call. |
| `tick_spacing` | Slipstream pools include tick spacing as part of pool identity and position data. |
| `tick_lower`, `tick_upper` | Needed to compute LP amounts and fee growth from pool state. |
| `liquidity` | Needed to compute current amounts and detect active/non-active range. |
| `position_manager_address` | Multiple Slipstream manager deployments exist in current sources; hardcoding one manager is unsafe. |
| `factory_address` | Pool verification and `getPool(tokenA, tokenB, tickSpacing)` checks need the relevant factory. |
| `pool_address` uniqueness scoped by chain/source | Existing single-column index on `external_id` is not enough for multi-source/multi-manager positions. |
| `last_verified_at` or service-level verification metadata | Useful for auditability when contract addresses or deployment sets change. |

## Jobs That Must Change

### `WalletSyncJob`

- Add source-aware discovery instead of unconditional `UniswapService.new`.
- Restrict Aerodrome Slipstream discovery to Base wallets unless explicitly configured otherwise.
- Discover Aerodrome position NFTs from verified position manager contracts or a verified indexer.
- Store source/dex, chain, position manager, factory, token addresses, tick range, tick spacing, liquidity, pool address, and normalized current amounts.
- Fail safely if required Aerodrome addresses or method checks are missing.

### `PositionSyncJob`

- Route by `position.dex` or source.
- Replace subgraph price and fee calls for Aerodrome positions.
- Use mocked-test RPC abstractions for `positions(tokenId)`, pool `slot0()`, factory `getPool(...)`, token `decimals()`, token `symbol()`, and any fee/amount calls selected during implementation.
- Preserve current snapshot output shape so the dashboard and hedge calculations remain stable.
- Continue to fetch Hyperliquid PnL only for active hedges; do not change Hyperliquid methods.

### `HedgeSyncJob`

- Do not change hedge sizing, execution, subaccount allocation, margin transfer, failure recording, or circuit breaker behavior.
- Add only a safety gate before Aerodrome-sourced positions can be hedged, for example `AERODROME_HEDGE_ENABLED=false` by default plus per-position monitor readiness.
- Ensure Aerodrome monitor-only positions cannot trigger live `open_short`, `close_short`, `set_leverage`, or transfers.

## Parts That Must Not Change

- `app/services/hyperliquid_service.rb`.
- Hyperliquid order execution method signatures and behavior.
- `Hedge#needs_rebalance?` sizing formula.
- Existing subaccount isolation logic in `HedgeSyncJob`.
- Existing consecutive-failure circuit breaker behavior.
- Existing `ShortRebalance` success/failed audit behavior.
- Existing mailer behavior, except any future wording cleanup after source migration.

## Proposed `AerodromeSlipstreamService` Design

Create a read-only service with dependency injection for all network clients:

- `initialize(rpc_url:, position_manager_addresses:, factory_addresses:, pricing_source:, chain_id: 8453)`.
- `fetch_positions(wallet_address)` returns the same top-level shape needed by `WalletSyncJob`, plus metadata fields required by the migration.
- `fetch_position_state(position)` returns current token amounts, liquidity, tick state, token decimals, and pool metadata.
- `fetch_pool_data(pool_address)` returns decimals and USD prices only after the pricing source is verified.
- `fetch_uncollected_fees(position)` returns normalized uncollected fees only after the fee method is verified; otherwise returns an explicit unsupported/fail-safe result.
- `verify_contract_set!` performs cheap read-only checks on configured addresses before syncing.

Implementation constraints for the later coding phase:

- No hardcoded Aerodrome addresses unless the address is documented with official docs, verified BaseScan, GitHub interface, and live RPC confirmation.
- Prefer env-configurable address lists because current Aerodrome sources show multiple Slipstream deployments.
- Use small ABI encoder/decoder helpers or a maintained ABI library already present in the app. Do not paste unverified ABI blobs.
- Log clear, non-secret errors when a required contract check fails.
- Treat unavailable price or fee data as a monitor blocker, not as zero exposure.

## Required Verification Sources Before Implementation

Every Aerodrome-specific fact must be recorded in implementation docs/tests with exact URL, contract address, method signature, return fields, date checked, and why the source is trusted.

| Fact to verify | Source URL | Contract address | Method signature | Return fields | Date checked | Why trusted |
| --- | --- | --- | --- | --- | --- | --- |
| Official Aerodrome docs are reachable and official help content exists. | `https://aerodrome.finance/docs`; `https://github.com/aerodrome-finance/docs`; `https://raw.githubusercontent.com/aerodrome-finance/docs/main/content/liquidity.mdx` | N/A | N/A | N/A | 2026-05-08 | Official Aerodrome web domain and official `aerodrome-finance/docs` GitHub repo. |
| Aerodrome has concentrated pools that use ticks/tick spacing and require range maintenance. | `https://raw.githubusercontent.com/aerodrome-finance/docs/main/content/liquidity.mdx` | N/A | N/A | N/A | 2026-05-08 | Official Aerodrome docs repository content. |
| Aerodrome Slipstream contracts repo and deployment table. | `https://github.com/aerodrome-finance/slipstream` | See repo deployment table; do not pick one without RPC/BaseScan checks. | N/A | N/A | 2026-05-08 | Official `aerodrome-finance/slipstream` repository. |
| Initial deployment position manager and factory candidates. | `https://github.com/aerodrome-finance/slipstream` | Position manager `0x827922686190790b37229fd06084350E74485b72`; factory `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | N/A | N/A | 2026-05-08 | Official deployment table links to BaseScan pages. Must still be checked on BaseScan and RPC before implementation. |
| Gauge Caps deployment position manager and factory candidates. | `https://github.com/aerodrome-finance/slipstream` | Position manager `0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F`; factory `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` | N/A | N/A | 2026-05-08 | Official deployment table links to BaseScan pages. Must still be checked on BaseScan and RPC before implementation. |
| Gauges V3 deployment position manager and factory candidates. | `https://github.com/aerodrome-finance/slipstream` | Position manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53`; factory `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | N/A | N/A | 2026-05-08 | Official deployment table labels this as current latest gauge deployment, but existing managers may still hold active positions. Verify usage before selecting. |
| Position manager `positions` return shape. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol` | Must match the manager being queried. | `positions(uint256 tokenId)` | `nonce`, `operator`, `token0`, `token1`, `tickSpacing`, `tickLower`, `tickUpper`, `liquidity`, `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`, `tokensOwed0`, `tokensOwed1` | 2026-05-08 | Official Aerodrome Slipstream interface repo. Must be cross-checked against BaseScan verified ABI for each manager. |
| Position manager `collect` return shape. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol` | Must match the manager being queried. | `collect((uint256 tokenId,address recipient,uint128 amount0Max,uint128 amount1Max))` | `amount0`, `amount1` | 2026-05-08 | Official Aerodrome Slipstream interface repo. Static-call behavior and recipient constraints must be verified by live Base RPC before use. |
| Pool `slot0` return shape. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolState.sol` | Pool address verified from factory and position metadata. | `slot0()` | `sqrtPriceX96`, `tick`, `observationIndex`, `observationCardinality`, `observationCardinalityNext`, `unlocked` | 2026-05-08 | Official Aerodrome Slipstream interface repo. Must be cross-checked on verified BaseScan pool implementation. |
| Pool `positions` return shape. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolState.sol` | Pool address verified from factory and position metadata. | `positions(bytes32 key)` | `_liquidity`, `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`, `tokensOwed0`, `tokensOwed1` | 2026-05-08 | Official Aerodrome Slipstream interface repo. Key derivation must be verified from implementation before coding. |
| Pool `collect` and `burn` behavior for fee recomputation. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolActions.sol` | Pool address verified from factory and position metadata. | `collect(address,int24,int24,uint128,uint128)`; `collect(address,int24,int24,uint128,uint128,address)`; `burn(int24,int24,uint128)`; `burn(int24,int24,uint128,address)` | `amount0`, `amount1` | 2026-05-08 | Official Aerodrome Slipstream interface repo. Do not static-call or use for fee math until owner semantics are verified. |
| Factory `getPool` and tick spacing support. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/ICLFactory.sol` | Factory address for the relevant deployment. | `getPool(address tokenA,address tokenB,int24 tickSpacing)`; `tickSpacings()`; `tickSpacingToFee(int24)` | pool address; tick spacing list; fee | 2026-05-08 | Official Aerodrome Slipstream interface repo. Must be cross-checked on verified BaseScan factory and live RPC. |
| Verified BaseScan source for initial position manager. | `https://basescan.org/address/0x827922686190790b37229fd06084350e74485b72` | `0x827922686190790b37229fd06084350E74485b72` | N/A | Verified source/ABI page | 2026-05-08 | BaseScan verified contract page; must be re-opened during implementation and matched to interface. |
| Verified BaseScan source for current factory candidate. | `https://basescan.org/address/0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | N/A | Verified `CLFactory` source/ABI page | 2026-05-08 | BaseScan verified contract page. |
| Live Base RPC checks. | Configured `BASE_RPC_URL` or a documented public Base endpoint selected by the operator. | All configured managers/factories/pools. | `eth_chainId`, `eth_getCode`, `positions(uint256)`, `getPool(...)`, `slot0()`, token `decimals()`, token `symbol()`; optional `collect(...)` static-call only after safety review. | Must match verified ABI return fields. | Not run in this planning task. | Required because GitHub/docs can drift from deployed bytecode and BaseScan labels are not enough for runtime behavior. |

## Test Strategy

- Add service-level tests for `AerodromeSlipstreamService` using WebMock to stub JSON-RPC responses.
- No tests may call live Base RPC.
- Mock `eth_chainId`, `eth_getCode`, `eth_call` for manager, factory, pool, and ERC20 reads.
- Include tests for missing code at configured addresses, wrong chain id, invalid/zero pool address, malformed return data, and unsupported fee source.
- Include amount-math tests around in-range, below-range, above-range, and zero-liquidity positions after formulas are verified from source.
- Add job tests that assert monitor-only Aerodrome positions sync snapshots but cannot call Hyperliquid execution methods.
- Keep existing Uniswap tests passing during transition.
- Add regression tests proving `HedgeSyncJob` behavior is unchanged for existing positions.

## Safety Strategy

1. Read-only first: implement contract/indexer reads and persistence only.
2. Monitor-only mode: create/update Aerodrome positions and snapshots without hedge execution.
3. Explicit feature flag: require a default-off flag before Aerodrome-sourced positions are eligible for `HedgeSyncJob`.
4. Per-position readiness: require verified amount math, pricing, fees, and source metadata before hedge enablement.
5. No live trading by default: Aerodrome migration must not call `open_short`, `close_short`, `set_leverage`, or transfer methods unless the explicit flag is enabled and tests prove the gate.
6. Fail closed: if contract verification, pricing, or fee reads fail, mark the sync as incomplete and do not hedge.
7. Audit trail: store enough source metadata to reconstruct which manager/factory/pool produced each position.

## Implementation Phases

1. Add source metadata migrations and seed the new dex/source without changing job routing.
2. Build `AerodromeSlipstreamService` verification and read-only RPC calls with mocked tests.
3. Add monitor-only wallet and position sync path for Base Aerodrome positions.
4. Add UI visibility for source, chain, manager, factory, pool, tick spacing, and readiness status.
5. Run monitor-only comparisons against known wallets with no Hyperliquid execution.
6. Add an explicit hedge eligibility gate for Aerodrome positions.
7. Only after separate approval, enable hedging for Aerodrome positions behind the default-off feature flag.

## Remaining Open Questions

- Which Aerodrome Slipstream position manager deployments should be scanned for existing user NFTs?
- Is there a trusted Aerodrome indexer/subgraph for historical collected fees, or must fees be derived only from on-chain state?
- What pricing source should replace Uniswap subgraph `derivedETH * ethPriceUSD`?
- Does static-calling position manager `collect` with a zero recipient work safely on all relevant Aerodrome managers, or must uncollected fees be computed from pool fee growth instead?
- How should staked Slipstream NFT positions be represented if ownership or fee accounting moves through gauges?
- Should position uniqueness be `(chain_id, source, position_manager_address, external_id)`?
