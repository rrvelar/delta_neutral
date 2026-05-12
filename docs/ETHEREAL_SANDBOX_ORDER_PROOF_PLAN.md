# Ethereal Sandbox Order Proof Plan

Date checked: 2026-05-12

This is a future plan only. It does not implement sandbox orders.

NO ORDERS are implemented by this branch. NO CLOSE. NO SIGNING. NO PRODUCTION WIRING.

## Why This Is Separate

The current `ethereal-readonly-probe` branch is read-only. It has no order placement, close path, reduce-only close, signing/private-key support, or production wiring. Sandbox order proof requires new risk controls and must happen on a separate branch with explicit approval.

## Required Prerequisites

- Read-only observation completed.
- Market metadata complete.
- Mark price proven.
- Position readback proven, including zero/no-position behavior.
- Account health proven.
- Rate limits understood.
- Read-only auth model understood.

## Required Branch

Use a separate branch such as:

```bash
ethereal-sandbox-order-proof
```

## Explicit Safety

- Testnet/sandbox only.
- Tiny size only.
- Separate wallet only.
- No production runner wiring.
- No real production funds.
- No `.env.production` changes.
- No VPS automation.

## Required Proofs

- Open short.
- Rebalance down.
- Reduce-only close.
- Final zero readback.
- Order status and fills.
- Partial-fill handling.
- Rejection handling.
- Rate-limit behavior.

## Required Test Additions Before Any Sandbox Action

- Mocked order placement request serialization.
- Mocked signing payload construction with no real private key in tests.
- Mocked order rejection handling.
- Mocked partial-fill and final-fill lifecycle.
- Mocked reduce-only close response and final zero readback.
- Static tests proving no production runner uses Ethereal.
- Static tests proving production Hyperliquid path remains unchanged.

## Not Part Of Current Branch

This plan is documentation only. The current branch remains read-only and production remains Hyperliquid-only.

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
