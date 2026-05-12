# Hedge Backend Adapter Research

Date checked: 2026-05-11

## Executive Summary

The hedge backend should be abstracted before adding any non-Hyperliquid live adapter. The current application is not just placing shorts: it depends on position readback, precision, leverage/margin setup, reduce-only close semantics, post-close nil confirmation, failed-order classification, approved-open monitoring, volatility guard inputs, and manual emergency close guarantees. A backend swap that only implements `open_short` and `close_short` would be unsafe.

Recommended sequence:

1. Define a generic hedge backend interface and return objects behind the current Hyperliquid implementation, with no behavior change.
2. Add exhaustive mocked contract tests for the interface using the current Hyperliquid service behavior as the reference implementation.
3. Build a read-only adapter proof for one candidate at a time: market metadata, mark price, account health, current ETH position, fills/order status.
4. Only after read-only proof, add testnet/sandbox order proof for open, rebalance down, reduce-only close, and final nil readback.
5. Keep production live runners pinned to Hyperliquid until a candidate passes the same safety checklist.

Feasibility rating:

- Hyperliquid: `ready`, because it is the current proven backend.
- Extended: `possible`, and likely the easiest non-Hyperliquid candidate to prototype first. Official docs expose ETH-USD examples, positions, order management, reduce-only, leverage, rate limits, testnet, and SDK surfaces.
- Ethereal: `possible`, but not ready for adapter work until sandbox order/readback behavior is proven. Official docs show ETH-USD product metadata, market orders, EIP-712 signing, subaccounts, balances, and limits.
- Nado: `possible/unknown`. Official docs and SDK exist, product docs state ETH perpetuals are supported, and order placement includes signed gateway orders with nonce, IOC/FOK/post-only, reduce-only, and rate limits, but position/readback/fills semantics need deeper official validation before design can be considered complete.

Do not implement a live Ethereal, Extended, or Nado adapter until the checklist at the end of this document is satisfied.

## Ethereal Read-Only Probe Branch Status

Date checked: 2026-05-12

This branch adds a read-only Ethereal probe and inert hedge backend foundation only. There is no Ethereal live adapter, no Ethereal order placement, no Ethereal close path, no Ethereal emergency close, and no production runner integration. Production remains Hyperliquid-only.

Implemented:

- `HedgeBackends` typed error taxonomy for future adapters.
- Inert value objects for `PositionSnapshot`, `MarketMetadata`, `AccountHealth`, and `ProbeResult`.
- `HedgeBackends::EtherealReadOnlyProbe` with documented read-only REST calls for product metadata, market price, active position readback by explicit subaccount id, and subaccount balances.
- `hedge_backends:ethereal_probe` rake task with human and JSON output.
- `hedge_backends:ethereal_probe_record` rake task for manual, sanitized, local observation capture.
- `hedge_backends:ethereal_observation_summary` rake task for offline observation analysis with no network calls.
- `docs/ETHEREAL_OPENAPI_ENDPOINT_MAP.md` maps official OpenAPI endpoints into public read-only, private read-only candidate, dangerous execution, and unknown categories.
- `docs/ETHEREAL_TESTNET_READ_ONLY_RUNBOOK.md` documents the manual testnet read-only observation workflow.
- `docs/ETHEREAL_MERGE_READINESS_CHECKLIST.md` documents merge blockers and required safety checks.
- `docs/ETHEREAL_SANDBOX_ORDER_PROOF_PLAN.md` documents a future-only sandbox order proof plan; sandbox trading is not implemented here.
- `docs/ETHEREAL_READ_ONLY_PR_REVIEW.md` documents PR review steps, safety greps, rollback, and merge decision criteria.
- `hedge_backends:ethereal_safety_check` provides a static local safety self-check with JSON output.
- Static tests guard against Ethereal references in production runtime files, dangerous method names on the read-only probe, dangerous endpoint calls in read-only service code, and dangerous Ethereal env vars.
- Mocked tests only; no real Ethereal API calls in tests.
- Documentation in `docs/ETHEREAL_READ_ONLY_PROBE.md`.

