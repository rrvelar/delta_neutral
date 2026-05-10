# Aerodrome Slipstream Verification Checklist

Date prepared: 2026-05-08

This document is a practical checklist for implementing Aerodrome Slipstream support on Base. It is verification/documentation only. It does not change `HyperliquidService` and does not enable live trading by default.

Manual hedge proposals added after the read-only preview work are local records only. They suggest a manual short ETH amount/notional from persisted Aerodrome WETH/USDC monitor-only position data and retain proposal history/status and local safety-limit results, but they do not call Hyperliquid, do not place orders, do not create executable `Hedge` records, and do not change `AERODROME_HEDGE_ENABLED` from false/default-off. Proposal review/rejection is not execution. Missing safety limits are warnings. Blocked proposals must not be used for execution. Stale proposals must be regenerated before any manual review. Aerodrome remains NOT READY FOR LIVE HEDGE INTEGRATION.

Aerodrome hedge-loop processing is controlled by `AERODROME_HEDGE_ENABLED=false` by default. When unset or false, `HedgeSyncJob` skips Aerodrome hedges before constructing `HyperliquidService`. When true, Aerodrome still requires `HYPERLIQUID_TESTNET=true`; missing or false skips before `HyperliquidService` construction. This is a testnet-only rehearsal path. Production live must keep `AERODROME_HEDGE_ENABLED=false` until a separate future checklist and code change add an explicit live approval gate. With both rehearsal flags enabled, only complete active Aerodrome positions with explicit hedge records and persisted asset/amount/price data may enter the existing `HedgeSyncJob` rebalance path. The Aerodrome gate supports only the ETH/WETH side; USDC and unsupported symbols are skipped before `check_and_rebalance` and must never create hedge orders. `HyperliquidService` is reused unchanged; no new Aerodrome-specific execution path exists.

Aerodrome hedge execution is additionally paused by default. `AERODROME_HEDGE_PAUSED` defaults to true when missing, so testnet rehearsal requires explicitly setting `AERODROME_HEDGE_PAUSED=false`. Optional pre-live limits can also block the Aerodrome path before the order path: `AERODROME_MAX_SHORT_ETH`, `AERODROME_MAX_SHORT_NOTIONAL_USD`, and `AERODROME_MAX_LEVERAGE`. Live trading is still not approved; live use requires a separate future checklist/change.

`docs/AERODROME_FIRST_LIVE_MICRO_RUN.md` is a documentation-only first-live plan. It does not enable live trading, does not edit env, does not add a first-live execution task, and does not add an automatic execution path. `aerodrome:live_emergency_close` is a manual ETH-only emergency close tool that is live-order capable but blocked by default behind explicit live approval, paused state, enable flag, confirmation phrase, and max ETH cap. It must be tested/read-reviewed before any first-live micro-run. Dashboard AERO rewards and LP fees are read-only estimates and are not execution approval.

The first live micro-run is documented in `docs/AERODROME_FIRST_LIVE_MICRO_RUN_REPORT.md`. Local operator evidence shows `ShortRebalance #183` successfully opened a tiny mainnet ETH short (`new_short_size=0.011`) from the WETH side, USDC was skipped, the gated live emergency close closed the short, and final mainnet ETH readback was nil. This verifies one controlled tiny mainnet open/close cycle only. It is not approval for continuous live operation or larger sizing; live automation remains disabled by default.

The first controlled 15-minute live observation window is documented in `docs/AERODROME_LIVE_OBSERVATION_WINDOW_REPORT.md`. Local operator evidence shows `ShortRebalance #184` successfully opened a tiny mainnet ETH short (`new_short_size=0.0109`), iterations 2 through 5 created no additional rebalances, USDC was skipped, the gated live emergency close closed the short, and final mainnet ETH readback was nil. This verifies one short controlled observation window only. It is not approval for continuous unattended live operation or scaling.

The first controlled 30-minute live observation window is documented in `docs/AERODROME_30M_LIVE_OBSERVATION_REPORT.md`. Local operator evidence shows `ShortRebalance #185` successfully opened a tiny mainnet ETH short (`new_short_size=0.0111`), iterations 2 through 10 created no additional rebalances, USDC was skipped, the gated live emergency close closed the short, and final mainnet ETH readback was nil. This verifies one 30-minute controlled observation window only. It is not approval for continuous unattended live operation or scaling.

## Verified Facts As Of 2026-05-08

