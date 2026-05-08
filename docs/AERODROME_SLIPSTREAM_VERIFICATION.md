# Aerodrome Slipstream Verification Checklist

Date prepared: 2026-05-08

This document is a practical checklist for implementing Aerodrome Slipstream support on Base. It is verification/documentation only. It does not implement application code, does not change business logic, does not change `HyperliquidService`, and does not enable live trading.

## 1. Scope

The migration only replaces the LP position source:

- From: Uniswap V3 concentrated liquidity positions.
- To: Aerodrome Slipstream concentrated liquidity positions on Base.

Hyperliquid remains the perpetual venue. `HyperliquidService` must not be modified. Live hedge execution must not change in this phase. Aerodrome support must be read-only first. Aerodrome hedge usage must remain disabled until explicitly enabled by a later feature flag after read-only sync has been verified.

## 2. Trusted Sources

| Source category | Trusted for | Not trusted for |
| --- | --- | --- |
| Official Aerodrome documentation | Product-level protocol concepts such as concentrated pools, tick spacing categories, and whether pool ranges require maintenance. | Exact deployed bytecode behavior, current address selection for every active position, or ABI compatibility by itself. |
| Verified BaseScan contract pages | Deployed contract source, verified ABI, proxy/implementation links, and whether a candidate address has code on Base. | Product intent, which deployment should be used for all historical positions, or application-level safety. |
| Aerodrome/Velodrome GitHub contract interfaces | Expected Solidity method signatures and return field names for Slipstream contracts. | Proof that a specific deployed address still matches the interface without BaseScan/RPC checks. |
| Live Base RPC `eth_call` responses | Runtime behavior of configured addresses, chain id, code presence, ABI-compatible return data, and sample real-position checks. | Historical context, source authenticity, or safety by itself. |
| Comparison against Aerodrome UI/BaseScan for at least one real position | End-to-end confidence that token ids, ownership/discovery, amounts, fees, and pool metadata match user-visible data. | General proof for all positions, all managers, or all edge cases. |

## 3. Base Chain Verification

Verified facts:

| Fact | Source URL | Contract address | Method signature | Return fields | Date checked | Why trusted |
| --- | --- | --- | --- | --- | --- | --- |
| Base mainnet chain id is `8453`; live public RPC returned `0x2105`. | `https://docs.base.org/base-chain/quickstart/network-information`; live RPC `https://mainnet.base.org` | N/A | `eth_chainId` | JSON-RPC `result = 0x2105` | 2026-05-08 | Base official documentation plus live Base RPC response agree. |

Facts still requiring live verification:

| Item | Source URL | Date checked | Result | Command used | Unresolved notes |
| --- | --- | --- | --- | --- | --- |
| Configured production `BASE_RPC_URL` behavior. | Operator-provided RPC endpoint, not documented here. | Pending | UNRESOLVED | `eth_chainId`, `eth_getCode`, and sample `eth_call` checks against the configured endpoint. | Public RPC success does not prove the operator's configured RPC is reliable or archival enough. |
| Native ETH versus WETH assumptions. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/IPeripheryPayments.sol`; `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/IPeripheryImmutableState.sol` | 2026-05-08 | UNRESOLVED for app handling | Later: `WETH9()` on the selected position manager. | Periphery exposes WETH/ETH helper methods, but read-only positions should be treated as ERC20 token addresses from `positions(tokenId)` until WETH behavior is verified. |
| Whether positions are always ERC20/ERC20 pools or can include native ETH wrapping in user flows. | Same as above plus BaseScan/source for the selected manager. | 2026-05-08 | UNRESOLVED | Later: compare live WETH-position examples against Aerodrome UI/BaseScan. | Do not assume ETH and WETH are interchangeable in stored position data. |
| Safe chain-specific config behavior. | App config and future Aerodrome config. | Pending | UNRESOLVED | N/A | Missing Aerodrome config must not break existing Uniswap flows. |

## 4. Aerodrome Slipstream Contract Addresses

These addresses must be verified before coding. The official Slipstream repository lists multiple Base deployments. The latest deployment may not be the only deployment that contains user positions, so implementation should prefer environment-configurable address lists until a final discovery strategy is approved.

| Contract role | Address | Source URL | Date checked | Verification method | Status | Notes |
| --- | --- | --- | --- | --- | --- | --- |
| NonfungiblePositionManager, Gauges V3 deployment candidate | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | `https://github.com/aerodrome-finance/slipstream`; `https://basescan.org/address/0xe1f8cd9ac4e4a65f54f38a5cdafca44f6dd68b53` | 2026-05-08 | Official repo deployment table, verified BaseScan page, live `eth_getCode` returned non-empty bytecode on Base. | VERIFIED AS CURRENT LATEST CANDIDATE; DO NOT ASSUME ONLY MANAGER | Use only after implementation records exact BaseScan ABI/source and a live `positions(tokenId)` check for a known token id. Existing positions may live in older managers. |
| Factory, Gauges V3 deployment candidate | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | `https://github.com/aerodrome-finance/slipstream`; `https://basescan.org/address/0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | 2026-05-08 | Official repo deployment table, verified BaseScan page, live `eth_getCode` returned non-empty bytecode on Base. | VERIFIED AS CURRENT LATEST CANDIDATE; DO NOT ASSUME ONLY FACTORY | Use with `getPool(address,address,int24)` checks. Implementation should keep the address env-configurable. |
| NonfungiblePositionManager, Initial deployment candidate | `0x827922686190790b37229fd06084350E74485b72` | `https://github.com/aerodrome-finance/slipstream`; `https://basescan.org/address/0x827922686190790b37229fd06084350e74485b72` | 2026-05-08 | Official repo deployment table and BaseScan address page listed for later verification. | UNRESOLVED | Candidate only until live code/ABI checks and sample position checks are run. |
| Factory, Initial deployment candidate | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` | `https://github.com/aerodrome-finance/slipstream` | 2026-05-08 | Official repo deployment table listed for later verification. | UNRESOLVED | Candidate only until BaseScan and live RPC checks are run. |
| NonfungiblePositionManager, Gauge Caps deployment candidate | `0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F` | `https://github.com/aerodrome-finance/slipstream` | 2026-05-08 | Official repo deployment table listed for later verification. | UNRESOLVED | Candidate only until BaseScan and live RPC checks are run. |
| Factory, Gauge Caps deployment candidate | `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a` | `https://github.com/aerodrome-finance/slipstream` | 2026-05-08 | Official repo deployment table listed for later verification. | UNRESOLVED | Candidate only until BaseScan and live RPC checks are run. |
| Voter/gauge/staking contracts | TBD | TBD | Pending | Only needed if staked/gauge positions are brought into scope. | DO NOT USE YET | Out of scope for read-only owner-wallet token-id support until staking behavior is verified. |

Implementation decision: keep `AERODROME_SLIPSTREAM_POSITION_MANAGER` and `AERODROME_SLIPSTREAM_FACTORY` env-configurable. If multiple deployments are supported, use env-configurable comma-separated address lists or a structured config, not hardcoded constants.

## 5. NonfungiblePositionManager ABI Verification

Verified interface facts:

| Fact | Source URL | Contract address | Method signature | Return fields | Date checked | Why trusted |
| --- | --- | --- | --- | --- | --- | --- |
| Slipstream `INonfungiblePositionManager` extends `IERC721Metadata` and `IERC721Enumerable`. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol` | Must match selected manager. | Interface inheritance | `ownerOf`, `balanceOf`, `tokenURI`, `tokenOfOwnerByIndex`, `tokenByIndex`, `totalSupply` through imported ERC721 interfaces. | 2026-05-08 | Official Aerodrome Slipstream interface. Still must be cross-checked against selected BaseScan ABI and live behavior. |
| Slipstream `positions(tokenId)` uses `tickSpacing`, not a Uniswap V3 `fee` field, in the official interface. | Same as above | Must match selected manager. | `positions(uint256 tokenId)` | `nonce`, `operator`, `token0`, `token1`, `tickSpacing`, `tickLower`, `tickUpper`, `liquidity`, `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`, `tokensOwed0`, `tokensOwed1` | 2026-05-08 | Official Aerodrome Slipstream interface names the return fields. BaseScan and live call verification are still required before implementation. |
| Write/approval/transfer methods are not needed for read-only support. | Same as above | Must match selected manager. | `approve`, `setApprovalForAll`, `safeTransferFrom`, `transferFrom`, `mint`, `increaseLiquidity`, `decreaseLiquidity`, `collect`, `burn` | N/A for read-only implementation | 2026-05-08 | Contract interface exposes these methods, but they are out of scope and must not be used in the read-only migration. |

Methods to verify before implementation:

| Method | Required? | Safe to rely on now? | Verification required |
| --- | --- | --- | --- |
| `ownerOf(uint256 tokenId)` | Yes, for ownership of user-provided token ids. | UNRESOLVED | Verify BaseScan ABI and live `eth_call` for a known token id. |
| `balanceOf(address owner)` | Optional for wallet enumeration. | UNRESOLVED | Verify BaseScan ABI and live `eth_call`; compare count with UI/BaseScan. |
| `tokenOfOwnerByIndex(address owner,uint256 index)` | Optional, only if ERC721Enumerable is verified. | UNRESOLVED | Verify selected manager supports enumerable behavior and index bounds; do not rely on this for staked positions. |
| `positions(uint256 tokenId)` | Yes. | PARTIALLY VERIFIED BY INTERFACE ONLY | Verify exact deployed return structure on BaseScan ABI and live `eth_call` for a known token id. |
| `tokenURI(uint256 tokenId)` | Optional display only. | UNRESOLVED | Verify it does not introduce large/slow calls or unexpected failures. |
| `safeTransferFrom`, `approve`, `setApprovalForAll` | No. | OUT OF SCOPE | Must not be called by read-only support. |

Warning: Do not assume Uniswap V3 `positions(tokenId)` return shape. Verify Aerodrome Slipstream return fields from current interfaces and contract source.

## 6. Position Discovery Strategy

A. Direct wallet ERC721 enumeration:

- Uses `balanceOf(owner)` and `tokenOfOwnerByIndex(owner,index)`.
- Only valid if ERC721Enumerable is verified on the selected deployed manager.
- Pros: direct wallet-owned token discovery.
- Cons: misses staked/escrowed positions and can fail if enumerable behavior is incomplete or expensive.

B. Event/log based discovery:

- Uses ERC721 `Transfer` events and current `ownerOf(tokenId)` checks.
- Pros: can reconstruct historical token ids without enumerable support.
- Cons: requires reliable log range scanning, reorg handling, multiple manager addresses, and staked-owner interpretation.

C. User-provided token IDs:

- Safest fallback for early read-only mode.
- Requires only selected manager address, `ownerOf(tokenId)`, and `positions(tokenId)`.
- Useful if enumerable support or staked positions are uncertain.

D. Staked/gauge positions:

- Out of scope until verified.
- Positions may not be visible via wallet `ownerOf` if deposited into a gauge/staking contract. Do not treat missing wallet ownership as proof a user has no economic exposure until staking flows are verified.

Implementation decision: support user-provided token IDs first if discovery is uncertain. Add wallet discovery only after ERC721Enumerable or event strategy is verified against Aerodrome UI/BaseScan and at least one real wallet.

## 7. Factory and Pool Resolution

Verified interface facts:

| Fact | Source URL | Contract address | Method signature | Return fields | Date checked | Why trusted |
| --- | --- | --- | --- | --- | --- | --- |
| Slipstream factory resolves pools with token pair plus tick spacing. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/ICLFactory.sol` | Must match selected factory. | `getPool(address tokenA,address tokenB,int24 tickSpacing)` | `pool` address; zero address if missing per interface comment | 2026-05-08 | Official Aerodrome Slipstream factory interface. Must be cross-checked against selected BaseScan ABI and live `eth_call`. |
| Token order may be either order for `getPool`. | Same as above | Must match selected factory. | `getPool(address tokenA,address tokenB,int24 tickSpacing)` | `pool` | 2026-05-08 | Official interface comment states tokenA/tokenB may be passed either order. Verify deployed behavior with live calls. |
| Factory exposes `tickSpacingToFee(int24)` and `tickSpacings()`. | Same as above | Must match selected factory. | `tickSpacingToFee(int24)`; `tickSpacings()` | `fee`; `int24[]` | 2026-05-08 | Official interface. Use for metadata only after deployed verification. |