Concise status: Ethereal read-only probe exists, observation tooling exists, endpoint safety map exists, and a testnet read-only runbook exists. Sandbox order proof is explicitly separate and not implemented. Production remains Hyperliquid-only.

Pre-merge commands:

```bash
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
FORMAT=json bin/rails hedge_backends:ethereal_safety_check
git diff --name-only | grep -E 'hyperliquid_service|hedge_sync_job|aerodrome_production_live_runner|aerodrome_live_emergency_close|\.env$|\.env.production|schema|migration' || true
```

Current official docs note: Ethereal documents mainnet/testnet API hosts and OpenAPI references, and the testnet page documents dedicated RPC/chain details. Trading and signing remain outside this branch.

Official Ethereal sources checked:

- https://docs.ethereal.trade/
- https://docs.ethereal.trade/protocol-reference/api-hosts
- https://docs.ethereal.trade/developer-guides/trading-api/quick-start
- https://docs.ethereal.trade/developer-guides/trading-api/products
- https://docs.ethereal.trade/developer-guides/trading-api/order-placement
- https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers
- https://docs.ethereal.trade/developer-guides/trading-api/message-signing
- https://docs.ethereal.trade/developer-guides/trading-api/system-limits
- https://docs.ethereal.trade/developer-guides/trading-api/websockets
- https://docs.ethereal.trade/developer-guides/trading-api/tradingview-api
- https://docs.ethereal.trade/developer-guides/sdk/python-sdk
- https://api.ethereal.trade/openapi.json
- https://api.ethereal.trade/docs
- https://api.etherealtest.net/openapi.json
- https://api.etherealtest.net/docs
- https://meridianxyz.github.io

Remaining unknowns:

- `min_notional_usd` is not proven from the checked official product metadata/API schema.
- A safe production read-only authentication design is not proven.
- Live order placement, reduce-only close, fills/order-state reconciliation, final zero readback, and emergency close behavior are not proven for this application.
- Recorded observations are operator-local evidence and must not be committed if they contain real account identifiers, balances, positions, or other sensitive operational data.

Live adapter work remains prohibited until read-only proof, sandbox order proof, reduce-only close proof, fills/order-state proof, final zero readback proof, and an operator runbook exist.

### Ethereal HedgeBackend Contract Gap Matrix

| Capability | Current Ethereal proof status | Source URL | Local code status | Next proof needed |
|---|---|---|---|---|
| `market_metadata(asset)` | proven_public_read_only | https://docs.ethereal.trade/developer-guides/trading-api/products and https://api.ethereal.trade/openapi.json | Read-only probe implemented | Record real testnet observation |
| `get_mark_price(asset)` | proven_public_read_only | https://docs.ethereal.trade/developer-guides/trading-api/products and OpenAPI `GET /v1/product/market-price` | Read-only probe implemented | Confirm oracle price as mark equivalent |
| `get_position(asset, account/subaccount)` | possible_private_read_only | OpenAPI `GET /v1/position/active` | Read-only probe implemented with explicit subaccount id | Prove zero-position semantics and auth model |
| `account_health(account/subaccount)` | possible_private_read_only | OpenAPI `GET /v1/subaccount/balance` | Read-only probe implemented with explicit subaccount id | Prove margin/account value mapping |
| `fills(asset, start_time)` | possible_private_read_only | OpenAPI `GET /v1/order/fill`, `GET /v1/position/fill` | Not implemented | Prove fill schema and PnL mapping |
| `order_status(order_id/client_order_id)` | possible_private_read_only | OpenAPI `GET /v1/order`, `GET /v1/order/{id}` | Not implemented | Prove lifecycle and ambiguous state handling |
| `ensure_leverage(asset, leverage)` | unknown | No clear leverage endpoint found in checked OpenAPI | Not implemented | Prove leverage/margin model |
| `open_short` | dangerous_execution | https://docs.ethereal.trade/developer-guides/trading-api/order-placement and OpenAPI `POST /v1/order` | Not implemented and forbidden | Separate sandbox order proof |
| `rebalance_short` | dangerous_execution | Order placement plus readback APIs | Not implemented and forbidden | Separate sandbox rebalance proof |
| `close_short reduce-only` | dangerous_execution | Order schema includes reduce-only fields, but close safety is not proven | Not implemented and forbidden | Prove reduce-only close and final readback |
| final zero/nil readback | unknown | Position APIs | Not implemented | Prove post-close zero/nil behavior |
| rate limits | possible_private_read_only | https://docs.ethereal.trade/developer-guides/trading-api/system-limits and OpenAPI `GET /v1/rate-limit/config` | Not implemented | Capture official limits and pacing design |
| precision/lot size/tick size | proven_public_read_only | Product schema | Implemented | Confirm real values |
| min order size | proven_public_read_only | Product schema `minQuantity` | Implemented | Confirm semantics |
| min notional | unknown | Not found in checked product schema | Not implemented | Find official field or leave unsupported |
| collateral/account value | possible_private_read_only | Balance schema | Partially implemented | Prove full account health model |
| liquidation/margin health | possible_private_read_only | Position and balance schemas | Partially implemented | Prove liquidation/margin semantics |

