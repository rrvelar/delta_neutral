# Extended Exchange Integration Feasibility

Date checked: 2026-05-25

This document is a research, implementation, and operations artifact. It does
not add credentials, does not approve Extended auto-rebalance, and does not
change the current production hedge venue. Current production remains Ethereal;
Nado is flat and disabled. Extended manual mainnet probes are available only
behind explicit live gates and signer health checks.

## Sources Checked

- Extended API docs: https://api.docs.extended.exchange/
- Extended technical architecture: https://docs.extended.exchange/about-extended/technical-architecture
- Extended testnet docs: https://docs.extended.exchange/extended-resources/more/testnet
- Extended Python SDK: https://github.com/x10xchange/python_sdk
- SDK files inspected from a temporary clone in `/private/tmp/extended_python_sdk`:
  - `README.md`
  - `x10/config.py`
  - `x10/core/stark_account.py`
  - `x10/clients/rest/rest_api_client.py`
  - `x10/clients/rest/modules/account_module.py`
  - `x10/clients/rest/modules/info_module.py`
  - `x10/clients/rest/modules/order_management_module.py`
  - `x10/clients/stream/stream_client.py`
  - `x10/perpetual/order_object.py`
  - `x10/perpetual/order_object_settlement.py`
  - `x10/models/market.py`
  - `x10/models/position.py`
  - `x10/models/balance.py`
  - `x10/models/order.py`
  - `examples/onboarding_example.py`

## Feasibility Verdict

Extended is feasible as a future delta_neutral hedge venue, but it should stay
manual-only until more of the lifecycle is proven. The implemented path is:

1. Documentation-only.
2. Read-only Ruby adapter.
3. Dry-run order planning and payload summaries.
4. Separate Stark signer sidecar with SDK-parity hashing/signing.
5. Controlled mainnet probes behind explicit gates.
6. Auto-rebalance only after open, close, delta increase/decrease, delayed
   reconciliation, and operational rollback are proven.

The main integration risks are key handling, Stark order signing, async order
confirmation, leverage/margin semantics, and the need to reconcile REST
acceptance against WebSocket/account readback truth. Extended write access
requires a Stark private key. Treat it as full trading/funds access.

## Protocol and Architecture

Extended is a perpetuals DEX built on Starknet. Its architecture is a hybrid
CLOB: order processing, matching, position risk assessment, and transaction
sequencing occur off-chain, while validation and settlement occur on Starknet.
Extended docs state that trades and other collateral-affecting state changes are
validated through Starknet/on-chain health checks.

API hosts verified:

| Network | REST base URL | Stream URL | Signing domain |
| --- | --- | --- | --- |
| Mainnet | `https://api.starknet.extended.exchange/api/v1` | `wss://api.starknet.extended.exchange/stream.extended.exchange/v1` | `extended.exchange` |
| Testnet | `https://api.starknet.sepolia.extended.exchange/api/v1` | `wss://api.starknet.sepolia.extended.exchange/stream.extended.exchange/v1` | `starknet.sepolia.extended.exchange` |

The SDK config uses Starknet domain:

| Network | Domain name | Version | Chain id | Revision |
| --- | --- | --- | --- | --- |
| Mainnet | `Perpetuals` | `v0` | `SN_MAIN` | `1` |
| Testnet | `Perpetuals` | `v0` | `SN_SEPOLIA` | `1` |

## Account, Subaccount, Vault, Client Model

User observations and SDK docs align:

- A connected Ethereum wallet can create up to ten Extended subaccounts.
- Each subaccount has its own API key, Stark public/private key, and vault
  number.
- The SDK represents the trading identity as `StarkPerpetualAccount(vault,
  private_key, public_key, api_key)`.
- The `vault` is used as the `collateralPosition` / position id in the signed
  order settlement payload.
- The API key authenticates REST and WebSocket access.
- The Stark private key signs write operations.
- `accountIndex` is part of the Ethereum typed data used for onboarding /
  subaccount creation.
- `clientId` appears in user/referral surfaces and API-management UI. It should
  be captured as operational metadata, but order signing in the SDK uses vault,
  Stark key, market metadata, fee, nonce, and Starknet domain rather than
  `clientId` directly.

Open questions before implementation:

- Whether `clientId` must be included in any production order metadata for this
  account.
- Whether account leverage is per-market configurable and whether Extended
  should be operated at 1x effective leverage or a configured leverage.
- Whether the UI-created Stark private key is exportable only once. The docs
  show SDK deterministic derivation from an Ethereum signature, but production
  recovery must be tested on testnet before relying on it.

## Authentication and Key Model

Extended docs state:

- Read-only operations such as market data, account information, and order
  history require only an API key.
- Write operations such as create orders, transfers, and withdrawals require an
  API key and valid Stark signature.
- Private WebSocket account updates use header `X-Api-Key: <api key>`.

SDK request header:

- `X-Api-Key` from `x10/utils/http.py`.

Signer recommendation:

- Do not use `delta-neutral-eip712-signer` for Extended. Extended uses Stark
  order hashes/signatures, not EIP-712 exchange order signing.
- Add a separate Extended/Stark signer sidecar if live trading is ever built.
- The sidecar should read `EXTENDED_STARK_PRIVATE_KEY_FILE` from a root-owned
  `0600` file outside Rails and outside the repo.
- Rails should send an unsigned canonical order intent or order hash to the
  sidecar and receive only `(r, s)` plus public key diagnostics.
- The sidecar must never expose the Stark private key in `/health`, logs,
  receipts, exceptions, or process args.

Implications:

- Deleting an API key removes REST/WS access for that key but does not remove
  the Stark private key's signing authority if another API key is created for
  the same subaccount.
- Losing a Stark private key can prevent live trading/signing from the bot.
- Leaking a Stark private key is critical because it can authorize trading,
  transfers, and withdrawals where supported.

