# Ethereal Testnet Read-Only Runbook

Date checked: 2026-05-12

ETHEREAL TESTNET READ-ONLY OBSERVATION - NO ORDERS

## Purpose

This runbook describes how an operator/developer can manually run Ethereal read-only testnet observations and save sanitized response-shape evidence for future adapter design.

## Scope

- Read-only probe only.
- No order placement.
- No close.
- No reduce-only close.
- No signing or private key support.
- No production wiring.
- Production remains Hyperliquid-only.

This runbook does not authorize sandbox trading or live trading.

## Required Branch

Run only on:

```bash
ethereal-readonly-probe
```

## Required Local Preflight

```bash
git branch --show-current
git status --short
HOME=/private/tmp XDG_CACHE_HOME=/private/tmp bin/rake
git diff -- .env .env.production
```

Required state:

- Branch is `ethereal-readonly-probe`.
- `git status --short` is clean before starting observation work.
- `bin/rake` is green.
- No `.env` or `.env.production` changes.

## Required Env Variables

Use testnet:

```bash
ETHEREAL_READ_ONLY_ENABLED=true
ETHEREAL_API_BASE_URL=https://api.etherealtest.net
ETHEREAL_MARKET_SYMBOL=ETH-USD
ETHEREAL_ACCOUNT_ID=
ETHEREAL_SUBACCOUNT_ID=
```

`ETHEREAL_ACCOUNT_ID` and `ETHEREAL_SUBACCOUNT_ID` are optional. Without `ETHEREAL_SUBACCOUNT_ID`, private readback such as position and account health is expected to be `unsupported` or `unknown`.

Do not set private keys. Do not set signing keys. Do not set order-enabled variables. Do not fund or trade from this task.

## Human Probe

```bash
ETHEREAL_READ_ONLY_ENABLED=true \
ETHEREAL_API_BASE_URL=https://api.etherealtest.net \
ETHEREAL_MARKET_SYMBOL=ETH-USD \
bin/rails hedge_backends:ethereal_probe
```

## JSON Probe

```bash
FORMAT=json \
ETHEREAL_READ_ONLY_ENABLED=true \
ETHEREAL_API_BASE_URL=https://api.etherealtest.net \
ETHEREAL_MARKET_SYMBOL=ETH-USD \
bin/rails hedge_backends:ethereal_probe
```

## Record Observation

```bash
ETHEREAL_READ_ONLY_ENABLED=true \
ETHEREAL_API_BASE_URL=https://api.etherealtest.net \
ETHEREAL_MARKET_SYMBOL=ETH-USD \
bin/rails hedge_backends:ethereal_probe_record
```

With optional private readback identifiers:

```bash
ETHEREAL_READ_ONLY_ENABLED=true \
ETHEREAL_API_BASE_URL=https://api.etherealtest.net \
ETHEREAL_MARKET_SYMBOL=ETH-USD \
ETHEREAL_ACCOUNT_ID=<account-id-or-address> \
ETHEREAL_SUBACCOUNT_ID=<subaccount-id> \
bin/rails hedge_backends:ethereal_probe_record
```

## Summarize Observation

```bash
bin/rails hedge_backends:ethereal_observation_summary PATH=storage/hedge_backends/ethereal_observations/example.json
```

JSON:

```bash
FORMAT=json bin/rails hedge_backends:ethereal_observation_summary PATH=storage/hedge_backends/ethereal_observations/example.json
```

## Files Created

The recorder may create:

```text
storage/hedge_backends/ethereal_observations/*.json
```

These files are local operator evidence. They are not required for the app to run.

## Sanitization Expectations

The observation recorder strips nested keys that look like secrets, including private keys, signatures, passwords, API keys, authorization values, bearer values, cookies, and token-like fields.

Account ids and subaccount ids may still be sensitive operational metadata. Do not commit real observations unless they have been manually reviewed and sanitized.

## Expected Outcomes

- Market metadata: `ok` or `unknown`.
- Mark price: `ok` or `unknown`.
- Position readback: `unsupported` or `unknown` unless a read-only auth/subaccount model is proven.
- Account health: `unsupported` or `unknown` unless a read-only auth/subaccount model is proven.

`PASS` means the read-only probe found no warnings or blockers. `WARN` means some useful evidence exists but at least one field remains unsupported or unknown. `BLOCKED` means configuration or endpoint errors prevented useful observation.

## Evidence Enough For Next Phase

Minimum evidence before considering a separate sandbox order proof branch:

- Market metadata is complete.
- Mark price is proven.
- Position readback is proven, including zero/no-position behavior.
- Account health is proven.
- Rate limits are understood.
- Read-only auth model is understood.

## Still Missing Before Sandbox Order Proof

- Order placement is not implemented.
- Reduce-only close is not implemented.
- Final zero readback is not proven.
- Order status and fills are not proven.
- Partial-fill handling is not proven.
- Rejection handling is not proven.

## Still Missing Before Live Adapter

- Separate sandbox order proof.
- Reduce-only close proof.
- Final zero/nil readback proof.
- Operator runbook.
- Production safety gates.
- Explicit review that production remains Hyperliquid-only until a later approved task changes it.

## Official Sources Checked

- https://docs.ethereal.trade/
- https://docs.ethereal.trade/protocol-reference/api-hosts
- https://docs.ethereal.trade/protocol-reference/contracts
- https://docs.ethereal.trade/developer-guides/trading-api/quick-start
- https://docs.ethereal.trade/developer-guides/trading-api/products
- https://docs.ethereal.trade/developer-guides/trading-api/accounts-and-signers
- https://docs.ethereal.trade/developer-guides/trading-api/message-signing
- https://docs.ethereal.trade/developer-guides/trading-api/order-placement
- https://docs.ethereal.trade/developer-guides/trading-api/system-limits
- https://docs.ethereal.trade/developer-guides/trading-api/websockets
- https://docs.ethereal.trade/developer-guides/sdk/python-sdk
- https://api.ethereal.trade/openapi.json
- https://api.etherealtest.net/openapi.json
- https://api.ethereal.trade/docs
- https://api.etherealtest.net/docs
