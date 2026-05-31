# Hedge Migration Route Capabilities

Checked: 2026-05-31

This document records the public API facts used by the supervised migration route planner. Readiness and rehearsal paths remain no-live: they submit zero orders and create zero signatures.

## Extended

Official source: https://api.docs.extended.exchange/

Relevant facts:
- Read-only account/market/order-history calls use `GET` with API-key authentication.
- Order submit uses `POST /api/v1/user/order`.
- Write operations require a Stark signature in addition to the API key.
- The existing `HedgeVenues::Extended`, `ExtendedHedgeExecutionService`, and `ExtendedMainnetLifecycleCheck` implement readback, open-order checks, signed submit, and post-submit readback confirmation behind explicit live gates.

## Ethereal

Official sources:
- https://api.ethereal.trade/openapi.json
- https://api.ethereal.trade/docs
- https://docs.ethereal.trade/

Relevant facts:
- Current position readback is `GET /v1/position/active`.
- Subaccount balance/health is `GET /v1/subaccount/balance`.
- Working open orders are read with `GET /v1/order` using `subaccountId`, `productIds`, `isWorking=true`.
- Order submit uses `POST /v1/order` and is implemented only through `EtherealHedgeExecutionService` with EIP-712 signer gates and post-submit readback.

## Nado

Official sources:
- https://docs.nado.xyz/developer-resources/api/gateway/queries/order
- https://docs.nado.xyz/developer-resources/api/gateway/queries/orders
- https://docs.nado.xyz/developer-resources/api/gateway/queries/subaccount-info
- https://docs.nado.xyz/developer-resources/api/order-appendix
- https://nadohq.github.io/nado-python-sdk/api-reference.html

Relevant facts:
- Gateway order lookup uses `/query?type=order&product_id=...&digest=...`.
- Gateway order-list lookup supports the `orders` query surface used by `HedgeVenues::Nado` for open-order readback.
- Subaccount readback is available through gateway subaccount and isolated-position query surfaces.
- The order appendix encodes isolated margin, order type, and reduce-only. The reduce-only bit prevents increasing exposure and is required for source close/reduce legs.
- `NadoHedgeExecutionService` builds EIP-712 `Order` payloads, supports isolated open/increase, reduce-only delta decrease/close, submit response digest classification, and readback confirmation behind explicit live gates.

## Route Policy

All six directed routes are represented:
- `extended -> ethereal`
- `ethereal -> extended`
- `extended -> nado`
- `nado -> extended`
- `ethereal -> nado`
- `nado -> ethereal`

The default and only supported live sequence is `target_first`. `source_first` remains blocked unless a future task proves and gates it separately.

Every target-first route has the same recovery design:
- If the target leg fails before readback, do not submit source close.
- If target readback confirms but source close fails, keep production venue unchanged and require operator recovery.
- Recovery is reduce-only on the venue being closed and requires fresh readback, zero open orders, exact confirmation, and live gates.
