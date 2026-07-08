# Extended fast fill-confirmation feasibility (read-only dig)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** READ-ONLY code + repo-docs dig. No live execution, no runner, no gates, no DB/env/secrets
mutation, no threshold change, no order-construction change. No live API call was made.

## Verdict: **CONFIRMED YES — validated read-only against the live API (2026-07-08)**
Extended's documented reads are real and return terminal filled-order data by id (no Ethereal-style
by-id 404). All three read-only GETs returned HTTP 200 for the known filled target-open order.
They are simply **not implemented** in `extended_api_client.rb` yet.

### Validation results (order 2074738406414946304, read-only GETs, no writes)
- `GET /user/orders/{order_id}` → **HTTP 200**, envelope `{"status":"OK","data":{…}}`:
  `id=2074738406414946304`, `market="ETH-USD"`, `type="MARKET"`, `timeInForce="IOC"`, `side="SELL"`,
  **`status="FILLED"`**, `qty="1.8160"`, **`filledQty="1.8160"`**, `cancelledQty="0.0"`,
  **`reduceOnly=false`**, `averagePrice="1749.2"`. → terminal fill, full size, non-reduce-only. ✓
- `GET /user/orders/history?market=ETH-USD` → HTTP 200, 295 rows; includes the target order (FILLED) and
  the recent reduce-only close (`id=2074726399821369344, side=BUY, reduceOnly=true, status=FILLED`). Same
  field names as by-id. ✓ (so both open AND close legs are retrievable historically)
- `GET /user/trades?market=ETH-USD` → HTTP 200, 300 rows; each has `orderId` linking to the order; the
  target order filled across multiple partial trades (`orderId=2074738406414946304`). ✓ (fallback path)

### Parser field mapping (confirmed)
- envelope: top-level `status=="OK"`; payload under `data` (object for by-id, array for history/trades).
- order id: `data.id` — **JSON integer** (2074738406414946304 > 2^53); **stringify before compare** (the
  receipt already stores it as the string `exchange_order_id`).
- terminal status: `data.status` — observed `"FILLED"` (must also allow other terminals: PARTIALLY-then-
  CANCELLED for IOC, CANCELLED/REJECTED/EXPIRED → not confirmed).
- total size: `data.qty`; filled: `data.filledQty`; cancelled: `data.cancelledQty`;
  remaining = `qty - filledQty` (0 when fully filled).
- reduce-only: `data.reduceOnly` (boolean); side: `data.side` ("SELL"/"BUY"); market: `data.market`.
- IOC caveat: MARKET+IOC can partially fill then cancel the remainder → confirm only when
  `terminal AND filledQty >= expected_size - lot` (fail closed on underfill), exactly like Ethereal.

---

## 1. submit_order response shape
- `ExtendedApiClient#submit_order` → `POST /user/order` (`extended_api_client.rb:57-59`). The full response
  is retained in the receipt via `sanitize_submit_response` (`extended_mainnet_lifecycle_check.rb:479-481`).
- The executor uses it **only** for the order id: `exchange_order_id(submit_response, signer_response)` reads
  `submit_response.data.id` (`extended_mainnet_lifecycle_check.rb:636-641`).
- Per the repo's integration research, `POST /user/order` "returns Extended order id and external id after
  API acceptance" and explicitly: **"Do not mark success from REST acceptance alone"**
  (`docs/EXTENDED_INTEGRATION_FEASIBILITY.md:243-249`). So the submit response carries id/externalId but
  **not a trustworthy terminal fill** — confirmation needs a follow-up read.
- Confirmation today is 100% position readback: `sign_and_submit` → `poll_short_readback` /
  `poll_flat_readback` calling `@venue.read_position` (`:269`, `:494-508`, `:544-558`). That readback loop
  is the ~64.8s cost (the HTTP client timeout is only 2s — `extended_api_client.rb:158-162` — so the 64.8s
  is repeated slow position reads, not one call).
- (Could not extract a raw Extended submit_response from the failed canary — the `manual_live_canary`
  receipt stores only a curated top-level receipt, not per-leg `submit_response`. This is exactly the
  missing per-leg diagnostic recommended earlier.)

## 2. Available Extended read endpoints (documented, per `docs/EXTENDED_INTEGRATION_FEASIBILITY.md:151-160`)
| Endpoint | Auth | Fields | Use |
|---|---|---|---|
| `GET /user/orders?market=` (open only) | API key | `id, externalId, status, side, qty, filledQty, reduceOnly, postOnly, timeInForce` | open-order detection |
| **`GET /user/orders/{order_id}`** | API key | **order status / filled quantity** | **REST fallback confirmation** |
| `GET /user/orders/history` | API key | historical order rows | reconciliation |
| `GET /user/orders/external/{external_id}` | API key | order rows | idempotency/recovery |
| `GET /user/trades?market=` | API key | `orderId, side, price, qty, value, fee` | fills / realized fees |
| `GET /stream.extended.exchange/v1/account` (WS) | API key | `ORDER, TRADE, POSITION` events | "final order/position truth" |

**Only `open_orders`/`positions`/`balance`/`leverage`/`fees`/`markets`/`submit_order` are implemented**
in `extended_api_client.rb:21-59`. `GET /user/orders/{order_id}`, `/user/orders/history`, `/user/trades`,
and the account WS are **documented but NOT wired**. No `ExtendedReadOnlyProbe` exists.