## Read-Only Endpoint Map

All paths below are relative to `/api/v1`.

| Need | Endpoint | Auth | Key fields | delta_neutral mapping |
| --- | --- | --- | --- | --- |
| Markets | `GET /info/markets?market={market}` | None | `name`, `type`, `active`, `marketStats.markPrice`, `marketStats.bidPrice`, `marketStats.askPrice`, `tradingConfig.minOrderSize`, `minOrderSizeChange`, `minPriceChange`, `maxMarketOrderValue`, `maxLeverage`, `l2Config` | market symbol, mark price, increments, caps, settlement ids |
| Market stats | `GET /info/markets/{market}/stats` | None | `lastPrice`, `askPrice`, `bidPrice`, `markPrice`, `indexPrice`, `fundingRate` | mark/price fallback |
| Order book | `GET /info/markets/{market}/orderbook` | None | bids/asks | crossing IOC price preview |
| Account details | `GET /user/account/info` | API key | `status`, `l2Key`, `l2Vault`, `accountId`, `description`, `bridgeStarknetAddress` | account configured/active, vault number |
| Balance | `GET /user/balance` | API key | `balance`, `equity`, `availableForTrade`, `availableForWithdrawal`, `unrealisedPnl`, `initialMargin`, `marginRatio` | collateral/account value, margin, effective leverage denominator |
| Positions | `GET /user/positions?market={market}&side={side}` | API key | `market`, `status`, `side`, `leverage`, `size`, `value`, `openPrice`, `markPrice`, `unrealisedPnl`, `realisedPnl`, `liquidationPrice` | side, short_size, entry, mark, notional, PnL, leverage |
| Position history | `GET /user/positions/history` | API key | size/open/exit/realised PnL | lifecycle diagnostics |
| Open orders | `GET /user/orders?market={market}` | API key | `id`, `externalId`, `status`, `side`, `qty`, `filledQty`, `reduceOnly`, `postOnly`, `timeInForce` | pending order detection and duplicate prevention |
| Order history | `GET /user/orders/history` | API key | historical order rows | reconciliation diagnostics |
| Order by id | `GET /user/orders/{order_id}` | API key | order status/filled quantity | REST fallback confirmation |
| Order by external id | `GET /user/orders/external/{external_id}` | API key | order rows | idempotency/recovery |
| Trades/fills | `GET /user/trades?market={market}` | API key | `orderId`, `side`, `price`, `qty`, `value`, `fee` | fills, realized fees |
| Fees | `GET /user/fees?market={market}` | API key | maker/taker fee | required `fee` field for order signing |
| Current leverage | `GET /user/leverage?market={market}` | API key | `market`, `leverage` | margin/leverage status only |
| Funding history | `GET /info/{market}/funding` | None | funding rows | optional analytics |
| Account stream | `GET /stream.extended.exchange/v1/account` | API key | `ORDER`, `TRADE`, `BALANCE`, `POSITION` events | final order/position truth |

Normalized `HedgeVenues::Extended#read_position("ETH")` should return:

```ruby
{
  venue: "Extended",
  symbol: "ETH-PERP",
  market_symbol: "ETH-USD",
  side: "short",
  size: "-0.1234",
  short_size: "0.1234",
  margin_mode: "cross_or_configured",
  entry_price: "...",
  mark_price: "...",
  notional_usd: "...",
  unrealized_pnl_usd: "...",
  account_value_usd: "...",
  collateral_usd: "...",
  effective_leverage: "..."
}
```

Extended docs expose current leverage with `GET /user/leverage` and leverage
updates with `PATCH /user/leverage`. The docs reviewed do not expose a
separate per-position isolated/cross margin-mode field equivalent to Nado
isolated margin. Until isolated or isolated-equivalent account semantics are
operator-verified, Extended live submit is blocked.

## Trading Semantics for Future Work

Market:

- Verify ETH market from `GET /info/markets`; likely `ETH-USD`, but do not
  hardcode without live read-only confirmation.
- Use only `type: "PERPETUAL"` markets for hedge positions.

Side mapping:

- `SELL` opens/increases an ETH short.
- `BUY` decreases/closes an ETH short.
- Decrease and close must use `reduceOnly: true`.

Order type:

- Extended supports `LIMIT`, `MARKET`, `CONDITIONAL`, and `TPSL`.
- API market orders must use `timeInForce: "IOC"`.
- Price is still required as worst accepted price in collateral asset. The docs
  note that the UI applies a crossing buffer: buys use best ask times
  `(1 + 1.5%)`, sells use best bid times `(1 - 1.5%)`.
- For hedge execution, use crossing IOC with explicit worst price and bounded
  slippage rather than pretending there is a price-free market order.

Order payload fields from docs/SDK:

- `id`: client assigned external order id.
- `market`: e.g. `ETH-USD` after verification.
- `type`: `MARKET` or `LIMIT`.
- `side`: `BUY` or `SELL`.
- `qty`: base asset quantity.
- `price`: worst accepted price.
- `reduceOnly`: boolean.
- `postOnly`: boolean.
- `timeInForce`: `IOC` for market-like crossing.
- `expiryEpochMillis`: epoch ms.
- `fee`: highest accepted fee decimal, taker for IOC.
- `nonce`: integer between 1 and `2^31`.
- `selfTradeProtectionLevel`: `ACCOUNT` by default.
- `settlement.signature.r/s`, `settlement.starkKey`,
  `settlement.collateralPosition`.

SDK signing details:

- `create_order_object` builds the API request.
- `create_order_settlement_data` computes Stark amounts, fee amount, nonce,
  expiration, and order hash.
- Buy orders negate collateral amount; sell orders negate synthetic amount in
  settlement hashing.
- Settlement expiration is order expiration plus a 14-day buffer in seconds.
- The Stark signer signs the order hash with the Stark private key.

