# Ethereal OpenAPI Endpoint Map

Date checked: 2026-05-12

This map is for read-only adapter research only. It does not approve live trading, order placement, close logic, signing, or production wiring. Production remains Hyperliquid-only.

## Official Sources Checked

- Ethereal docs home: https://docs.ethereal.trade/
- API hosts: https://docs.ethereal.trade/protocol-reference/api-hosts
- Trading API quick start: https://docs.ethereal.trade/developer-guides/trading-api/quick-start
- Products: https://docs.ethereal.trade/developer-guides/trading-api/products
- Accounts and signers: https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers
- Message signing: https://docs.ethereal.trade/developer-guides/trading-api/message-signing
- Order placement: https://docs.ethereal.trade/developer-guides/trading-api/order-placement
- System limits: https://docs.ethereal.trade/developer-guides/trading-api/system-limits
- Websockets: https://docs.ethereal.trade/developer-guides/trading-api/websockets
- Python SDK: https://docs.ethereal.trade/developer-guides/sdk/python-sdk
- Mainnet OpenAPI: https://api.ethereal.trade/openapi.json
- Testnet OpenAPI: https://api.etherealtest.net/openapi.json
- Mainnet Swagger UI: https://api.ethereal.trade/docs
- Testnet Swagger UI: https://api.etherealtest.net/docs

## Category A - Safe Public/Read-Only Candidates

| Endpoint | Source | Auth requirement | Mutates state | Safe for probe | HedgeBackend fields | Missing fields | Readiness |
|---|---|---:|---:|---:|---|---|---|
| `GET /v1/product` | OpenAPI + products docs | Not proven required | No | Yes | product id, ticker/display ticker, status, min quantity, lot size, tick size, max leverage, quote/collateral token | min notional | ready_for_probe |
| `GET /v1/product/{id}` | OpenAPI | Not proven required | No | Candidate | single product metadata | min notional | ready_for_probe |
| `GET /v1/product/market-price` | OpenAPI + products docs | Not proven required | No | Yes | oracle price, best bid, best ask | explicit mark/index naming beyond oracle/bid/ask | ready_for_probe |
| `GET /v1/product/market-liquidity` | OpenAPI | Not proven required | No | Not currently used | liquidity context | adapter need unclear | unknown |
| `GET /v1/funding`, `GET /v1/funding/projected`, `GET /v1/funding/projected-rate` | OpenAPI | Not proven required | No | Not currently used | funding context | not needed for first hedge readback | unknown |
| `GET /v1/rate-limit/config` | OpenAPI + system limits docs | Not proven required | No | Candidate | rate-limit config | account-specific limits unclear | ready_for_probe |
| `GET /v1/rpc/config` | OpenAPI + message signing docs | Not proven required | No | Reference only | EIP-712 domain data | not used because probe does not sign | ready_for_probe |
| `GET /v1/time`, `GET /v1/maintenance` | OpenAPI | Not proven required | No | Candidate | clock/maintenance status | not needed for hedge contract | ready_for_probe |

## Category B - Private Read-Only Candidates

| Endpoint | Source | Auth requirement | Mutates state | Safe for probe | HedgeBackend fields | Missing fields | Readiness |
|---|---|---:|---:|---:|---|---|---|
| `GET /v1/subaccount`, `GET /v1/subaccount/all`, `GET /v1/subaccount/{id}` | OpenAPI + accounts/signers docs | Account/sender or id required; auth model not fully proven for production | No by method | Candidate after auth design | account/subaccount identity | safe read-only auth model | needs_auth_design |
| `GET /v1/subaccount/balance` | OpenAPI | subaccount id required | No by method | Yes only with explicit subaccount id | collateral, account value approximation, available/used balance | full margin health semantics | needs_auth_design |
| `GET /v1/position`, `GET /v1/position/active`, `GET /v1/position/{id}` | OpenAPI | subaccount/product/id required | No by method | Yes only with explicit subaccount id | signed size via side+size, unrealized PnL, cost, liquidation price | zero-position semantics and entry price | needs_auth_design |
| `GET /v1/position/fill`, `GET /v1/position/liquidation` | OpenAPI | subaccount/id parameters | No by method | Not currently used | fills/liquidation history | realized PnL mapping, lifecycle semantics | needs_auth_design |
| `GET /v1/order`, `GET /v1/order/{id}`, `GET /v1/order/{id}/group`, `GET /v1/order/fill`, `GET /v1/order/trade` | OpenAPI | subaccount/order parameters | No by method | Not currently used | order status, fills, reduce-only flag, filled quantity | final reconciliation semantics | needs_auth_design |
| `GET /v1/linked-signer*`, `GET /v1/linked-signer/quota` | OpenAPI + accounts/signers docs | signer/account context | No by method | Do not call in probe | signer inventory/quota | not needed for read-only probe | needs_auth_design |
| `GET /v1/token`, `GET /v1/token/{id}`, `GET /v1/token/transfer`, `GET /v1/token/withdraw` | OpenAPI | token/account context unclear | No by method | Do not call in probe | token/balance history | mutation boundary around token surfaces | unknown |