Placeholders for implementation verification:

| Item | Value |
| --- | --- |
| Method signature | `getPool(address tokenA,address tokenB,int24 tickSpacing)` |
| Interface source URL | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/ICLFactory.sol` |
| BaseScan source URL | `BASESCAN_FACTORY_SOURCE_URL_PLACEHOLDER` |
| Live `eth_call` command | See section 17. |
| Expected response example | `0x000000000000000000000000POOL_ADDRESS_20_BYTES` for an existing pool; zero address for a missing pool. |

Fail safely if pool address is zero: mark the position as partial/invalid, do not estimate amounts, do not value it, and do not pass it to `HedgeSyncJob`.

## 8. Pool ABI and State Verification

Verified interface facts:

| Fact | Source URL | Contract address | Method signature | Return fields | Date checked | Why trusted |
| --- | --- | --- | --- | --- | --- | --- |
| Slipstream pool `slot0()` returns six fields in the official interface. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolState.sol` | Must match resolved pool address. | `slot0()` | `sqrtPriceX96`, `tick`, `observationIndex`, `observationCardinality`, `observationCardinalityNext`, `unlocked` | 2026-05-08 | Official Aerodrome Slipstream pool state interface. Must be verified against deployed pool source and live call. |
| Pool `liquidity()` returns currently in-range liquidity and includes staked liquidity. | Same as above | Must match resolved pool address. | `liquidity()` | `uint128` | 2026-05-08 | Official interface comment. This is pool-level state, not the position's total liquidity. |
| Pool `ticks(int24)` includes fee growth outside fields and staked liquidity net. | Same as above | Must match resolved pool address. | `ticks(int24 tick)` | `liquidityGross`, `liquidityNet`, `stakedLiquidityNet`, `feeGrowthOutside0X128`, `feeGrowthOutside1X128`, `rewardGrowthOutsideX128`, `tickCumulativeOutside`, `secondsPerLiquidityOutsideX128`, `secondsOutside`, `initialized` | 2026-05-08 | Official interface. Fee math must be deferred until fully tested. |
| Pool `positions(bytes32 key)` returns position liquidity and owed-token fields by key. | Same as above | Must match resolved pool address. | `positions(bytes32 key)` | `_liquidity`, `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`, `tokensOwed0`, `tokensOwed1` | 2026-05-08 | Official interface. Key derivation must be verified before use. |
| Pool exposes `fee()` and `unstakedFee()`. | Same as above | Must match resolved pool address. | `fee()`; `unstakedFee()` | `uint24` fee values | 2026-05-08 | Official interface. Do not confuse these with position manager `tickSpacing`. |

Warning: Do not assume Uniswap V3 `slot0` shape unless verified against current Slipstream pool interface/source.

## 9. Token Metadata Verification

Required ERC20 metadata methods:

- `decimals()`.
- `symbol()`.
- `name()`.

Failure strategy:

- `decimals()` failure must fail position valuation safely. Never guess decimals.
- `symbol()` or `name()` failure may fall back to address-shortening in UI.
- Cache decimals carefully if implemented later; cache by `(chain_id, token_address)` and invalidate only deliberately.

Required tests:

- Normal decimals response.
- Decimals call failure.
- Malformed RPC response.
- Token symbol/name failure fallback.
- Non-standard token metadata response handling if encountered in live checks.

## 10. Liquidity Math Verification

Amount calculations must account for:

- Below range.
- In range.
- Above range.
- Liquidity as an integer.
- `sqrtPriceX96`.
- `tickLower`.
- `tickUpper`.
- Sqrt ratios.
- BigDecimal/integer precision approach.
- Rounding strategy.
- Avoiding float precision loss.

Instruction: Do not implement `amount0`/`amount1` calculations until the formula is verified from trusted sources and covered by tests.

Required tests:

- Below range position.
- In-range position.
- Above range position.
- Zero liquidity.
- Extreme ticks.
- `token0` decimals not equal to `token1` decimals.
- Comparison against known fixture values from Aerodrome UI/BaseScan and live RPC.

Unresolved facts:

| Fact | Status | Notes |
| --- | --- | --- |
| Exact amount0/amount1 formula to use for Slipstream positions. | UNRESOLVED | Must be verified from Aerodrome/Velodrome source or a trusted math library, then cross-checked against a real position. |
| Whether any Slipstream-specific rounding differs from Uniswap V3 math. | UNRESOLVED | Do not assume identical math. |

## 11. Fees Verification

Safe first reads:

- `tokensOwed0` from position manager `positions(tokenId)` after live verification.
- `tokensOwed1` from position manager `positions(tokenId)` after live verification.

Deferred unless fully verified:

- Uncollected fee calculation from `feeGrowthInside*` fields.
- Fee growth outside/inside logic using pool `ticks`.
- Tick crossing edge cases.
- Gauge/staked-liquidity fee and reward behavior.

Recommendation: Initial read-only implementation may show `tokensOwed0` and `tokensOwed1` only and mark advanced uncollected fee calculation as deferred unless verified and tested.

## 12. Pricing / USD Valuation

Existing app behavior:

- `UniswapService#fetch_pool_data` uses subgraph token `derivedETH` multiplied by `bundle.ethPriceUSD`.
- `PositionSyncJob` uses those USD prices for `asset0_price_usd`, `asset1_price_usd`, `entry_value_usd`, snapshots, and portfolio value.

Aerodrome verification required:

- Whether an Aerodrome indexer provides trustworthy USD pricing.
- How ETH/USD or token/USD price is sourced.
- Whether Aerodrome pool price is enough for hedge exposure. Pool price alone gives relative token price, not USD value.
- Whether an external USD pricing source is required.
- Stale-price detection and behavior.

Safety rule: If USD valuation is uncertain, do not feed Aerodrome exposure into `HedgeSyncJob`.

## 13. Normalized Position Data Shape

Proposed internal read-only structure, not implemented yet:

```ruby
{
  dex_source: "aerodrome_slipstream",
  chain_id: 8453,
  token_id: "TOKEN_ID",
  owner_address: "0x...",
  position_manager_address: "0x...",
  factory_address: "0x...",
  pool_address: "0x...",
  token0_address: "0x...",
  token1_address: "0x...",
  token0_decimals: 18,
  token1_decimals: 6,
  token0_symbol: "TOKEN0",
  token1_symbol: "TOKEN1",
  tick_lower: -1200,
  tick_upper: 1200,
  tick_spacing: 200,
  liquidity: "0",
  sqrt_price_x96: "0",
  current_tick: 0,
  amount0_raw: "0",
  amount1_raw: "0",
  amount0_decimal: "0",
  amount1_decimal: "0",
  tokens_owed0_raw: "0",
  tokens_owed1_raw: "0",
  last_synced_at: "TIMESTAMP",
  verification_status: "partial",
  partial_data_reason: "pricing_unverified"
}
```

This structure is read-only and must not contain private keys, approvals, transaction calldata, or order instructions.

## 14. App Integration Constraints

- `WalletSyncJob` may discover positions only in read-only mode.
- `PositionSyncJob` may refresh read-only position data.
- `HedgeSyncJob` must ignore Aerodrome positions until an explicit later flag is enabled.
- `HyperliquidService` must remain unchanged.
- `UniswapService` must remain functional.
- Existing tests must continue passing.
- No models, controllers, jobs, or services should be changed as part of this verification document.

## 15. Configuration Plan

Proposed env vars for a later implementation task:

- `BASE_RPC_URL`.
- `AERODROME_SLIPSTREAM_POSITION_MANAGER`.
- `AERODROME_SLIPSTREAM_FACTORY`.
- `AERODROME_READ_ONLY_ENABLED=false`.
- `AERODROME_HEDGE_ENABLED=false`, reserved for later.

Rules:

- Missing Aerodrome config must not break existing Uniswap dev/test flows.
- Missing Aerodrome config should fail safely only when Aerodrome mode is selected.
- `.env` must not be edited by Codex.
- `.env.example` may be updated in a later implementation task.

## 16. Test Strategy

Unit tests:

- ABI encoding/decoding.
- `positions(tokenId)` parsing.
- Factory `getPool` parsing.
- `slot0` parsing.
- Token decimals parsing.
- Failure handling.

Service tests:

- Read-only service never creates transactions.
- No private key required.
- No Hyperliquid call.
- Missing config failure.
- Malformed RPC response failure.
- Partial data handling.