Status legend: **VERIFIED** means checked from a trusted source in this session. **CANDIDATE** means a trusted source lists the value, but implementation should keep it configurable or verify against a concrete position before relying on it. **UNRESOLVED** means do not implement from this fact. **DEFERRED** means intentionally out of scope for the read-only migration.

### Sources Checked

| Source | Check | Result |
| --- | --- | --- |
| Official Aerodrome docs: `https://aerodrome.finance/docs` | `curl -I` | **VERIFIED** reachable, HTTP 200. |
| Official Aerodrome docs repo: `https://raw.githubusercontent.com/aerodrome-finance/docs/main/content/liquidity.mdx` | `curl` + `rg` for concentrated pool/tick spacing sections | **VERIFIED** docs describe concentrated pools and tick spacing. |
| Official Slipstream repo: `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/README.md` | `curl` + `rg` for deployments | **VERIFIED** deployment table lists three Base Slipstream deployments. |
| Official Slipstream interfaces: `INonfungiblePositionManager.sol`, `ICLFactory.sol`, `ICLPoolState.sol`, `IPeripheryImmutableState.sol` | `curl` raw GitHub files | **VERIFIED** method signatures and return fields listed below. |
| Official Slipstream CL gauge interface: `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/gauge/interfaces/ICLGauge.sol` | Web/GitHub source review | **VERIFIED** CL rewards are read with `earned(address account,uint256 tokenId)`, gauge staking can be checked with `stakedContains(address,uint256)`, and reward claiming is a separate write method that remains out of scope. |
| Official Aerodrome/Velodrome voter interface: `https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IVoter.sol` | Web/GitHub source review | **VERIFIED** `Voter.gauges(address pool)` is the read-only pool-to-gauge discovery method. |
| Hyperliquid exchange endpoint docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint` | Web/docs review | **VERIFIED** exchange actions include signed order/transfer operations; first-live runbook must not add executable commands. |
| Hyperliquid API wallets / nonces docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets` | Web/docs review | **VERIFIED** API wallets are signing wallets only; account state must be read for the master/subaccount address, not the API wallet address. |
| Hyperliquid sub-account docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/trading/sub-accounts` | Web/docs review | **VERIFIED** subaccount/vault context must be treated explicitly before live use. |
| Hyperliquid info endpoint docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint` | Web/docs review | **VERIFIED** read-only account/position state queries exist and are appropriate for live preflight. |
| Hyperliquid order type docs: `https://hyperliquid.gitbook.io/hyperliquid-docs/trading/order-types` | Web/docs review | **VERIFIED** market orders execute immediately at current market price; first live size must be intentionally tiny and operator-defined. |
| BaseScan Voter candidate: `https://basescan.org/address/0x16613524e02ad97edfeF371bc883f2f5d6c480a5#code` | Web/BaseScan page review | **CANDIDATE** verified contract address candidate for Aerodrome Voter on Base; keep `AERODROME_VOTER_ADDRESS` configurable and do not hardcode. |
| Public Base RPC: `https://base-rpc.publicnode.com` | JSON-RPC `eth_chainId`, `eth_getCode`, `eth_call` | **VERIFIED** live read-only checks listed below. No private RPC or keys used. |
| BaseScan contract pages linked from Slipstream README | URLs recorded from official repo links | **CANDIDATE** pages are the official repo-linked `#code` pages; automated proof of BaseScan source verification was not completed in this pass. |

### Verified And Candidate Facts