Confirmation:

- REST `POST /user/order` returns Extended order id and external id after API
  acceptance.
- Docs explicitly warn that a REST-accepted order can later be canceled or
  rejected by the matching engine.
- Production success must require account WebSocket order/position updates or
  later REST/readback confirmation. Do not mark success from REST acceptance
  alone.

## SDK Reuse Assessment

Ruby implementation is reasonable for read-only REST and dashboard formatting.
Ruby implementation is not the safest first choice for Stark signing/order hash
construction because the SDK uses `fast_stark_crypto` and StarkEx/Starknet
domain-specific hashing.

Recommended split:

- Rails:
  - read-only REST adapter;
  - normalized current position/account state;
  - order planning and fail-closed preflight;
  - receipt storage and `ShortRebalance` records.
- Python sidecar:
  - build canonical SDK order object;
  - sign Stark order hash;
  - optionally submit in testnet/mainnet phases only after explicit gate;
  - report redacted payload, hash, signature metadata, and response.

Do not vendor the whole SDK into Rails. Either call a small audited sidecar that
depends on `x10-python-trading-starknet`, or port only read-only schemas and keep
signing external.

## Fit Into delta_neutral

Existing patterns to reuse:

- `HedgeVenues::Ethereal` for cross-margin readback/account normalization.
- `EtherealHedgeExecutionService` for preview, preflight, receipts, readback
  polling, pending reconciliation, and delta live probes.
- `NadoPendingRebalanceReconciler` and `EtherealPendingRebalanceReconciler` for
  delayed confirmation rules.
- `HedgeSyncJob` venue routing by `hedge.execution_venue`.
- `ShortRebalance` fields for venue, old/new short, order side, reduce-only,
  status, message, exchange order id, and receipt path.

Proposed classes:

- `HedgeVenues::Extended`
  - read-only account and position adapter;
  - disabled by default;
  - no submit methods.
- `ExtendedHedgeExecutionService`
  - phase 2 dry-run planner only;
  - no signing or submit in Rails initially;
  - preflight returns blockers until explicit testnet/live gates exist.
- `ExtendedPendingRebalanceReconciler`
  - later, after any live proof; readback-only success rules.
- `HedgeBackends::ExtendedReadOnlyProbe`
  - encapsulates REST GETs and redaction.
- `ExtendedStarkSigner` sidecar
  - separate from EIP-712 signer;
  - opt-in testnet/mainnet modes;
  - file-based key loading only.

Proposed env names, not added to real env in this task:

- `EXTENDED_ENABLED=false`
- `EXTENDED_NETWORK=testnet|mainnet`
- `EXTENDED_API_BASE_URL`
- `EXTENDED_STREAM_URL`
- `EXTENDED_API_KEY`
- `EXTENDED_ACCOUNT_ID`
- `EXTENDED_VAULT_NUMBER`
- `EXTENDED_CLIENT_ID`
- `EXTENDED_STARK_PUBLIC_KEY`
- `EXTENDED_STARK_PRIVATE_KEY_FILE`
- `EXTENDED_MARKET_SYMBOL=ETH-USD`
- `EXTENDED_READ_ONLY_ENABLED=false`
- `EXTENDED_LIVE_ENABLED=false`
- `EXTENDED_AUTO_REBALANCE_ENABLED=false`
- `EXTENDED_REQUIRED_LEVERAGE=1`
- `EXTENDED_REQUIRED_MARGIN_MODE=isolated`
- `EXTENDED_ISOLATED_ACCOUNT_CONFIRMED=false`
- `EXTENDED_TESTNET_LIVE_ENABLED=false`
- `EXTENDED_LIVE_CONFIRMATION`

## Phased Implementation Plan

### Phase 0 - Documentation Only

- Keep this document as the initial design record.
- Do not add code that can sign or trade.
- Do not add credentials.
- Operator action: verify account model in Extended UI/API with a deleted test
  key replaced by a fresh read-only/test key only when ready.

### Phase 1 - Read-Only Scaffold

- Add `HedgeVenues::Extended` and `HedgeBackends::ExtendedReadOnlyProbe`.
- Extended appears in UI only when `EXTENDED_ENABLED=true`.
- Missing API key/account/vault/market config shows clear blockers.
- Fetch:
  - `GET /info/markets?market=ETH-USD`
  - `GET /user/account/info`
  - `GET /user/balance`
  - `GET /user/positions?market=ETH-USD`
  - `GET /user/orders?market=ETH-USD`
- Normalize current ETH short.
- Add tests with mocked HTTP only.
- No signing, no order building, no submits.

### Phase 2 - Dry-Run Order Payload

- Build intended normalized order summaries:
  - open/increase short: `SELL`, `reduceOnly=false`;
  - decrease/close short: `BUY`, `reduceOnly=true`.
- Use read-only market metadata for tick/lot/min size and fee endpoint for taker
  fee.
- Include explicit price/worst-price preview from orderbook.
- Do not compute Stark signatures in Rails.
- Do not call `POST /user/order`.

### Phase 3 - Testnet Proof

- Use testnet endpoint only.
- Use separate testnet API key and Stark key file.
- Use explicit gate such as `EXTENDED_TESTNET_LIVE_ENABLED=true`.
- Require exact typed confirmation.
- Prove:
  - open tiny ETH short;
  - delta decrease reduce-only;
  - delta increase;
  - full close;
  - readback after delayed confirmation;
  - account WebSocket order updates.
- Store receipts under a testnet-specific path.

### Phase 4 - Mainnet Live

- Only after testnet proof.
- Add mainnet live gate `EXTENDED_LIVE_ENABLED=true`.
- Add dashboard selected venue and migration preview.
- Manual lifecycle first: open, increase, decrease, close.
- Auto-rebalance remains disabled until manual lifecycle and pending
  reconciliation are proven.