## Current Hyperliquid Dependency Map

Local code checked:

- `app/services/hyperliquid_service.rb`
- `app/jobs/hedge_sync_job.rb`
- `app/services/aerodrome_live_emergency_close.rb`
- `app/services/aerodrome_production_live_runner.rb`
- `app/services/aerodrome_approved_open_position.rb`
- `app/services/aerodrome_watchdog_check.rb`
- `app/services/aerodrome_rebalance_volatility_guard.rb`

Current direct service contract:

- `HyperliquidService.normalize_symbol(symbol)` maps `WETH` to `ETH`.
- `get_position(asset, address: nil)` returns `nil` or a hash with `:asset`, signed `:size`, `:entry_price`, `:position_value`, `:margin_used`, `:mark_price`, `:unrealized_pnl`, and `:liquidation_price`.
- `get_positions(address: nil)` is used for account-wide readback and margin estimation.
- `sz_decimals(asset)` is used by `HedgeSyncJob` to floor target short size to exchange lot precision.
- `set_leverage(asset:, leverage:, is_cross:, vault_address: nil)` is called before increasing a short.
- `open_short(asset:, size:, vault_address: nil)` submits a market sell and validates nested order errors.
- `close_short(asset:, size: nil, vault_address: nil)` closes by market buy. Explicit-size close is used by emergency close and by normal reduce paths.
- `user_fills(start_time:, address: nil)` is used to estimate realized PnL after close/reduce.
- Subaccount methods are used by the older multi-position hedge path: `list_subaccounts`, `create_subaccount`, `account_balance`, `transfer_to_subaccount`, and `withdraw_from_subaccount`.

`HedgeSyncJob` assumes:

- Symbol normalization is deterministic.
- Position sizes are signed, with shorts negative.
- Size precision is available before an order is placed.
- Reducing a short can be done by buying exactly the delta.
- Increasing a short can set leverage and then sell exactly the delta.
- A nil or malformed order response is not success.
- Ambiguous order errors can be reconciled by reading the position again.
- Aerodrome live mode only sends WETH/ETH into order logic; USDC is skipped.
- Minimum notional is enforced before order placement for Aerodrome deltas.

`AerodromeLiveEmergencyClose` assumes:

- ETH position readback is available before and after close.
- A short can be closed by explicit positive size.
- Final success means the readback short size is zero or the position is nil.
- The close path can retry and record errors without raising raw network exceptions as the primary operator result.

`AerodromeProductionLiveRunner` assumes:

- It can read ETH before start, during every iteration, and during finalization.
- It does not directly place orders; it calls `HedgeSyncJob`.
- It can close on error/signal by calling `AerodromeLiveEmergencyClose`.
- It can leave a position open only on clean duration completion after final readback confirms the open ETH short is within caps.
- Runtime safety and approved-open monitoring use the same current-position shape as `HyperliquidService#get_position`.

`AerodromeApprovedOpenPosition` and `AerodromeWatchdogCheck` assume:

- Current ETH readback is authoritative.
- Approved-open state must match a previous successful production live JSONL finish event and current ETH readback within caps/tolerance.
- Safe-mode watchdog remains strict unless approved-open monitoring proves the open ETH hedge is intentional.

`AerodromeRebalanceVolatilityGuard` assumes:

- The runner can pass LP price and, when available, exchange mark price.
- If mark price is unavailable, divergence can be warned/skipped, but LP price is required when the guard is enabled.

## Proposed Generic Hedge Backend Interface

The interface should be introduced behind the existing Hyperliquid behavior first. Names below are design-level, not implemented code.

```ruby
class HedgeBackend
  def backend_name; end
  def normalize_symbol(symbol); end
  def market_metadata(asset); end
  def get_position(asset, account: nil); end
  def get_positions(account: nil); end
  def get_mark_price(asset); end
  def ensure_leverage(asset:, leverage:, margin_mode:, account: nil); end
  def rebalance_short(asset:, target_size:, current_size:, caps:, account: nil); end
  def open_short(asset:, size:, caps:, account: nil); end
  def close_short(asset:, size: nil, max_size:, reduce_only: true, account: nil); end
  def order_status(order_id: nil, client_order_id: nil); end
  def fills(asset:, start_time:, account: nil); end
  def account_health(account: nil); end
end
```

Required `PositionSnapshot` shape:

```ruby
{
  backend: "hyperliquid",
  asset: "ETH",
  market: "ETH",
  signed_size: BigDecimal("-0.3912"),
  short_size: BigDecimal("0.3912"),
  entry_price: BigDecimal("2360.0"),
  mark_price: BigDecimal("2362.0"),
  position_value: BigDecimal("923.0"),
  margin_used: BigDecimal("923.0"),
  unrealized_pnl: BigDecimal("0"),
  liquidation_price: nil,
  account: nil,
  raw: {}
}
```

Required `MarketMetadata` shape:

```ruby
{
  backend: "extended",
  asset: "ETH",
  market: "ETH-USD",
  status: "ACTIVE",
  size_decimals: 4,
  lot_size: BigDecimal("0.0001"),
  tick_size: BigDecimal("0.1"),
  min_order_size: BigDecimal("0.005"),
  min_notional_usd: BigDecimal("10"),
  max_leverage: BigDecimal("20"),
  collateral: "USDC",
  raw: {}
}
```

Required `OrderResult` shape:

```ruby
{
  backend: "hyperliquid",
  status: "filled", # submitted, filled, partially_filled, rejected, canceled, unknown
  order_id: "123",
  client_order_id: "optional",
  asset: "ETH",
  side: "sell",
  requested_size: BigDecimal("0.1"),
  filled_size: BigDecimal("0.1"),
  average_price: BigDecimal("2300"),
  reduce_only: false,
  raw: {}
}
```

Required `AccountHealth` shape:

```ruby
{
  backend: "ethereal",
  account: "primary",
  collateral: "USDe",
  account_value_usd: BigDecimal("1000"),
  withdrawable_usd: BigDecimal("100"),
  margin_used_usd: BigDecimal("900"),
  raw: {}
}
```

## Required Error Taxonomy

Adapters should raise typed errors or return typed failed results that map into these categories:

- `ConfigurationError`: missing URL, key, wallet, account, market, or unsupported asset.
- `AuthenticationError`: invalid API key, expired signer, bad signature, wrong chain/domain, or missing permission.
- `RateLimitError`: HTTP 429 or exchange-specific rate-limit response, with retry-after when available.
- `NetworkError`: timeout, DNS, SSL, disconnected websocket, or transient gateway error.
- `ExchangeRejectedOrder`: known rejected order state, including minimum notional, precision, margin, reduce-only, open interest cap, no liquidity, or price band rejection.
- `UnknownOrderState`: order submitted but status/fill cannot be confirmed.
- `ReadbackUnavailable`: position readback failed after retries.
- `PrecisionError`: target cannot be represented in exchange lot/tick units.
- `RiskLimitError`: requested cap/leverage/notional exceeds local or exchange risk limits.
- `UnsupportedOperation`: backend cannot safely implement a required method, such as reduce-only close or account health.

Safety rule: unknown must never be treated as success. Live runners may only return success after readback confirms the expected nil or approved-open state.

## Required Safety Semantics

Every backend must provide these semantics before live use:

- ETH/WETH symbol mapping is explicit and tested.
- Position readback returns a signed ETH size or nil/zero unambiguously.
- Market metadata exposes lot size, tick size, min order size, min notional, and current status.
- A short increase cannot silently flip a position long.
- A close path must be reduce-only or otherwise proven unable to increase exposure.
- Emergency close must use an independent, minimal path and must not be blocked by volatility guard.
- Final readback after close must be retried and must be authoritative for success.
- A failed or ambiguous order must create operator-visible failure state, not silent success.
- Mark price or an equivalent exchange price must be available for volatility guard and notional cap checks.
- Rate limits must be known and respected by the runner loop and finalization readbacks.
- Secrets must be scoped to the backend and never logged.
- Any backend-specific signer must be revocable or replaceable without moving the full custody wallet when possible.

## Candidate Matrix