## 3. Can order 2074738406414946304 be queried?
**Theoretically yes** — via `GET /user/orders/{order_id}` (documented to return order status + filled
quantity), with `/user/orders/history` and `/user/trades?market=ETH-USD` as corroborating reads. That order
is the Extended target-open from the failed canary; the position is still open (extended short 1.816), so it
should return terminal FILLED with `filledQty ≈ 1.816`, `reduceOnly=false`.

Caveat: the feasibility doc is research transcribed from Extended's public docs, not verified in-code
against a *filled* order. Ethereal's `GET /v1/order/{id}` 404'd on us and we had to use the list endpoint —
Extended's by-id endpoint could likewise differ (404 on filled, different field names, `data` wrapper).
So the shape MUST be validated read-only before trusting it.

### Proposed validation (READ-ONLY — do NOT run per your instruction; for you to run when ready)
API-key GET only; no orders, no signatures, no writes. Run inside the web container env (has
`EXTENDED_API_KEY` + `EXTENDED_API_BASE_URL=https://api.starknet.extended.exchange/api/v1`):
```
# order-by-id: does a FILLED order return with status + filledQty + reduceOnly?
curl -s -H "X-Api-Key: $EXTENDED_API_KEY" \
  "$EXTENDED_API_BASE_URL/user/orders/2074738406414946304" | jq .
# do filled orders appear in history / trades (fallbacks)?
curl -s -H "X-Api-Key: $EXTENDED_API_KEY" "$EXTENDED_API_BASE_URL/user/orders/history?market=ETH-USD" | jq '.data[0:3]'
curl -s -H "X-Api-Key: $EXTENDED_API_KEY" "$EXTENDED_API_BASE_URL/user/trades?market=ETH-USD" | jq '.data[0:3]'
```
Confirm: terminal status value(s) (e.g. `FILLED`), the filled-size field name (`filledQty`), `qty` (total),
`reduceOnly`, and how remaining is derived (`qty - filledQty`). Those become the `classify_*_fill` inputs.

## 4. Is `/user/orders` open-only or can it return filled history?
`GET /user/orders?market=` is **open-orders only** (`extended_api_client.rb:33-35`; doc: "pending order
detection"). A fully-filled order drops off it. Historical/filled retrieval requires the separate
`/user/orders/history`, `/user/orders/{order_id}`, or `/user/trades` endpoints (none wired yet).

## 6. Feasibility conclusion
Not "NO". The endpoints exist in Extended's documented API; the blocker is that they are **unimplemented in
this repo**, plus **unverified response shapes**. This is a build-with-validation task, not a dead end.

## 5/7. Safest next step (recommended order)
1. **Validate read-only** (command above) the `/user/orders/{order_id}` (+ history/trades) response for a
   known filled order — confirm status/filledQty/reduceOnly/qty field names and that a FILLED order is
   retrievable. (You run it; I do not.)
2. **If validated**, implement behind **default-OFF** flags, fail-closed, final readback still mandatory:
   - `ExtendedApiClient#order_by_id(order_id)` → `GET /user/orders/{order_id}` (+ optional `order_history`
     / `trades` fallback).
   - `ExtendedReadOnlyProbe#find_order` normalizing to `{status, filled_eth, remaining_eth, reduce_only}`
     (mirror `EtherealReadOnlyProbe`).
   - `classify_open_fill` / `classify_close_fill` + `fast_open_fill_readback` / `fast_close_fill_readback`
     in the Extended execution path, gated by `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED` /
     `EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED` (default OFF).
   - Because a single order-by-id GET (~2s) replaces the multi-attempt position readback (~64s), this
     directly shrinks `target_total_latency`, the real overhedge, and the double-exposure window for all
     four Extended-touching routes.
   - Add the missing per-leg receipt diagnostics (confirmation source + timing) at the same time.
3. **If validation fails** (by-id 404s, no filled retrieval, wrong shape): fall back to `/user/trades`
   (fills by orderId) or `/user/orders/history`; if none usable, escalate — Extended fast confirmation then
   needs external Extended API/vendor support and cannot be built from current repo knowledge alone.

## Summary answers
- **submit_order response shape:** id + externalId on acceptance; NOT trustworthy terminal fill ("do not
  mark success from REST acceptance alone"). Retained but used only for `data.id`.
- **Available Extended read endpoints:** implemented = open_orders/positions/balance/leverage/fees/markets;
  documented-but-unwired = **order-by-id, order-history, order-external-id, trades/fills, account WS**.
- **Order 2074738406414946304 queryable?** Theoretically yes via `GET /user/orders/{order_id}`; needs
  read-only shape validation.
- **Verdict:** **YES**, contingent on a one-command read-only response-shape validation.
- **Safest next step:** run the read-only validation GET; if it returns terminal fill + size + reduceOnly,
  build the Extended probe + fast-fill behind default-OFF flags (fail-closed, final readback mandatory).

## Safety confirmation
Read-only investigation only. No live API call was made, no live execution, no runner, no gates, no
DB/env/secrets mutation, no thresholds/order-construction changed. Production unchanged (venue extended,
runner inactive, 5/6).