| Fact | Status | Source URL / command | Result |
| --- | --- | --- | --- |
| Base mainnet chain id. | **VERIFIED** | Public Base RPC `eth_chainId` against `https://base-rpc.publicnode.com`. | Returned `0x2105`, decimal `8453`. |
| Aerodrome docs availability. | **VERIFIED** | `curl -I https://aerodrome.finance/docs`. | HTTP 200. |
| Aerodrome concentrated pools use tick spacing. | **VERIFIED** | `https://raw.githubusercontent.com/aerodrome-finance/docs/main/content/liquidity.mdx`. | Docs describe concentrated pools, tick ranges, and tick spacing examples including 1, 50, 200, and 2000. |
| Current latest Slipstream deployment group in official repo. | **VERIFIED** | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/README.md`. | README marks "Gauges V3 Deployment" as current latest; it also says existing gauges are still in use. |
| Gauges V3 NonfungiblePositionManager on Base. | **CANDIDATE** | Official Slipstream README + live `eth_getCode`. | `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53`; live code exists; `factory()` returns the Gauges V3 factory below. Keep configurable because older managers may contain positions. |
| Gauges V3 PoolFactory on Base. | **CANDIDATE** | Official Slipstream README + live `eth_getCode` + manager `factory()`. | `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef`; live code exists; selected manager returns this factory. Keep configurable. |
| Initial deployment manager/factory. | **CANDIDATE** | Official Slipstream README + live `eth_getCode`. | Manager `0x827922686190790b37229fd06084350E74485b72`, factory `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A`; live code exists. Position coverage unresolved. |
| Gauge Caps deployment manager/factory. | **CANDIDATE** | Official Slipstream README + live `eth_getCode`. | Manager `0xa990C6a764b73BF43cee5Bb40339c3322FB9D55F`, factory `0xaDe65c38CD4849aDBA595a4323a8C7DdfE89716a`; live code exists. Position coverage unresolved. |
| `positions(tokenId)` uses `tickSpacing`, not Uniswap V3 `fee`. | **VERIFIED** | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol`; live `eth_call` on sample token. | Interface and live return decode include `tickSpacing`; no `fee` field in `positions(tokenId)`. |
| Exact `positions(tokenId)` return fields. | **VERIFIED** | Same interface URL + live `positions(uint256)` call. | 12 words: `nonce`, `operator`, `token0`, `token1`, `tickSpacing`, `tickLower`, `tickUpper`, `liquidity`, `feeGrowthInside0LastX128`, `feeGrowthInside1LastX128`, `tokensOwed0`, `tokensOwed1`. |
| Factory pool resolution signature. | **VERIFIED** | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/ICLFactory.sol`; live sample `getPool`. | `getPool(address tokenA,address tokenB,int24 tickSpacing)` returns `address pool`; interface says token order may be either order and returns address zero if missing. |
| Pool `slot0` return fields. | **VERIFIED** | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolState.sol`; live sample `slot0`. | 6 words: `sqrtPriceX96`, `tick`, `observationIndex`, `observationCardinality`, `observationCardinalityNext`, `unlocked`. |
| ERC721Enumerable support appears available on Gauges V3 manager. | **VERIFIED FOR SAMPLE MANAGER ONLY** | Live `supportsInterface(0x780e9d63)`, `tokenByIndex(0)`, `balanceOf(owner)`, `tokenOfOwnerByIndex(owner,0)`. | Calls returned successfully on `0xe1f8...`. Discovery still must account for staked/escrowed positions and older managers. |
| WETH9 address exposed by Gauges V3 manager. | **VERIFIED** | Live `WETH9()` on `0xe1f8...`; interface source `IPeripheryImmutableState.sol`. | Returned `0x4200000000000000000000000000000000000006`. Native ETH vs WETH app behavior remains **UNRESOLVED**. |
| Slipstream CL rewards are staked NFT/account based. | **VERIFIED** | Official Slipstream `ICLGauge.sol`. | CL gauge exposes `earned(address account,uint256 tokenId)` and `stakedContains(address,uint256)`, so rewards discovery must be defensive for wallet/account plus token id and must not assume unstaked wallet-owned NFTs are reward eligible. |
| Pool-to-gauge discovery is Voter based. | **VERIFIED** | Official `IVoter.sol`. | Voter exposes `gauges(address pool)`. Implementation keeps `AERODROME_VOTER_ADDRESS` configurable and treats zero gauge as not discoverable. |
| Reward claiming is a transaction and out of scope. | **VERIFIED** | Official Slipstream `ICLGauge.sol`. | Gauge exposes claim/write methods separately from read methods; current implementation only uses `eth_call` for discovery and `earned`. |

### Live RPC Checks Performed