- Implement `ExtendedPendingRebalanceReconciler` before auto.

## Safe Defaults

- Extended disabled by default.
- Extended live disabled by default.
- Extended auto disabled by default.
- Missing API key, vault, market, or signer support fails closed.
- No secrets in logs, UI, receipts, or database.
- Read-only account data may still be operationally sensitive; redact API key
  and Stark private key always.
- Do not use the deleted API key from the manual UI experiment.
- Do not store a Stark private key in `.env`, Rails credentials, logs, DB, or UI.

## Risks and Blockers

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Stark signing mismatch | Order rejected or worse, wrong order signed | Use SDK sidecar first; testnet proof before mainnet |
| REST accepted but engine rejects | False success and incorrect hedge state | Require WebSocket/account readback confirmation |
| Price crossing too aggressive | Bad fills | Explicit slippage cap and worst-price receipt |
| Wrong ETH market symbol | No-op or wrong market | Verify via `GET /info/markets` before any order plan |
| Leverage/margin semantics unclear | Unexpected liquidation/margin | Read leverage/balance first; do not call `PATCH /user/leverage` until separately designed |
| API key deletion/regeneration | Readback outage | Preflight checks and clear dashboard blockers |
| Stark key leakage | Funds/trading compromise | Dedicated signer sidecar, key file outside repo, redaction tests |
| Duplicate order during delayed confirmation | Over-hedge | Open-order readback and pending reconciliation before any auto |

## Optional No-Live Scaffold Recommendation

Phase 1 scaffold was added after the initial research pass. It is intentionally
fail-closed and cannot trade:

- `HedgeVenues::Extended` is available as a future venue option.
- `ExtendedHedgeExecutionService` only returns blocked results.
- Missing API key/account/vault/client/Stark public key config produces
  dashboard blockers.
- No `POST`, signing, Stark key loading, order submit, order cancel, or live
  auto-rebalance code exists.
- `HedgeSyncJob` explicitly skips Extended hedges so they cannot fall through to
  Hyperliquid execution.
- Nado and Ethereal behavior remains unchanged.

## Phase 1 Runbook

### How to verify Extended is safely disabled

1. Open `/positions/:id?hedge_venue=extended`.
2. Confirm the selected venue panel says:
   - `Extended mainnet order submit is implemented behind explicit live gates`
   - `Live disabled`
   - `Dry-runs do not sign or submit orders`
3. Confirm live buttons are disabled and preflight blockers include missing
   Extended config when no Extended env is present.
4. Run `bin/rails ethereal:hedge_payload_check` to verify the existing Ethereal
   no-live check remains unaffected.

### Credentials needed later

Future read-only Phase 1.5/2 work will need non-committed, non-logged config:

- `EXTENDED_API_BASE_URL`
- `EXTENDED_STREAM_URL`
- `EXTENDED_API_KEY`
- `EXTENDED_ACCOUNT_ID`
- `EXTENDED_VAULT_NUMBER`
- `EXTENDED_CLIENT_ID`
- `EXTENDED_STARK_PUBLIC_KEY`
- `EXTENDED_NETWORK`
- `EXTENDED_MARKET_SYMBOL`

Future Phase 3+ live work additionally needs:

- `EXTENDED_STARK_PRIVATE_KEY_FILE`
- explicit testnet/live gates and operator confirmation

### Why a Stark signer sidecar is required for Phase 3+

Extended order authorization uses Stark order hashes and Stark signatures. The
existing `delta-neutral-eip712-signer` signs EIP-712 typed data for Nado and
Ethereal and should not be extended to hold Stark trading keys. A separate Stark
sidecar keeps the key boundary explicit, lets the implementation reuse the
official Python SDK hashing/signing semantics, and avoids storing Stark private
keys in Rails.

## Phase 2 Dry-Run Order Intent Scaffold

Phase 2 originally added Extended order intent previews only. The current
implementation has since added controlled manual `open_only`/`close_only`
mainnet probes; this section documents the dry-run intent shape that is still
used before any live probe. It still cannot auto-rebalance Extended orders.

The scaffold now builds normalized intent summaries for operator review:

- `open_short`: `SELL`, `reduceOnly: false`
- `increase_short`: `SELL`, `reduceOnly: false`
- `decrease_short`: `BUY`, `reduceOnly: true`
- `close_short`: `BUY`, `reduceOnly: true`

This follows the docs/SDK side mapping described above: selling ETH-USD
perpetuals opens or increases a short; buying decreases or closes an existing
short. Decrease and close intents are always marked reduce-only.

The preview intentionally marks live-required fields as `required_later`:

- explicit worst accepted crossing price;
- IOC/market-like order construction;
- expiration;
- fee;
- Stark settlement signature;
- final submit body.

Market metadata is required before the preview can show rounded order size. The
operator can provide manual overrides, but Rails now first attempts to discover
the values from the read-only Extended market metadata response:

- `EXTENDED_MARKET_SYMBOL`
- `EXTENDED_SIZE_INCREMENT` override, otherwise `tradingConfig.minOrderSizeChange`
- `EXTENDED_PRICE_INCREMENT` override, otherwise `tradingConfig.minPriceChange`

The same response is used for optional diagnostics:

- `tradingConfig.minOrderSize` -> minimum order size
- `tradingConfig.minOrderValue` / `minNotional` variants -> minimum notional
- `marketStats.markPrice` -> read-only mark price

If that metadata is absent, the preview shows `rounded_size_eth: "unknown"` and
adds clear blockers. This avoids pretending a future order is submit-ready.
When metadata includes `tradingConfig.minOrderSize` or a min-notional field,
the dry-run preview validates the requested/rounded size against those limits.
Dry-run still prints the preview, but below-min orders carry blockers such as
`requested size 0.005 is below Extended min order size 0.01`; live mode inherits
the same blocker before any signer or submit path can run. The lifecycle task
defaults `size_eth` to `0.01`; operators must pass `size_eth` at or above the
discovered `min_size` and should not rely on implicit rounding up.