## Category C - Dangerous/Execution Endpoints

| Endpoint | Source | Auth requirement | Mutates state | Safe for probe | HedgeBackend fields | Missing fields | Readiness |
|---|---|---:|---:|---:|---|---|---|
| `POST /v1/order` | OpenAPI + order placement docs | Signing/order auth required | Yes | No | order placement | live safety proof absent | dangerous_do_not_call |
| `POST /v1/order/cancel` | OpenAPI | Signing/order auth likely required | Yes | No | order cancel | cancel safety proof absent | dangerous_do_not_call |
| `POST /v1/order/dry-run` | OpenAPI | order payload/signing semantics unclear | Unknown/possible state-free but execution-like | No | order simulation | dry-run safety not proven | dangerous_do_not_call |
| `POST /v1/linked-signer/link`, `POST /v1/linked-signer/refresh`, `POST /v1/linked-signer/extend`, `DELETE /v1/linked-signer/revoke` | OpenAPI + accounts/signers docs | signer/account auth required | Yes | No | signer management | not part of read-only probe | dangerous_do_not_call |
| `POST /v1/token/{id}/withdraw` | OpenAPI | account auth likely required | Yes | No | withdrawal | not hedge readback | dangerous_do_not_call |
| `POST /v1/referral/claim`, `POST /v1/referral/activate` | OpenAPI | account auth likely required | Yes | No | none for hedge backend | not hedge readback | dangerous_do_not_call |
| `POST /v1/time` | OpenAPI | Unknown | Unknown | No | none | GET alternative exists | dangerous_do_not_call |

No leverage or margin mutation endpoint was identified in the checked OpenAPI path list. That does not prove leverage/margin behavior is unnecessary; it means the capability is unknown for adapter design.

## Category D - Unknown/Needs Proof

| Endpoint | Source | Auth requirement | Mutates state | Safe for probe | HedgeBackend fields | Missing fields | Readiness |
|---|---|---:|---:|---:|---|---|---|
| `GET /v1/whitelist` | OpenAPI | Unknown | No by method | Not currently used | none | semantics unclear | unknown |
| `GET /v1/points*` | OpenAPI | Unknown | No by method | Not currently used | none | rewards semantics irrelevant to hedge backend | unknown |
| `GET /v1/referral*` | OpenAPI | Unknown | No by method | Not currently used | none | referral semantics irrelevant to hedge backend | unknown |
| Websocket surfaces | Websocket docs | Unknown by channel | Unknown by channel | Not currently used | possible live market/order stream | subscription/auth behavior not integrated | unknown |

## Read-Only Probe Allowlist

The current read-only probe is limited to:

- `GET /v1/product`
- `GET /v1/product/market-price`
- `GET /v1/position/active`
- `GET /v1/subaccount/balance`

It does not call order, cancel, signer mutation, transfer, withdraw, leverage, execute, or trade endpoints.

## Guardrail Notes

- Real account ids and subaccount ids can be sensitive operational metadata even when no secret is present.
- Observation files must be sanitized before sharing or committing.
- The next allowed step is manual read-only observation. Sandbox order proof requires a separate explicit task, separate branch/review, and new safety gates.
