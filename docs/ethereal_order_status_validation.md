# Ethereal Order-Status Validation (read-only) + get_order_status parser fix

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Scope:** Read-only production validation + code/test change only. No live canary, no gates, no runner
start, no DB/env/secrets mutation.

Goal: validate the Ethereal order-status endpoint the fast reduce-only close confirmation would use,
against the real source-close order id from Step 3.

---

## 1. Order id extracted
From `/tmp/step3_canary.out`:
- `source_leg_exchange_order_id = c91e028d-748e-4770-adfb-a71d083c4983` (Ethereal source close).
- (`2074540650492735488` is the Extended target order.)

## 2. Read-only validation result

```
bin/rails runner 'svc=EtherealHedgeExecutionService.new; puts svc.send(:get_order_status, "c91e028d-...").inspect'
=> nil
```

Raw request inspection (read-only):
```
URI:        https://api.ethereal.trade/v1/order/c91e028d-748e-4770-adfb-a71d083c4983
RESP CLASS: Net::HTTPNotFound
RESP:       404 Not Found
```

## 3. Two findings

**(a) Parser response-handling bug (fixed).** The default `http_get` returns a raw `Net::HTTPResponse`
(`Net::HTTP.get_response`), but `get_order_status` only handled a Hash, so it returned `nil` for ANY
real response. The rest of the service uses `response.respond_to?(:body) ? JSON.parse(response.body) :
response`. This is now fixed (see below), including explicit 4xx/5xx -> nil (fail closed).

**(b) Endpoint path is wrong / not reachable.** `GET /v1/order/{id}` returns **404**. The
production-proven way to read Ethereal orders is the LIST endpoint
`GET /v1/order?subaccountId=<id>&...` (used by `hedge_backends/ethereal_read_only_probe.rb:145-167`,
`endpoint /v1/order` with `subaccountId` + product filter). A FILLED (closed) order's fill is not
retrievable via `/v1/order/{id}`; it would need the fills/trades history endpoints
(`GET /v1/order/fill`, `GET /v1/order/trade`, or `GET /v1/position/fill`), none of which are currently
integrated ("needs_auth_design" in `docs/ETHEREAL_OPENAPI_ENDPOINT_MAP.md`).

So the field-name defaults could not be validated — there is no successful response to learn from; the
request itself 404s.

## 4. Change made (parser only)
`get_order_status` now:
- treats a `Net::HTTPResponse` with `code >= 400` (e.g. 404) as `nil` -> fail-closed to position readback;
- parses a 2xx `Net::HTTPResponse` via `JSON.parse(response.body)`;
- still supports injected Hash stubs and returns `nil` on any error.

Field-name parsing is unchanged (defensive defaults retained) because there is no live response shape
to confirm against yet.

## 5. Net effect on safety / the fast path
- With this fix deployed, `get_order_status("c91e028d-...")` returns `nil` (404) -> `classify_close_fill`
  -> `:unknown` -> position-readback fallback. So the fast path stays inert and safe.
- The feature remains default-OFF (`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED`). Even if enabled today,
  it fails closed (404 -> nil -> position poll). It will only speed up the close once wired to the
  correct authenticated order/fills endpoint and validated against a real filled order.

## 6. Files changed
- `app/services/ethereal_hedge_execution_service.rb` — `get_order_status` response handling + 404
  fail-closed (`http_error_response?`).
- `test/services/ethereal_hedge_execution_service_test.rb` — 2 tests: 404 Net::HTTP -> nil; 200 JSON ->
  parsed + classified `:filled`.

## 7. Tests / checks
- ethereal_hedge_execution_service_test — 33 runs, 0 failures.
- RuboCop on changed files — 0 offenses.

## 8. Recommended follow-up (needs its own read-only validation + approval)
Wire `get_order_status` to the working order/fills endpoint:
1. Query `GET /v1/order?subaccountId=<subaccount>&...` (as the open-orders probe does) and/or the fills
   endpoints `GET /v1/order/fill` / `GET /v1/order/trade`, with the same auth the probe uses.
2. Validate read-only against a recent FILLED reduce-only close order to learn the real field names
   (status, filled/cumulative quantity, remaining, reduceOnly) and adjust the parser.
3. Only then enable `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` (scoped inline to one manual canary).

## Safety confirmation
Read-only production calls (a GET that 404'd) + code/test change only. No live canary, no gates, no
runner start/restart, no DB/env/secrets mutation. Production state unchanged: venue extended, extended
short ~1.669, ethereal/nado flat, open orders zero, inside_tolerance=true, runner inactive, proofs 5/6.