### What still blocks automatic production use

- `Extended live disabled.`
- `Extended auto-rebalance disabled.`
- Missing API/account/vault/client/Stark public key config.
- Missing market metadata.
- Missing or unhealthy Stark signer sidecar.
- `signing_enabled=false`.
- Open orders present.
- Missing exact operator confirmation for manual live probes.
- No WebSocket/account stream confirmation loop.

The payload includes `submit_endpoint: "POST /user/order"` because manual submit
is implemented for gated lifecycle probes. Dry-run still keeps
`order_submission: false`, `orders_placed: 0`, `signatures_created: 0`, and
`submitted: false`.

## Minimal Mainnet Foundation

The implementation now follows a mainnet-first, fail-closed path. There is no
mandatory testnet phase, but live Extended trading remains disabled until an
operator provides credentials, explicitly enables probe gates, and the Stark
signing algorithm is verified against the official SDK.

### Implemented

- `ExtendedApiClient` performs read-only REST calls with `X-Api-Key`.
- `HedgeVenues::Extended` can read account info, balance, positions, open
  orders, and ETH market metadata when env config is present.
- Balance/equity uses `GET /api/v1/user/balance`. Extended docs state this
  endpoint returns 404 when the user's balance is zero, so Rails classifies a
  balance 404 as `unsupported`/zero-balance in diagnostics rather than as a
  fatal read-only account error. Successful balance responses are parsed from
  `data.equity` and `data.balance`.
- Extended position readback normalizes to the same dashboard shape used by
  other venues: `side`, `short_size`, `size`, `entry_price`, `mark_price`,
  `notional_usd`, `unrealized_pnl_usd`, `account_value_usd`,
  `collateral_usd`, `effective_leverage`, and `margin_mode`.
- Dry-run order intent summaries now include future signing fields:
  `client_id`, `vault_number`, `account_id`, redacted Stark public key, nonce,
  price, crossing price, expiration, fee, IOC assumption, and a blocked external
  signer request summary.
- `scripts/extended_stark_signer.py` is a separate sidecar skeleton. It exposes
  `/health` and `/sign/extended_order`. Signing stays opt-in behind
  `EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM=true`; the systemd template keeps
  it false.
- `bin/rails extended:mainnet_lifecycle_check` builds manual mainnet lifecycle
  dry-run receipts for `open_only`, `close_only`, `delta_round_trip`, and
  `close_reopen`.
- Gated live `open_only` and `close_only` probes are implemented. Both require
  readback confirmation before reporting success.
- Receipts are appended to
  `storage/extended_mainnet_live_checks/YYYYMMDD.jsonl` and redact Stark
  signatures/API secrets.

### Still Blocked

- No Extended auto-rebalance.
- No Rails-side Stark signature creation.
- No Stark private key in Rails.
- No live order can run without the explicit probe gates, exact confirmation,
  healthy signer, and clean read-only account state.
- No close/reopen or delta round-trip live submit is enabled yet.

### Required Mainnet Read-Only Env

These values are read from operator-provided environment only. Do not commit
real values:

- `EXTENDED_API_BASE_URL=https://api.starknet.extended.exchange/api/v1`
- `EXTENDED_API_KEY`
- `EXTENDED_ACCOUNT_ID`
- `EXTENDED_VAULT_NUMBER`
- `EXTENDED_CLIENT_ID`
- `EXTENDED_STARK_PUBLIC_KEY`
- `EXTENDED_MARKET_SYMBOL=ETH-USD`
- `EXTENDED_SIZE_INCREMENT` optional override when the API does not return
  `tradingConfig.minOrderSizeChange`
- `EXTENDED_PRICE_INCREMENT` optional override when the API does not return
  `tradingConfig.minPriceChange`

### Required Live Probe Env

These are required for the controlled manual mainnet probes:

- `EXTENDED_MAINNET_PROBE_ENABLED=true`
- `EXTENDED_LIVE_ENABLED=true`
- `EXTENDED_SET_LEVERAGE_ENABLED=false` by default. Set true only for the
  manual `extended:set_leverage` workflow.
- `EXTENDED_SIGNER_URL=http://172.18.0.1:8776`
- `EXTENDED_AUTO_REBALANCE_ENABLED=false`
- `EXTENDED_REQUIRED_LEVERAGE=1`
- `EXTENDED_REQUIRED_MARGIN_MODE=isolated`
- `EXTENDED_ISOLATED_ACCOUNT_CONFIRMED=true` only after the operator has
  verified the account/subaccount is dedicated and isolated-equivalent for this
  hedge.
- `EXTENDED_PROBE_MAX_SIZE_ETH=0.01` or another explicit cap at or above the
  discovered Extended minimum order size.
- exact confirmation:
  `I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS`

### Stark Signer Key File Model

Extended must use a separate signer from the existing EIP-712 signer:

- Template: `docs/templates/delta-neutral-extended-signer.service`
- Script: `scripts/extended_stark_signer.py`
- Key file env: `EXTENDED_STARK_PRIVATE_KEY_FILE`
- Algorithm env: `EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM=false` by default
- Key file should be outside the repo, root-owned, and `0600`.

The sidecar `/health` reports `ok`, `signer_id`, `supported_exchanges`,
`supported_actions`, redacted `stark_public_key`, `verified_algorithm`, and
`signing_enabled`. It advertises Extended support only when:

- `EXTENDED_SIGNER_ENABLED=true`
- `EXTENDED_STARK_PRIVATE_KEY_FILE` exists
- `fast-stark-crypto` is installed
- `EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM=true`