| Capability | Hyperliquid | Ethereal | Extended | Nado |
|---|---|---|---|---|
| Feasibility | Ready | Possible, needs sandbox proof | Possible, best first non-Hyperliquid candidate | Possible/unknown, needs deeper official validation |
| ETH perpetual trading | Yes in current local integration | Yes, official product example includes `ETH-USD` | Yes, official API/SDK examples include `ETH-USD` | Yes, official product docs state ETH perpetuals are supported |
| Official API/SDK | Official API docs and Python SDK | Official Trading API docs and Python SDK docs | Official API docs and Python SDK repo | Official API docs and Python SDK docs |
| Position readback | Current code uses `user_state`; official info endpoint exposes user state/order/fill status | Subaccount/account docs show balance and subaccount queries; position endpoint details need exact API schema validation | Official private REST `Get positions` endpoint | Must verify exact official position endpoint and zero-position semantics |
| Market/IOC/reduce-only orders | Current SDK market orders; official exchange endpoint supports order actions/status | Official docs state market and limit orders; signed `TradeOrder` includes `reduceOnly`; IOC support must be verified | Official order docs expose `MARKET`, `IOC`, and `reduceOnly` fields | Official place-order docs encode IOC/FOK/post-only and reduce-only in order appendix |
| Leverage/margin config | Current code calls `update_leverage` | Product metadata exposes max leverage; exact leverage update endpoint must be verified | Official `Get current leverage` and `Update leverage` endpoints | Must verify leverage/margin endpoint and constraints |
| Authentication/signing | EVM wallet/API wallet signing via Hyperliquid SDK; API wallet/nonces documented | EIP-712 signatures; linked signers; nanosecond nonce guidance | API key for reads, Stark signature/private Stark key for writes | Signed gateway orders by linked signer; exact key lifecycle must be validated |
| Chain/account model | Hyperliquid account/subaccount/vault address model | EVM appchain with subaccounts identified by `bytes32`; settlement via Arbitrum One per docs | Starknet account/subaccount/vault model | Omnichain/self-custody model per docs; exact account abstraction needs validation |
| Collateral | Current local operations use USDC-style USD margin/account values | USDe/USD margin model per docs; subaccount balances show USD token fields | USDC collateral per official docs and SDK config | Must verify collateral assets and deposit/withdraw mechanics |
| Custody/deposits | Funds deposited to Hyperliquid account/subaccounts | Deposits to Ethereal exchange smart contracts; linked signers cannot withdraw | Self-custodied in Starknet smart contracts per docs | Docs describe CEX-less/self-custody; exact contract flow needs validation |
| Testnet/sandbox | Current app supports testnet flag | Docs are under `etherealtest.net`; API hosts/product endpoints must be validated | Official testnet endpoints and test USDC faucet documented | Must verify sandbox/testnet availability and faucet |
| Rate limits | Official user rate-limit endpoint; local code does not yet fully abstract this | Official system limits: HTTP, websocket, and account point windows | Official REST limits: default 1,000 requests/minute, higher tiers by request | Official docs: gateway/private/public limits and HTTP 429 behavior |
| Min size/notional | Current app enforces local min notional and uses `sz_decimals`; official order status includes min notional rejection | Product metadata includes ETH lot size and min quantity; min notional/risk constraints need exact validation | Market metadata exposes precision/config; min constraints need mapping | Must verify product constraints/min notional |
| Emergency close feasibility | Proven locally with manual gated close and final nil readback | Feasible if reduce-only market close and position readback are validated | Feasible due reduce-only order support and positions endpoint | Feasible only after reduce-only close and position readback are proven |
| Final nil/zero detection | Proven by `get_position("ETH")` nil/zero checks | Unknown until position endpoint zero semantics validated | Likely feasible via `Get positions` returning open positions only | Unknown until position endpoint zero semantics validated |
| Approved-open equivalent | Proven locally via JSONL + current position readback | Possible if current ETH readback is stable and signed-size convention is normalized | Possible if current ETH position readback is stable | Possible if current ETH readback is stable |
| Volatility guard equivalent | Current local integration can use mark price from position/readback | Possible; product docs expose mark/oracle prices via API/websocket | Possible; market stats expose mark/index price and websockets | Possible if mark/index/current price endpoint is available |
| Fills/order status reliability | Official info endpoint exposes fills by time and order status; locally used | Docs describe order lifecycle/status; exact fill endpoint should be validated | Official order history, order-by-id, trades, positions, websocket streams | Must validate order status/fills API reliability |

## Per-Candidate Notes

### Hyperliquid

Rating: `ready`.

Hyperliquid remains the only production-proven backend in this app. It supports the exact local safety contract: ETH position readback, market short open, explicit-size close, leverage update, precision lookup, fills by time, subaccounts, emergency close, final nil readback, approved-open monitoring, production runner caps, and volatility guard integration.

Design implication: use the existing `HyperliquidService` behavior as the reference adapter contract. Do not change it while introducing the abstraction; wrap it after tests pin the current shape.

Missing information before generic abstraction:

- Decide whether the generic interface must support subaccount assignment in V1 or whether Aerodrome ETH-only production remains main-account-only.
- Decide how much of current realized PnL calculation belongs in backend return objects versus `HedgeSyncJob`.

### Ethereal

Rating: `possible`.

Official docs show Ethereal as a perps DEX around USDe, deployed as an EVM appchain with settlement via Arbitrum One. Product docs show an active `ETH-USD` perpetual with lot size, tick size, min quantity, and max leverage. Order placement docs state market and limit orders are supported and order status is queryable through lifecycle states. Message signing docs use EIP-712 and include `TradeOrder` fields with `reduceOnly`. Accounts are subaccount-based and deposits occur through exchange smart contracts; linked signers can place/cancel orders and cannot withdraw.

Adapter risks:

- Need exact official API schema for current open positions, fills, and account health.
- Need testnet/sandbox proof for market sell, reduce-only buy, partial fill behavior, and final zero-position readback.
- Need to verify whether leverage is set per product, inferred from margin, or configured through a separate endpoint.
- Need to map USDe/USD collateral fields into the app's USD notional and margin semantics.
- Need to test linked signer expiration and revocation flows operationally.

Emergency close feasibility: possible, but blocked from production until a reduce-only close path and final nil/zero readback are proven in sandbox.

### Extended

Rating: `possible`, preferred first non-Hyperliquid prototype.

Official Extended docs describe a Starknet perpetuals DEX with self-custodied funds in on-chain smart contracts. The API includes public markets, mark/index prices, private positions, balance, order history, order-by-id, trades, current leverage, update leverage, and websocket account updates. Auth separates read-only API key access from write operations requiring a Stark signature. Official docs and SDK examples include `ETH-USD`, `MARKET`, `IOC`, `reduceOnly`, leverage, positions, and testnet configuration.

Adapter risks:

- Order placement is asynchronous: an order ID can be returned before the order is recorded. The adapter must poll order status or subscribe to private streams before declaring success.
- Need exact min order size/notional mapping from market metadata to current local cap checks.
- Need exact signed-size/side normalization for shorts.
- Need to verify reduce-only market close behavior in testnet, especially partial fills and `IOC` unmatched quantity.
- Need to operationally manage API key, Stark key, and vault number without logging secrets.

Emergency close feasibility: likely feasible if reduce-only market/IOC order plus `Get positions` readback pass sandbox tests.

### Nado

Rating: `possible/unknown`.

Official Nado docs describe a CEX-less/self-custody perps protocol and provide API docs plus a Python SDK. The product docs state perpetual trading supports assets including ETH with USDT0 settlement. The place-order docs expose a signed gateway order flow using `product_id`, signed sender/order fields, nonce, amount sign for buy/sell direction, and an appendix that encodes IOC/FOK/post-only and reduce-only behavior. Official rate-limit docs define public/private/gateway limits and HTTP 429 behavior.

Adapter risks:

- Need official confirmation of current open-position endpoint shape, zero-position semantics, fills, and order status.
- Need exact collateral, deposit, chain/account, linked-signer, and signer-revocation workflow.
- Need testnet/sandbox availability and test funds.
- Need market metadata for lot size, tick size, min order size, min notional, max leverage, and supported order statuses.
- Need to verify whether reduce-only market close can always close the current ETH short without creating long exposure.

Emergency close feasibility: unknown until the official position and reduce-only order flows are validated end to end.

## Comparison Against Current Hyperliquid Integration

| Current need | Hyperliquid behavior | Adapter requirement |
|---|---|---|
| `get_position("ETH")` | Returns nil or signed-size position hash | Every backend must normalize current ETH position to the same signed-size shape |
| Rebalance to target short | `HedgeSyncJob` computes delta, closes if delta negative, opens if positive | Backend should eventually expose `rebalance_short`, but initial wrapper can keep separate `open_short`/`close_short` |
| Emergency close | Explicit-size market buy plus retries/readback | Backend must provide reduce-only or proven non-increasing close |
| Leverage | `set_leverage` before open | Backend method may be no-op only if the exchange has no equivalent and risk is controlled by margin/caps |
| Readback after close | Final nil/zero is authoritative | Same rule across all adapters |
| Precision | `sz_decimals` from metadata | Adapter must expose lot size/size decimals and reject impossible targets before order submission |
| Min notional | Local env min plus exchange rejection handling | Adapter must expose/min-check product constraints and classify exchange min rejection |
| Error handling | Nested response validation and typed `OrderError` | Adapter must translate backend-specific errors to shared taxonomy |
| Signing/key safety | Hyperliquid key/API wallet via SDK | Adapter must isolate secrets and support read-only mode without execution keys where possible |
| Operational maturity | Proven by live runs and close tests | Candidates must pass read-only, sandbox, and supervised micro live stages separately |

## Recommended Implementation Sequence