| RPC URL | Method | Target | Token id | Result summary |
| --- | --- | --- | --- | --- |
| `https://base-rpc.publicnode.com` | `eth_chainId` | N/A | N/A | Returned `0x2105` (`8453`). |
| `https://base-rpc.publicnode.com` | `eth_getCode` | All three official manager candidates and all three official factory candidates | N/A | Non-empty code for all six candidate addresses. |
| `https://base-rpc.publicnode.com` | `eth_call supportsInterface(bytes4)` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | N/A | ERC721, ERC721Enumerable, and ERC721Metadata returned true. |
| `https://base-rpc.publicnode.com` | `eth_call factory()` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | N/A | Returned `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef`. |
| `https://base-rpc.publicnode.com` | `eth_call WETH9()` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | N/A | Returned `0x4200000000000000000000000000000000000006`. |
| `https://base-rpc.publicnode.com` | `eth_call tokenByIndex(0)` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | N/A | Returned sample token id `5016`. |
| `https://base-rpc.publicnode.com` | `eth_call ownerOf(uint256)` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | `5016` | Returned owner `0x23cb5f48fa3f4502232f3442637f90e8e3355701`. |
| `https://base-rpc.publicnode.com` | `eth_call positions(uint256)` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | `5016` | Returned 12 ABI words matching the official interface; sample had `token0=0x22af33fe49fd1fa80c7149773dde5890d3c76f3b`, `token1=0x4200000000000000000000000000000000000006`, `tickSpacing=200`, `tickLower=-151400`, `tickUpper=-147400`. |
| `https://base-rpc.publicnode.com` | `eth_call balanceOf(address)` and `tokenOfOwnerByIndex(address,uint256)` | Gauges V3 manager `0xe1f8cd9AC4e4A65F54f38a5CdAfCA44f6dD68b53` | Owner of token `5016` | `balanceOf(owner)` returned `2`; `tokenOfOwnerByIndex(owner,0)` returned token id `1315`. |
| `https://base-rpc.publicnode.com` | `eth_call getPool(address,address,int24)` | Gauges V3 factory `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` | Tokens from token `5016` | Returned pool `0x90757bd1595ca6e6a011e900e7a22d1a991856a5`. |
| `https://base-rpc.publicnode.com` | `eth_call slot0()` | Pool `0x90757bd1595ca6e6a011e900e7a22d1a991856a5` | N/A | Returned 6 ABI words matching the official interface; sample tick decoded to `-155876`. |
| `https://base-rpc.publicnode.com` | `eth_call decimals()`, `symbol()`, `name()` | Sample `token0` and `token1` from token `5016` | N/A | `decimals()` returned `18` for both sample tokens; `symbol()` and `name()` returned non-empty data. Do not generalize decimals. |

### Unresolved Or Deferred Facts

| Fact | Status | Fail-safe recommendation |
| --- | --- | --- |
| Whether one manager/factory pair covers all relevant user positions. | **UNRESOLVED** | Keep manager/factory configurable; consider multiple deployments. |
| Whether BaseScan source/ABI pages can be programmatically verified without an API key. | **UNRESOLVED** | Treat official README + live RPC as candidate/operational verification; still perform manual BaseScan source/ABI review before implementation. |
| Whether wallet NFT enumeration is sufficient for staked or escrowed positions. | **UNRESOLVED** | Start with user-provided token ids or mark staked/gauge discovery out of scope. |
| Exact amount0/amount1 math and rounding. | **VERIFIED FOR READ-ONLY IMPLEMENTATION** | Implemented from Aerodrome Slipstream `TickMath`, `LiquidityAmounts`, `FixedPoint96`, and `FullMath` sources using integer floor division. Still requires manual comparison against Aerodrome UI/BaseScan for real positions before hedge use. |
| Advanced uncollected fee calculation beyond `tokensOwed0`/`tokensOwed1`. | **DEFERRED** | Initial read-only scope should show only verified owed-token fields or mark fees partial. |
| USD pricing and hedge exposure readiness. | **PARTIAL** | Keep `AERODROME_HEDGE_ENABLED=false` and `AERODROME_HEDGE_PAUSED=true` by default. If explicitly enabled and unpaused, `HYPERLIQUID_TESTNET=true` is still required. Optional max short/notional/leverage gates can block before the order path. Only complete persisted ETH/WETH-side exposure may enter the existing `HedgeSyncJob` path. USDC is never hedged. |
| Native ETH vs WETH display/identity behavior. | **UNRESOLVED** | Store/read token addresses exactly as returned; do not collapse WETH to ETH without explicit verified mapping. |

## 1. Scope

The migration only replaces the LP position source:

- From: Uniswap V3 concentrated liquidity positions.
- To: Aerodrome Slipstream concentrated liquidity positions on Base.