Rails live probes remain blocked by their own gates unless the signer reports
`ok=true`, `verified_algorithm=true`, `signing_enabled=true`,
`supported_exchanges=["Extended"]`, and
`supported_actions=["sign_extended_order"]`.

Rails also blocks before signer/sign/submit unless the margin gate passes:

- `GET /user/leverage?market=ETH-USD` returns `leverage=1`.
- Required margin mode is `isolated`.
- Because the current Extended API/docs do not expose a Nado-style isolated
  position mode, `EXTENDED_ISOLATED_ACCOUNT_CONFIRMED=true` is required as an
  operator assertion that the configured Extended account is
  isolated-equivalent/dedicated for this hedge.
- If a current position exists and effective leverage is materially above 1x,
  Rails blocks even when the operator flag is set.
- If current leverage is not 1, run
  `bin/rails extended:set_leverage dry_run=true` first and review the intended
  `PATCH /user/leverage` payload. Do not rely on order submit to auto-change
  leverage.

### Mainnet Lifecycle Proof

Manual Extended mainnet lifecycle probes have been proven with the current
implementation:

| Probe | Size | Side | reduceOnly | Result |
| --- | ---: | --- | --- | --- |
| `open_only` | `0.01 ETH` | `SELL` | `false` | Submitted, filled, and confirmed by Extended readback as a short |
| `close_only` | full current short, `0.01 ETH` | `BUY` | `true` | Submitted, filled, and confirmed by Extended readback as flat |

`delta_round_trip` is implemented but not yet production-proven live. It is the
next controlled proof path and must be run only after a dry-run review:

1. Start flat with `open_orders_count=0`.
2. Open `0.02 ETH` short with `SELL reduceOnly=false`.
3. Confirm readback short is approximately `0.02 ETH`.
4. Decrease `0.01 ETH` with `BUY reduceOnly=true`.
5. Confirm readback short is approximately `0.01 ETH`.
6. Increase `0.01 ETH` with `SELL reduceOnly=false`.
7. Confirm readback short is approximately `0.02 ETH`.
8. Close full `0.02 ETH` short with `BUY reduceOnly=true`.
9. Confirm readback is flat/no position.

Every leg requires signer health, creates at most one signature and one submit,
requires readback confirmation before the next leg, and stops immediately if a
leg is not confirmed. It never retries or duplicates orders automatically.

Final state after the proof:

- Extended readback is flat/no position.
- Ethereal production hedge remained open and unchanged.
- Nado remained flat.
- Extended auto-rebalance remains disabled.
- Receipts are in `storage/extended_mainnet_live_checks/YYYYMMDD.jsonl`.

Success criteria used by the lifecycle task:

- REST submit acceptance alone is not success.
- `open_only` success requires later readback showing the expected short size.
- `close_only` success requires later readback showing no position or
  `short_size <= 0.001`.
- If submit is accepted but readback does not confirm, status remains
  `submitted_but_readback_pending`.

Exact live gates used for the successful probes:

- `EXTENDED_MAINNET_PROBE_ENABLED=true`
- `EXTENDED_LIVE_ENABLED=true`
- `EXTENDED_AUTO_REBALANCE_ENABLED=false`
- `EXTENDED_SIGNER_URL` points to the Extended Stark signer sidecar.
- `GET /user/leverage?market=ETH-USD` reports `1`.
- `EXTENDED_REQUIRED_LEVERAGE=1`.
- `EXTENDED_REQUIRED_MARGIN_MODE=isolated`.
- `EXTENDED_ISOLATED_ACCOUNT_CONFIRMED=true` after operator verification.
- Signer `/health` reports `ok=true`, `verified_algorithm=true`,
  `signing_enabled=true`, `supported_exchanges=["Extended"]`, and
  `supported_actions=["sign_extended_order"]`.
- Exact confirmation:
  `I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS`
- `open_only` additionally requires no current Extended position, visible
  account balance, valid market min size/notional, and `open_orders_count=0`.
- `close_only` requires a current Extended short and `open_orders_count=0`.
- `delta_round_trip` requires a flat starting state, visible account balance,
  valid market min size/notional, and `open_orders_count=0` before each leg.

### Stark Signing Verification

The signer algorithm is tested against the official `x10xchange/python_sdk`
market-order vector from commit `b7e7c64`:

- SDK file: `tests/perpetual/order_object/test_market_order_object.py`
- SDK implementation files:
  - `x10/perpetual/order_object.py`
  - `x10/perpetual/order_object_settlement.py`
  - `x10/core/stark_account.py`

The deterministic vector uses dummy SDK keys only:

- market: `BTC-USD`
- side: `SELL`
- qty: `0.00100000`
- price: `49625.0`
- nonce: `1473459052`
- vault: `10002`
- domain: `Perpetuals/v0/SN_SEPOLIA/revision 1`

Expected SDK values:

- order id/hash:
  `2580220688642480426946040763258220762106230673118492731878319591751617419967`
- signature `r`:
  `0x28af719b8c9619fadd151a0f9c269058b3240ae2e08ab14e6fa15b8ea081dc6`
- signature `s`:
  `0x78c518768fe71c8583aee78e756de66ffed2170171fec10da03edc5e9a3d241`
- debugging amounts:
  `collateralAmount=49625000`, `feeAmount=24813`,
  `syntheticAmount=-1000`

No real API key or Stark key is used by this test.

### Operator Checklist

1. Keep production hedge venue on Ethereal.
2. Add read-only Extended env values outside the repo.
3. Open `/positions/:id?hedge_venue=extended` and verify normalized readback.
4. Run:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=open_only`
5. Confirm receipts show `orders_placed: 0` and `signatures_created: 0`.
6. Confirm signer health before any live probe:
   `curl -s http://172.18.0.1:8776/health`
