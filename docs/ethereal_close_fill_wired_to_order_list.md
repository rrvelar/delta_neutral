# Ethereal Fast Close Confirmation — wired to the proven order-list read (validated)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Scope:** Read-only production validation + code/test change only. No live canary, no gates, no runner
start, no DB/env/secrets mutation. `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` unchanged.

`get_order_status` now uses the production-proven Ethereal order-list read (not the non-existent
`GET /v1/order/{id}`), validated read-only against the real Step 3 filled close order.

---

## 1-2. Proven read path (reused)
`hedge_backends/ethereal_read_only_probe.rb#open_orders` reads orders via the PUBLIC (no auth token)
endpoint `GET /v1/order` with `subaccountId` + `productIds` (product resolved from
`GET /v1/product?ticker=ETHUSD`). It filters `isWorking: true` (open only). Added a public
`EtherealReadOnlyProbe#find_order(order_id)` that reuses that exact request path **without** `isWorking`
so filled/historical orders are included, and returns the raw order hash or nil (never raises).

## 3. Read-only lookup of the Step 3 close order
`c91e028d-748e-4770-adfb-a71d083c4983` was NOT found via `/v1/order/{id}` (404). Via
`GET /v1/order?subaccountId=&productIds=&limit=100` (no `isWorking`) it WAS found.

## 4-5. Real validated response shape
```
id:               c91e028d-748e-4770-adfb-a71d083c4983
type:             LIMIT
status:           FILLED          # terminal filled status
quantity:         1.7025          # order size
filled:           1.7025          # cumulative filled  -> field name is "filled"
availableQuantity:1.7025          # NOT remaining! equals quantity even when fully filled
reduceOnly:       true
side:             0               # reduce-only buy
```
Key correction: `availableQuantity` is **not** the leaves/remaining quantity (it reports `1.7025` for a
fully filled order). Remaining is derived authoritatively as `quantity - filled = 0`.

## 6. Parser patch (validated)
- `get_order_status(order_id)` -> `EtherealReadOnlyProbe.new(env:).find_order(order_id)` ->
  `normalize_ethereal_order`.
- `normalize_ethereal_order` maps: `status`, `filled_eth = filled`, `remaining_eth = quantity - filled`
  (NOT availableQuantity), `reduce_only = reduceOnly`.
- Fail closed: missing subaccount/product, not found, or any error -> nil -> `:unknown` -> position
  readback.

End-to-end read-only validation against production (corrected logic):
```
status=FILLED filled=1.7025 remaining(q-f)=0.0 reduceOnly=true
classify_close_fill => :filled
```

## 7. Tests
- `test/services/ethereal_hedge_execution_service_test.rb`:
  - normalize maps the real filled reduce-only close shape -> `:filled`.
  - normalize derives remaining from quantity - filled, ignoring `availableQuantity` (partial -> `:partial`).
  - `get_order_status` returns nil when subaccount not configured (fail closed).
  - (retained) fast fill confirms before slow polling; fallback when unavailable; partial never flat;
    non-reduce-only ignored; disabled-by-default doesn't query.
- `hedge_venue_migration_executor_test.rb` — 5s double-exposure threshold guard.
- Suite (ethereal + executor + manual canary runner + probe): 96 runs, 0 failures. RuboCop 0 offenses.

## Files changed
- `app/services/hedge_backends/ethereal_read_only_probe.rb` — public `find_order`.
- `app/services/ethereal_hedge_execution_service.rb` — `get_order_status` via probe +
  `normalize_ethereal_order` (remaining = quantity - filled).
- `test/services/ethereal_hedge_execution_service_test.rb` — real-shape tests.

## Enable path (default-OFF; needs deploy + approval)
Feature still gated by `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` (default false). After deploy, enable
it scoped inline on a single manual canary (env-only gate, no DB change). The fast path confirms a
reduce-only close as soon as the order-list read shows `status=FILLED` with `filled >= close size`,
closing the double-exposure window without the ~12-attempt position poll. Any non-`:filled`/error falls
back to the position readback.

## Safety confirmation
Read-only production GETs (order/product list) + code/tests only. No live canary, no gates, no runner
start/restart, no DB/env/secrets mutation, threshold unchanged. Production state unchanged: venue
extended, extended short ~1.669, ethereal/nado flat, open orders zero, inside_tolerance=true, runner
inactive, route proofs 5/6.