Hyperliquid remains the perpetual venue. `HyperliquidService` must not be modified. Live hedge execution must not be enabled by default. Aerodrome support remains monitor-only unless `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, and `HYPERLIQUID_TESTNET=true` are explicitly set for testnet rehearsal after read-only sync has been verified. Production live mode requires a separate future checklist and code change.

The manual hedge proposal workflow is part of the read-only/manual review phase. It may create/read/update `AerodromeHedgeProposal` rows and display local proposal history/stale/safety status, but it must not create `Hedge` rows, must not call `HyperliquidService`, and must not submit approvals, transfers, swaps, NFT transfers, or transactions.

Proposal stale status is computed from local persisted values only. A proposal is stale when current WETH amount or notional differs materially from the proposal, when the position is inactive, or when the proposal is rejected/expired. Stale status is informational and does not trigger automated execution.

Proposal safety limits are local checks only. They compare proposal values to optional env vars for max short ETH, max short notional USD, max LP value USD, and max stale percent. Missing limits produce warnings rather than failures. Exceeded limits mark proposals `BLOCKED` for manual review, but do not trigger any transaction or external API call.

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
| Voter for CL gauge discovery | `AERODROME_VOTER_ADDRESS` | `https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IVoter.sol`; candidate BaseScan page `https://basescan.org/address/0x16613524e02ad97edfeF371bc883f2f5d6c480a5#code` | 2026-05-09 | Official interface review plus candidate verified contract page. | CANDIDATE; CONFIG ONLY | Used only for read-only `gauges(pool)` discovery when explicitly configured. Do not hardcode until final address is manually verified for the target deployment. |

## 4.1 AERO Rewards Discovery Verification

Verified facts:

| Fact | Source URL | Method signature | Date checked | Result |
| --- | --- | --- | --- | --- |
| Voter can discover a gauge for a pool. | `https://github.com/aerodrome-finance/contracts/blob/main/contracts/interfaces/IVoter.sol` | `gauges(address pool)` | 2026-05-09 | Read-only discovery can call `Voter.gauges(pool)` and treat the zero address as not discoverable. |
| Slipstream CL gauges expose staked-position reward reads. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/gauge/interfaces/ICLGauge.sol` | `earned(address account,uint256 tokenId)` | 2026-05-09 | Claimable reward is tied to account plus CL position token id, so discovery must use wallet/account and token id together. |
| Slipstream CL gauges expose a staked-position check. | Same `ICLGauge.sol` source. | `stakedContains(address account,uint256 tokenId)` | 2026-05-09 | If false, report not staked/not eligible rather than faking rewards. |
| Reward claiming is not read-only. | Same `ICLGauge.sol` source. | Claim/write methods are separate from `earned`. | 2026-05-09 | Current task must not claim, approve, transfer, or send transactions. |
| Base AERO token address is verified. | `https://basescan.org/token/0x940181a94a35a4569e4529a3cdfb74e38fd98631` | ERC20 token page/source | 2026-05-10 | AERO token for reward amount and AERO/USDC pool validation is `0x940181a94a35a4569e4529a3cdfb74e38fd98631`. |
| Base native USDC token address is verified. | `https://basescan.org/token/0x833589fcd6edb6e08f4c7c32d4f71b54bda02913` | ERC20 token page/source | 2026-05-10 | USDC token for AERO/USDC valuation is `0x833589fcd6edb6e08f4c7c32d4f71b54bda02913`. |
| Aerodrome CL gauge links to the AERO/USDC pool. | Base read-only `eth_call` against verified gauge `0x430c09546ae9249ab75b9a4ef7b5fd9a4006d6f3` | `pool()` -> `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1` | 2026-05-10 | Gauge-linked pool for read-only AERO/USDC valuation is `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1`. |
| AERO/USDC pool token order and price ABI are verified. | Base read-only `eth_call` against pool `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1` plus official Slipstream `ICLPoolState.sol` | `token0()` -> USDC, `token1()` -> AERO, `slot0()` returns `sqrtPriceX96` first | 2026-05-10 | Pool is a Slipstream CL pool suitable for existing `token0`/`token1`/`slot0` read-only price math. |
| Slipstream position manager exposes uncollected tokens owed. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/periphery/interfaces/INonfungiblePositionManager.sol` | `positions(uint256 tokenId)` returns `tokensOwed0`, `tokensOwed1`; `collect(CollectParams)` is write/payable | 2026-05-10 | Read-only fee discovery can read `tokensOwed0/tokensOwed1`; collecting remains out of scope. |
| Staked CL positions receive emissions instead of fees. | `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/gauge/interfaces/ICLGauge.sol` | `deposit(uint256 tokenId)` comment: receive emissions instead of fees; `withdraw(uint256 tokenId)` comment: receive fees instead of emissions | 2026-05-10 | Staked NFT LP fee readback is treated as unavailable until a separate verified procedure exists; dashboard must not show fake zero. |

Implementation decision: add `AERODROME_VOTER_ADDRESS`, `AERODROME_AERO_TOKEN_ADDRESS`, and `AERODROME_REWARDS_ENABLED=false` as env examples only. Rewards discovery uses mocked tests and read-only `eth_call` paths. AERO rewards are shown as discovery-only. AERO USD valuation is read-only and requires a configured verified source: `AERODROME_AERO_USD_MANUAL_PRICE` or enabled on-chain AERO/USDC pool valuation using verified Slipstream `token0()`, `token1()`, `slot0()`, and ERC20 `decimals()` reads. The verified pool address for on-chain Base AERO/USDC valuation is `0xbe00ff35af70e8415d0eb605a286d8a45466a4c1`; configure it explicitly in env rather than hardcoding it in application code. Dashboard PnL shows excluding-rewards and including-unclaimed-rewards-estimate totals separately; unclaimed rewards are not realized until claimed/sold.

Implementation decision: Aerodrome LP fee discovery is read-only. For unstaked positions only, use `NonfungiblePositionManager.positions(tokenId)` `tokensOwed0/tokensOwed1`, token decimals, and persisted position prices to show unclaimed fee estimates. Do not call `collect`. If a position is staked in a CL gauge or fee readback is not verified, report unavailable instead of fake zero. Fee estimates are separate from realized PnL until collected.

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

Implementation status: `amount0`/`amount1` calculations are implemented for read-only service and dry-run output using Aerodrome Slipstream source formulas. Raw amount math uses integer arithmetic and Solidity-style floor division. Manual comparison against Aerodrome UI/BaseScan is still required before any operational use.

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
| Exact amount0/amount1 formula to use for Slipstream positions. | VERIFIED FOR READ-ONLY IMPLEMENTATION | Source: Aerodrome Slipstream `contracts/periphery/libraries/LiquidityAmounts.sol`, `contracts/core/libraries/TickMath.sol`, `contracts/core/libraries/FixedPoint96.sol`, and `contracts/core/libraries/FullMath.sol`. |
| Whether any Slipstream-specific rounding differs from Uniswap V3 math. | VERIFIED FOR IMPLEMENTED PATH | Aerodrome Slipstream source uses integer floor division in `getAmount0ForLiquidity`, `getAmount1ForLiquidity`, and `getAmountsForLiquidity`; Ruby implementation mirrors that. |

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

Implementation status:

- A monitor-only USD valuation preview is implemented for pools where one token address matches configured `AERODROME_USDC_ADDRESS`.
- The preview uses Aerodrome Slipstream pool `slot0.sqrtPriceX96`, token decimals, and the configured USDC quote token. It assumes the configured USDC token is worth 1 USD for preview only.
- Unsupported pairs leave `asset0_price_usd` and `asset1_price_usd` nil and set valuation status to unsupported.
- The implementation does not infer USDC by symbol and does not hardcode a Base USDC address.
- Source checked for formula: `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/libraries/TickMath.sol` and `https://raw.githubusercontent.com/aerodrome-finance/slipstream/main/contracts/core/interfaces/pool/ICLPoolState.sol` on 2026-05-08.