7. Dry-run open:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=open_only size_eth=0.01`
8. Live open, only for a controlled probe:
   `EXTENDED_MAINNET_PROBE_ENABLED=true EXTENDED_LIVE_ENABLED=true EXTENDED_AUTO_REBALANCE_ENABLED=false bin/rails extended:mainnet_lifecycle_check dry_run=false mode=open_only size_eth=0.01 confirmation=I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS`
9. Dry-run close:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=close_only`
10. Live close, only to flatten the controlled probe:
   `EXTENDED_MAINNET_PROBE_ENABLED=true EXTENDED_LIVE_ENABLED=true EXTENDED_AUTO_REBALANCE_ENABLED=false bin/rails extended:mainnet_lifecycle_check dry_run=false mode=close_only confirmation=I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS`
11. Dry-run delta round-trip:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=delta_round_trip size_eth=0.01`
   This should show four planned legs: open `0.02`, decrease `0.01`,
   increase `0.01`, close `0.02`, with `orders_placed: 0` and
   `signatures_created: 0`.
12. Live delta round-trip, only for a controlled proof after dry-run review:
   `EXTENDED_MAINNET_PROBE_ENABLED=true EXTENDED_LIVE_ENABLED=true EXTENDED_AUTO_REBALANCE_ENABLED=false bin/rails extended:mainnet_lifecycle_check dry_run=false mode=delta_round_trip size_eth=0.01 confirmation=I_UNDERSTAND_THIS_SUBMITS_LIVE_EXTENDED_MAINNET_ORDERS`
13. Final flat readback:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=close_only`
   should show `current_position_status: no_position` and a
   `close_only probe requires current Extended short position` blocker because
   there is no longer a short to close.

### Controlled Leverage Update

Use this only while Extended is flat and has no open orders. It never signs and
never places orders.

Dry-run:

```bash
bin/rails extended:set_leverage dry_run=true market=ETH-USD leverage=1
```

Live, only after reviewing the dry-run payload:

```bash
EXTENDED_SET_LEVERAGE_ENABLED=true bin/rails extended:set_leverage dry_run=false market=ETH-USD leverage=1 confirmation=I_UNDERSTAND_THIS_UPDATES_EXTENDED_LEVERAGE
```

The task:

- reads current leverage with `GET /user/leverage?market=...`;
- builds the intended `PATCH /user/leverage` payload;
- refuses live mode unless `EXTENDED_SET_LEVERAGE_ENABLED=true` and the exact
  confirmation is provided;
- refuses live mode if an Extended position exists;
- refuses live mode if `open_orders_count` is not zero;
- reads leverage again after PATCH;
- reports success only when readback equals the target leverage;
- writes redacted JSONL receipts under `storage/extended_leverage_checks/`.

### Signer Operations

The Extended Stark signer is a separate sidecar from Rails and from the
EIP-712 signer. The Stark private key must stay outside Rails and outside this
repo.

One-time host setup:

```bash
sudo install -d -m 700 -o root -g root /etc/delta-neutral/keys
sudo install -m 600 -o root -g root /dev/null /etc/delta-neutral/keys/extended-stark.key
sudoedit /etc/delta-neutral/keys/extended-stark.key
sudo cp /opt/delta_neutral/docs/templates/delta-neutral-extended-signer.service /etc/systemd/system/delta-neutral-extended-signer.service
sudo systemctl daemon-reload
```

The service template defaults to:

- `EXTENDED_SIGNER_HOST=172.18.0.1`
- `EXTENDED_SIGNER_PORT=8776`
- `EXTENDED_STARK_PRIVATE_KEY_FILE=/etc/delta-neutral/keys/extended-stark.key`
- `EXTENDED_SIGNER_ENABLED=false`
- `EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM=false`

Safe start after reviewing the key path and public key:

```bash
sudo systemctl start delta-neutral-extended-signer
sudo systemctl status delta-neutral-extended-signer --no-pager
curl -s http://172.18.0.1:8776/health
```

For a permanent signer service, keep the private key in
`/etc/delta-neutral/keys/extended-stark.key` with `root:root` ownership and
`0600` permissions. Use a systemd drop-in or reviewed environment file outside
the repo to opt in the signer:

```bash
sudo systemctl edit delta-neutral-extended-signer
```

Example non-secret drop-in values:

```ini
[Service]
Environment=EXTENDED_SIGNER_ENABLED=true
Environment=EXTENDED_SIGNER_ENABLE_VERIFIED_ALGORITHM=true
Environment=EXTENDED_SIGNER_HOST=172.18.0.1
Environment=EXTENDED_SIGNER_PORT=8776
Environment=EXTENDED_STARK_PRIVATE_KEY_FILE=/etc/delta-neutral/keys/extended-stark.key
Environment=EXTENDED_STARK_PUBLIC_KEY=0x...
```

Then reload and start:

```bash
sudo systemctl daemon-reload
sudo systemctl enable delta-neutral-extended-signer
sudo systemctl restart delta-neutral-extended-signer
curl -s http://172.18.0.1:8776/health
```

For live probes, `/health` must show `ok=true`, `verified_algorithm=true`,
`signing_enabled=true`, `supported_exchanges=["Extended"]`, and
`supported_actions=["sign_extended_order"]`. If it shows
`signing_enabled=false`, Rails must block before signing or submit.

Safe stop:

```bash
sudo systemctl stop delta-neutral-extended-signer
curl -s http://172.18.0.1:8776/health
```

After stop, Rails Extended live preflight should show the signer as unreachable
or unhealthy. Existing Ethereal/Nado behavior is independent.

### Rollback

Rollback is readback-first and avoids any automatic retry:

1. Stop the Extended signer:
   `sudo systemctl stop delta-neutral-extended-signer`
2. Ensure `EXTENDED_LIVE_ENABLED=false` and
   `EXTENDED_AUTO_REBALANCE_ENABLED=false` outside the repo.