Job tests:

- Uniswap path unchanged.
- Aerodrome path only active when selected.
- `HedgeSyncJob` ignores Aerodrome positions by default.
- No live RPC calls.

UI tests:

- Aerodrome positions labeled as Aerodrome Slipstream / Base.
- Monitor-only warning.
- Partial-data warning.
- No guessed values silently displayed.

All tests must use mocked RPC responses. No real RPC calls in tests.

## 17. Live Verification Commands To Run Later

Templates only. Do not include secrets. Do not require private keys.

Check Base chain ID:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

Check code exists at a configured contract:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getCode","params":["POSITION_MANAGER_ADDRESS_PLACEHOLDER","latest"],"id":1}'
```

Call `NonfungiblePositionManager.positions(tokenId)`:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"POSITION_MANAGER_ADDRESS_PLACEHOLDER","data":"POSITIONS_CALLDATA_PLACEHOLDER"},"latest"],"id":1}'
```

Call factory `getPool`:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"FACTORY_ADDRESS_PLACEHOLDER","data":"GET_POOL_CALLDATA_PLACEHOLDER"},"latest"],"id":1}'
```

Call pool `slot0`:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"POOL_ADDRESS_PLACEHOLDER","data":"SLOT0_CALLDATA_PLACEHOLDER"},"latest"],"id":1}'
```

Call ERC20 `decimals`:

```bash
curl -sS -X POST BASE_RPC_URL_PLACEHOLDER \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_call","params":[{"to":"TOKEN_ADDRESS_PLACEHOLDER","data":"DECIMALS_CALLDATA_PLACEHOLDER"},"latest"],"id":1}'
```

Compare one known position against Aerodrome UI/BaseScan:

```text
1. Open Aerodrome UI position for TOKEN_ID_PLACEHOLDER.
2. Open BaseScan token/contract views for POSITION_MANAGER_ADDRESS_PLACEHOLDER and TOKEN_ID_PLACEHOLDER.
3. Run ownerOf, positions, factory getPool, pool slot0, token decimals, token symbols, and amount math locally.
4. Record UI/BaseScan values, RPC values, block number, and differences in this document or a follow-up verification log.
```

## 18. Implementation Readiness Checklist

- [ ] NonfungiblePositionManager address verified.
- [ ] Factory address verified.
- [ ] `positions(tokenId)` return structure verified.
- [ ] `tickSpacing` versus `fee` verified.
- [ ] Pool `getPool` signature verified.
- [ ] `slot0` return structure verified.
- [ ] Token decimals verified.
- [ ] `amount0`/`amount1` math verified.
- [ ] Fee strategy decided.
- [ ] Discovery strategy decided.
- [ ] Read-only service design approved.
- [ ] Mocked RPC fixtures prepared.
- [ ] Hyperliquid untouched.
- [ ] Live trading disabled.
- [ ] `bin/rake` green.

## 19. Current Recommendation

Current status: NOT READY FOR IMPLEMENTATION for full Aerodrome support because key contract details remain unresolved for real positions, discovery, pricing, amount math, and staked/gauge behavior.

Ready only for documentation and planning. The project can become READY FOR READ-ONLY SERVICE SCAFFOLD after selected manager/factory interfaces are verified against BaseScan and live RPC. It becomes READY FOR READ-ONLY SYNC only after mocked tests and at least one live position comparison against Aerodrome UI/BaseScan. It is NOT READY FOR HEDGE INTEGRATION until read-only data is verified and Aerodrome hedge execution is explicitly enabled by a later default-off feature flag.

## Unresolved Facts That Must Be Closed

- Which Slipstream manager deployments must be scanned for user positions.
- Whether the Gauges V3 manager/factory should be the default for new positions.
- Whether ERC721Enumerable is safe enough for wallet discovery in production.
- How to discover staked/gauge/escrowed positions.
- Exact amount0/amount1 math and rounding for Slipstream positions.
- Fee strategy beyond `tokensOwed0` and `tokensOwed1`.
- USD pricing source and stale-price handling.
- WETH/native ETH display and token identity behavior.
- Live comparison against at least one known Aerodrome UI/BaseScan position.