Safety rule: If USD valuation is uncertain, do not feed Aerodrome exposure into `HedgeSyncJob`.

### Monitor-Only Hedge Preview

- `AerodromeHedgePreview` computes a preview-only 1x ETH short amount for supported configured WETH/USDC positions.
- `suggested_short_amount` equals the current WETH amount in the LP. `suggested_short_notional_usd` equals the suggested amount multiplied by the WETH USD preview price.
- Preview support requires verified amount math, supported USDC valuation, and configured `AERODROME_WETH_ADDRESS`.
- The preview reports `execution_enabled: false` and `hyperliquid_called: false`.
- It does not instantiate `HyperliquidService`, place orders, create hedges, or mark positions hedge-ready.

### UI Monitor-Only Display

- Dashboard and position views display Aerodrome positions with `Aerodrome Slipstream`, Base chain, token id, pool address, persisted amounts, supported USD prices, and estimated LP value.
- Aerodrome views show explicit `MONITOR ONLY`, `NO ORDERS`, `HEDGE DISABLED`, `HYPERLIQUID NOT CALLED`, and `NOT LIVE HEDGE-READY` labels.
- UI hedge preview is display-only. It uses persisted amounts/prices and configured WETH/USDC identity when available, does not call RPC or Hyperliquid, and shows an unavailable reason when data is incomplete.
- Aerodrome position pages do not show a create-hedge button.

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
  token0_price_usd: "0",
  token1_price_usd: "0",
  total_value_usd: "0",
  valuation_status: "supported_or_unsupported",
  valuation_source: "SOURCE_OR_NIL",
  valuation_reason: "REASON_OR_NIL",
  hedge_preview_supported: false,
  hedge_preview_reason: "REASON_OR_NIL",
  hedge_asset: "ETH_OR_NIL",
  hedge_side: "short_OR_NIL",
  suggested_short_amount: "0",
  suggested_short_notional_usd: "0",
  execution_enabled: false,
  hyperliquid_called: false,
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
- `HedgeSyncJob` must ignore Aerodrome positions while `AERODROME_HEDGE_ENABLED=false` or unset.
- `HedgeSyncJob` may process Aerodrome positions for testnet rehearsal only when `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, `HYPERLIQUID_TESTNET=true`, the position is active, an explicit hedge exists, and both assets, amounts, and USD prices are present.
- Hyperliquid mainnet Aerodrome hedge processing is additionally blocked unless `AERODROME_LIVE_APPROVED=true`. This flag is not sufficient by itself; `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, all readiness/risk gates, and WETH/ETH-only filtering are still required. Pre-live PASS is not live approval, and the first live run must be a separate future procedure.
- `bin/rails aerodrome:live_preflight_check` is a read-only first-live preflight only. It expects mainnet-mode env while live remains disabled/paused, performs no DB writes or orders, and PASS is not permission to live trade.
- Aerodrome hedge processing supports only `ETH`/`WETH` symbols mapped to Hyperliquid ETH exposure. `USDC` and all unsupported symbols must be skipped and never passed to `check_and_rebalance`.
- `HyperliquidService` must remain unchanged.
- `UniswapService` must remain functional.
- Existing tests must continue passing.
- No models, controllers, jobs, or services should be changed as part of this verification document.