3. Select Ethereal or Nado in the dashboard; do not switch the production hedge
   venue automatically.
4. If a probe left an Extended short open, use only the gated `close_only`
   lifecycle after a dry-run confirms the current short and `open_orders_count=0`.
5. Confirm final flat state with:
   `bin/rails extended:mainnet_lifecycle_check dry_run=true mode=close_only`

`HedgeSyncJob` still skips Extended auto-rebalance, and the lifecycle task does
not mutate hedge target state.

### Stepwise Ethereal to Extended Migration

The migration flow is intentionally stepwise and readback-gated. It does not
switch `hedge.execution_venue`; finalization is a separate task after readback
shows Ethereal flat and Extended near target.

Before any live migration step:

1. Disable Ethereal auto-rebalance outside the repo:
   `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=false`.
2. Keep Extended continuous auto disabled:
   `EXTENDED_AUTO_REBALANCE_ENABLED=false`.
3. Confirm Nado is flat.
4. Confirm Extended leverage/margin gate passes at 1x isolated-equivalent.
5. Confirm the Extended signer is running and healthy.

Dry-run one migration step:

```bash
bin/rails extended:migration_step dry_run=true position_id=3 step_size_eth=0.01
```

Live migration step requires:

```bash
EXTENDED_MIGRATION_STEP_ENABLED=true \
EXTENDED_LIVE_ENABLED=true \
AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true \
bin/rails extended:migration_step dry_run=false position_id=3 step_size_eth=0.01 confirmation=I_UNDERSTAND_THIS_MIGRATES_HEDGE_FROM_ETHEREAL_TO_EXTENDED
```

The step submits Extended first (`SELL`, `reduceOnly=false`) and submits the
Ethereal reduce-only leg (`BUY`, `reduceOnly=true`) only after Extended readback
confirms. If either readback is not confirmed, the task stops and requires
manual review. It never retries or duplicates orders.

### Fast Full Ethereal to Extended Migration

The fast migration path moves the whole planned short exposure in one
readback-gated operation. It is still manual-only and does not switch
`hedge.execution_venue`; finalization remains a separate command.

Before a live full migration:

1. Disable Ethereal auto-rebalance outside the repo:
   `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=false`.
2. Keep Extended continuous auto disabled:
   `EXTENDED_AUTO_REBALANCE_ENABLED=false`.
3. Confirm Nado is flat.
4. Confirm Extended leverage is 1x and isolated-equivalent is confirmed.
5. Confirm Extended signer health reports `ok=true`,
   `verified_algorithm=true`, `signing_enabled=true`, and supports
   `sign_extended_order`.

Dry-run the full migration:

```bash
bin/rails extended:migration_full dry_run=true position_id=3
```

Live full migration requires:

```bash
EXTENDED_MIGRATION_FULL_ENABLED=true \
EXTENDED_LIVE_ENABLED=true \
AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=false \
AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true \
bin/rails extended:migration_full dry_run=false position_id=3 confirmation=I_UNDERSTAND_THIS_FULLY_MIGRATES_HEDGE_FROM_ETHEREAL_TO_EXTENDED
```

Default sequence is `extended_first`:

1. Submit Extended `SELL`, `reduceOnly=false` for the additional size needed
   to bring Extended to the current target short.
2. Confirm Extended readback near the target.
3. Submit Ethereal `BUY`, `reduceOnly=true` for the full current Ethereal
   short.
4. Confirm Ethereal flat.
5. Read both venues and verify combined hedge remains near target.

The Extended-first sequence intentionally bounds risk toward temporary
overhedge rather than temporary underhedge. If Extended confirms but Ethereal
does not confirm, the receipt is marked
`partial_migration_manual_action_required` and no retry is attempted. If
Extended does not confirm, the Ethereal leg is not submitted. Receipts are
written to `storage/extended_migration_checks/YYYYMMDD.jsonl` with signatures,
API keys, auth headers, cookies, private keys, and secret env values redacted.

After all exposure has moved and readback shows Extended near target, Ethereal
flat, Nado flat, and no Extended open orders, dry-run finalization:

```bash
bin/rails extended:migration_finalize dry_run=true position_id=3
```

Live finalization requires:

```bash
EXTENDED_MIGRATION_FINALIZE_ENABLED=true \
bin/rails extended:migration_finalize dry_run=false position_id=3 confirmation=I_UNDERSTAND_THIS_SWITCHES_PRODUCTION_HEDGE_TO_EXTENDED
```

After finalization, choose which venue auto should run and enable only that
venue's auto gate. Do not leave Ethereal auto enabled during migration, because
it can fight the stepwise transfer by restoring Ethereal to the full target.

### Extended Continuous Auto Readiness

After full migration and `extended:migration_finalize`, continuous Extended auto
is still disabled until the operator enables `EXTENDED_AUTO_REBALANCE_ENABLED`
outside the repo. Use the read-only readiness task before changing that gate:

```bash
bin/rails extended:auto_readiness position_id=3
```

The readiness task never signs or submits. It reports:

- `execution_venue`
- Extended current short, target short, drift, and tolerance
- Ethereal flat status
- Nado flat status
- Extended leverage/margin gate
- signer health
- `open_orders_count`
- `EXTENDED_AUTO_REBALANCE_ENABLED`
- `EXTENDED_LIVE_ENABLED`
- `continuous_auto_ready`

Continuous Extended auto is allowed only when all of these are true:

- `hedge.execution_venue == "extended"`
- Ethereal is flat
- Nado is flat
- `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=false`
- `EXTENDED_AUTO_REBALANCE_ENABLED=true`
- `EXTENDED_LIVE_ENABLED=true`
- signer health is ok, verified, signing-enabled, and supports
  `Extended/sign_extended_order`
- Extended leverage/margin gate passes
- account balance/collateral and market metadata are visible
- `open_orders_count=0`