1. Add a non-runtime design interface in docs only, then add unit tests that describe the expected backend contract.
2. Create `HedgeBackend::HyperliquidAdapter` as a thin wrapper around `HyperliquidService`, but do not route production code through it until test parity is complete.
3. Add a feature flag that selects backend in test only. Keep production pinned to Hyperliquid.
4. Refactor `HedgeSyncJob`, `AerodromeLiveEmergencyClose`, and production runner constructors to accept a backend object while defaulting to Hyperliquid behavior.
5. Add read-only probe tasks for candidate adapters before any order support.
6. Prototype Extended read-only first because its official API surface appears closest to the current requirements.
7. Add candidate testnet order proof only after read-only probes pass and mocks cover all error states.
8. Add supervised micro-run docs and gates for any candidate backend before production caps are considered.

## Do Not Implement Live Adapter Until Checklist

- Official docs confirm ETH perpetual market identifier, status, lot size, tick size, min order size, min notional, max leverage, and collateral.
- Official docs or SDK confirm current position readback and zero-position semantics.
- Official docs or SDK confirm order status, fills, partial fills, rejection states, and rate limits.
- Testnet/sandbox account is funded with non-production funds.
- Read-only adapter can fetch market metadata, mark price, account health, and ETH position without execution credentials if supported.
- Test suite mocks all HTTP/SDK calls and proves no real API/RPC calls occur.
- Open short, rebalance down, reduce-only emergency close, and final nil readback are proven in testnet/sandbox.
- Network/readback failures return `close_unknown` or failed operator output without raw stacktraces.
- Approved-open monitoring is proven against candidate position readback.
- Volatility guard can use candidate mark/index price or explicitly degrades with warnings.
- Docs define candidate-specific gates, emergency close procedure, rate-limit handling, and key rotation/revocation.
- Production remains Hyperliquid-only until a separately approved implementation task changes that.

## Sources Checked

Official/primary external sources:

- Hyperliquid Info endpoint: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/info-endpoint
- Hyperliquid Exchange endpoint: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/exchange-endpoint
- Hyperliquid Nonces and API wallets: https://hyperliquid.gitbook.io/hyperliquid-docs/for-developers/api/nonces-and-api-wallets
- Hyperliquid official Python SDK: https://github.com/hyperliquid-dex/hyperliquid-python-sdk
- Ethereal docs home: https://docs.etherealtest.net/
- Ethereal Products: https://docs.etherealtest.net/developer-guides/trading-api/products
- Ethereal Order Placement: https://docs.etherealtest.net/developer-guides/trading-api/order-placement
- Ethereal Accounts & Signers: https://docs.etherealtest.net/developer-guides/trading-api/accounts-and-signers
- Ethereal Message Signing: https://docs.etherealtest.net/developer-guides/trading-api/message-signing
- Ethereal System Limits: https://docs.etherealtest.net/developer-guides/trading-api/system-limits
- Ethereal Python SDK docs: https://meridianxyz.github.io/ethereal-py-sdk/
- Extended API docs: https://api.docs.extended.exchange/
- Extended official Python SDK repository: https://github.com/x10xchange/python_sdk/tree/starknet
- Nado docs Products: https://docs.nado.xyz/products
- Nado Place Order: https://docs.nado.xyz/developer-resources/api/gateway/executes/place-order
- Nado Rate Limits: https://docs.nado.xyz/developer-resources/api/rate-limits
- Nado Python SDK docs: https://nadohq.github.io/nado-python-sdk/index.html

Local sources:

- `app/services/hyperliquid_service.rb`
- `app/jobs/hedge_sync_job.rb`
- `app/services/aerodrome_live_emergency_close.rb`
- `app/services/aerodrome_production_live_runner.rb`
- `app/services/aerodrome_approved_open_position.rb`
- `app/services/aerodrome_watchdog_check.rb`
- `app/services/aerodrome_rebalance_volatility_guard.rb`