### DEX Source Selection Scaffold

- `DexPositionSourceFactory` provides a small source-selection layer for LP position services.
- The default source remains `uniswap_v3`; Aerodrome Slipstream is selected only with an explicit `aerodrome_slipstream` source.
- Aerodrome service construction remains read-only and is not connected to `WalletSyncJob`, `PositionSyncJob`, `HedgeSyncJob`, or hedge exposure.
- `HyperliquidService` is untouched by this scaffold.

### Read-Only Sync Preparation

- `WalletSyncJob` can register Aerodrome Slipstream monitor-only positions only when `AERODROME_READ_ONLY_ENABLED=true` and explicit `AERODROME_SLIPSTREAM_TOKEN_IDS` are configured.
- Initial discovery is user-provided token ids only; wallet enumeration, staking/gauge discovery, and multi-manager discovery remain unresolved.
- `WalletSyncJob` and `PositionSyncJob` persist computed Aerodrome token amounts into existing `positions.asset0_amount` and `positions.asset1_amount` fields only when amount math is verified. Partial/deferred amount data leaves amounts nil and logs a clear monitor-only warning.
- Aerodrome USD prices are persisted only for supported configured-USDC pools with verified amount math. Unsupported pairs keep prices nil. Tick data, liquidity, manager, and factory metadata remain unstored in the current schema.
- `PositionSyncJob` does not create PnL snapshots for Aerodrome positions yet, because fee strategy, USD valuation, and real-position UI/BaseScan comparisons remain incomplete.
- `HedgeSyncJob` skips Aerodrome positions by default. Aerodrome exposure is only eligible for the existing hedge loop when `AERODROME_HEDGE_ENABLED=true`, `AERODROME_HEDGE_PAUSED=false`, network/live-approval gates pass, and local readiness checks pass, and only the ETH/WETH side may be hedged. The USDC side is skipped. `HyperliquidService` remains untouched.

### Manual Dry-Run Tooling

- `bin/rails aerodrome:dry_run TOKEN_IDS=...` provides manual Aerodrome Slipstream verification for explicit token ids.
- The dry-run is read-only: it performs no database writes, runs no jobs, and does not call `HyperliquidService`.
- It reports computed `amount0_raw`/`amount1_raw`, math source, and `hedge_enabled: false`; dry-run success does not make Aerodrome positions hedge-ready.
- `bin/rails aerodrome:verify_config` validates read-only Aerodrome config and only performs RPC checks when `CHECK_RPC=true`.
- `bin/rails aerodrome:live_preflight_check` validates first-live readiness read-only; optional `CHECK_HYPERLIQUID=true` is readback only and must not call execution methods.
- Dry-run hardening covers duplicate token ids, blank token ids, stable JSON output, and explicit no-DB/no-Hyperliquid/no-hedge safety output.
- See `docs/AERODROME_DRY_RUN.md`, `docs/AERODROME_OPERATOR_RUNBOOK.md`, `docs/AERODROME_PRE_LIVE_SAFETY_AUDIT.md`, and `docs/AERODROME_ROLLBACK.md`.
- These tools are still not hedge-ready and do not approve live Aerodrome hedge integration.

