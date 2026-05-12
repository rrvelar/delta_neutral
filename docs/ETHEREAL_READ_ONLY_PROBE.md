# Ethereal Read-Only Probe

Date checked: 2026-05-12

## Safety Banner

ETHEREAL READ-ONLY PROBE - NO ORDERS

- READ ONLY
- NO ORDERS
- NO CLOSE
- NO HYPERLIQUID EXECUTION
- NO PRODUCTION WIRING

## Purpose

This probe is a backend-interface preparation step for evaluating Ethereal as a future hedge backend. It is not a live adapter. It does not place orders, close orders, sign messages, or connect to the current Aerodrome production runner.

Production remains Hyperliquid-only.

## What It Does

- Defines inert hedge backend value objects and typed errors.
- Reads Ethereal product metadata when `ETHEREAL_READ_ONLY_ENABLED=true`.
- Reads Ethereal market price data when the product id can be resolved.
- Reads Ethereal active position data only when `ETHEREAL_SUBACCOUNT_ID` is explicitly configured.
- Reads Ethereal subaccount balance data only when `ETHEREAL_SUBACCOUNT_ID` is explicitly configured.
- Returns structured `PASS`, `WARN`, or `BLOCKED` probe output.
- Can record sanitized local observations under `storage/hedge_backends/ethereal_observations/`.
- Can summarize a saved observation without network calls.

## What It Does Not Do

- No Ethereal live adapter.
- No Ethereal order placement.
- No Ethereal emergency close.
- No order signing.
- No private key support.
- No trading key support.
- No signing.
- No Hyperliquid execution.
- No production runner integration.
- No HedgeSyncJob integration.
- No scheduler, systemd service, UI live button, or unattended automation.

## Required Env

The probe is disabled by default.

```bash
ETHEREAL_READ_ONLY_ENABLED=false
ETHEREAL_API_BASE_URL=
ETHEREAL_WS_URL=
ETHEREAL_ACCOUNT_ID=
ETHEREAL_SUBACCOUNT_ID=
ETHEREAL_MARKET_SYMBOL=ETH-USD
```

`ETHEREAL_API_BASE_URL` must be an Ethereal API host such as the official mainnet or testnet REST API base. No private key, trading key, or signing key is supported.

## How To Run The Probe

Human output:

```bash
ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.ethereal.trade bin/rails hedge_backends:ethereal_probe
```

JSON output:

```bash
FORMAT=json ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.ethereal.trade bin/rails hedge_backends:ethereal_probe
```

If `ETHEREAL_READ_ONLY_ENABLED` is not `true`, the task returns `BLOCKED` without network calls.

## How To Record A Sanitized Observation

Use testnet first:

```bash
ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.etherealtest.net ETHEREAL_MARKET_SYMBOL=ETH-USD bin/rails hedge_backends:ethereal_probe_record
```

JSON task output:

```bash
FORMAT=json ETHEREAL_READ_ONLY_ENABLED=true ETHEREAL_API_BASE_URL=https://api.etherealtest.net ETHEREAL_MARKET_SYMBOL=ETH-USD bin/rails hedge_backends:ethereal_probe_record
```

The recorder writes sanitized JSON to:

```text
storage/hedge_backends/ethereal_observations/YYYYMMDDHHMMSS-<shortid>.json
```

If the probe result is `BLOCKED`, the record task does not write an observation by default. This avoids storing mostly-empty configuration failure files.

The recorder strips nested keys matching `private_key`, `secret`, `signature`, `password`, `token`, `api_key`, and `authorization` case-insensitively. It still should be treated as operator-local evidence. Do not commit an observation file if it contains real account identifiers, subaccount identifiers, balances, positions, or any other sensitive operational data.

## How To Summarize An Observation

Human output:

```bash
bin/rails hedge_backends:ethereal_observation_summary PATH=storage/hedge_backends/ethereal_observations/example.json
```

JSON output:

```bash
FORMAT=json bin/rails hedge_backends:ethereal_observation_summary PATH=storage/hedge_backends/ethereal_observations/example.json
```

The summary task performs no network calls and cannot place orders. It reports endpoint statuses, whether market metadata appears complete enough for adapter design, whether mark price/position/account health were proven, and what remains before sandbox order proof.

## Official Sources Checked

- Ethereal docs home: https://docs.ethereal.trade/
- API hosts: https://docs.ethereal.trade/protocol-reference/api-hosts
- Trading API quick start: https://docs.ethereal.trade/developer-guides/trading-api/quick-start
- Products and market prices: https://docs.ethereal.trade/developer-guides/trading-api/products
- Order placement: https://docs.ethereal.trade/developer-guides/trading-api/order-placement
- Accounts and signers: https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers
- Message signing: https://docs.ethereal.trade/developer-guides/trading-api/message-signing
- System limits: https://docs.ethereal.trade/developer-guides/trading-api/system-limits
- Websockets: https://docs.ethereal.trade/developer-guides/trading-api/websockets
- TradingView API: https://docs.ethereal.trade/developer-guides/trading-api/tradingview-api
- Python SDK docs: https://docs.ethereal.trade/developer-guides/sdk/python-sdk
- Mainnet OpenAPI schema: https://api.ethereal.trade/openapi.json
- Mainnet Swagger UI: https://api.ethereal.trade/docs
- Testnet OpenAPI schema: https://api.etherealtest.net/openapi.json
- Testnet Swagger UI: https://api.etherealtest.net/docs
- SDK/docs repository linked from docs: https://meridianxyz.github.io

## Verified Read-Only API Details

- `GET /v1/product` lists products and includes documented fields such as `id`, `ticker`, `displayTicker`, `baseTokenName`, `quoteTokenName`, `status`, `minQuantity`, `lotSize`, `tickSize`, and `maxLeverage`.
- `GET /v1/product/market-price` requires `productIds` and returns documented fields including `oraclePrice`, `bestBidPrice`, and `bestAskPrice`.
- `GET /v1/position/active` requires `subaccountId` and `productId`.
- Position side enum is documented as BUY `0` and SELL `1`; the probe maps SELL to a negative signed size for short readback.
- `GET /v1/subaccount/balance` requires `subaccountId` and returns `amount`, `available`, and `totalUsed`.
- `GET /v1/rpc/config` returns EIP-712 domain data for signing, but the probe does not call signing flows.
- Order endpoints exist, including order placement, dry-run, cancel, fills, and status, but the probe does not call order placement or cancellation endpoints.

## Unsupported Or Unknown

- `min_notional_usd` was not proven from checked official product metadata and remains `nil`.
- Safe read-only authentication semantics for private account access were not proven as a production adapter design.
- Reduce-only close behavior, final zero readback, fills/order lifecycle reconciliation, sandbox order behavior, and emergency close semantics are not implemented.
- Rate-limit policy details are documented at a high level, but no runner pacing is implemented because there is no live runner integration.
- Ethereal trading API uses accounts, subaccounts, signers, and EIP-712 signing according to official docs. This probe intentionally avoids trading and signing.

## Checklist Before Sandbox Order Proof

- Market metadata complete.
- Mark price proven.
- Position readback proven.
- Account health proven.
- Rate limits understood.
- Auth/read-only key model understood.
- Reduce-only close still not implemented.
- Final zero readback still not proven.

## Current Status

The implementation is a read-only probe plus generic inert value objects and error classes. It is suitable for mocked tests and manual read-only exploration only.

Live adapter work is prohibited until read-only proof, sandbox order proof, reduce-only close proof, fills/order-state proof, final zero readback proof, and an operator runbook exist.

Production remains Hyperliquid-only.