## 15. Configuration Plan

Proposed env vars for a later implementation task:

- `DEX_POSITION_SOURCE=uniswap_v3`.
- `BASE_RPC_URL`.
- `AERODROME_SLIPSTREAM_POSITION_MANAGER`.
- `AERODROME_SLIPSTREAM_FACTORY`.
- `AERODROME_SLIPSTREAM_TOKEN_IDS`, optional comma-separated token ids for early read-only monitoring.
- `AERODROME_USDC_ADDRESS`, optional configured USDC quote token address for monitor-only valuation preview.
- `AERODROME_WETH_ADDRESS`, optional configured WETH token address for monitor-only hedge preview.
- `AERODROME_READ_ONLY_ENABLED=false`.
- `AERODROME_HEDGE_ENABLED=false`, default-off gate for controlled Aerodrome entry into the existing hedge loop.
- `AERODROME_HEDGE_PAUSED=true`, default-on kill switch for Aerodrome hedge execution.
- `AERODROME_LIVE_APPROVED=false`, default-off hard approval gate required before any Hyperliquid mainnet Aerodrome hedge path can proceed.
- `AERODROME_REQUIRE_HYPERLIQUID_TESTNET=true`, reserved safety marker for testnet-only Aerodrome hedge rehearsal.

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
- [x] `amount0`/`amount1` math verified for read-only implementation.
- [ ] Fee strategy decided.
- [ ] Discovery strategy decided.
- [ ] Read-only service design approved.
- [ ] Mocked RPC fixtures prepared.
- [ ] Hyperliquid untouched.
- [ ] Live trading disabled.
- [ ] `bin/rake` green.

## 19. Current Recommendation

Current status: READY FOR READ-ONLY AMOUNT-MATH DRY-RUN for explicit token ids, but NOT READY FOR LIVE HEDGE INTEGRATION because pricing, advanced fees, discovery, and staked/gauge behavior remain unresolved.

Ready only for documentation and planning. The project can become READY FOR READ-ONLY SERVICE SCAFFOLD after selected manager/factory interfaces are verified against BaseScan and live RPC. It becomes READY FOR READ-ONLY SYNC only after mocked tests and at least one live position comparison against Aerodrome UI/BaseScan. It is NOT READY FOR HEDGE INTEGRATION until read-only data is verified and Aerodrome hedge execution is explicitly enabled by a later default-off feature flag.

## Implemented Scaffold Notes

- `AerodromeSlipstreamService` is a read-only RPC scaffold only.
- Tests use mocked JSON-RPC responses and do not call real RPC.
- `amount0`/`amount1` liquidity math is implemented for read-only service and dry-run reports.
- Monitor-only sync persists verified computed token amounts into existing `Position` amount fields.
- Monitor-only sync persists USD prices only for supported configured-USDC pools. Unsupported pairs keep prices nil, no Aerodrome PnL snapshots are created, and Aerodrome positions remain skipped by `HedgeSyncJob`.
- Dry-run hedge preview exists for supported configured WETH/USDC positions only. It is not persisted, does not call Hyperliquid, and does not enable trading.
- Advanced fee math beyond `tokensOwed0` and `tokensOwed1` remains deferred.
- `HyperliquidService` is untouched.
- No live hedge execution path was changed or enabled.

## Unresolved Facts That Must Be Closed

- Which Slipstream manager deployments must be scanned for user positions.
- Whether the Gauges V3 manager/factory should be the default for new positions.
- Whether ERC721Enumerable is safe enough for wallet discovery in production.
- How to discover staked/gauge/escrowed positions.
- Manual comparison of computed amount0/amount1 values against Aerodrome UI/BaseScan for real positions.
- Fee strategy beyond `tokensOwed0` and `tokensOwed1`.
- USD pricing source and stale-price handling.
- WETH/native ETH display and token identity behavior.
- Live comparison against at least one known Aerodrome UI/BaseScan position.
