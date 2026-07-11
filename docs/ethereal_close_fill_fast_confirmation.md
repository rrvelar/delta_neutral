# Ethereal Reduce-Only Close — Fast Fill Confirmation (bounded)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Scope:** Code + tests only. No live canary, no runner start, no gates, no DB/env/secrets mutation,
`MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` unchanged. Change is default-OFF and not deployed.

Goal: keep `ethereal->extended` policy target_first but make the Ethereal source-close confirmation
faster/bounded so the double-exposure window can fit the 5s production-safe budget — without weakening
any safety threshold.

---

## What was wrong (recap)

The double-exposure window is `target_leg_accepted_at -> source_close_flat_confirmed_at`
(`hedge_venue_migration_executor.rb:728-731`). The Ethereal source close confirms only via
`poll_post_submit_readback` (`ethereal_hedge_execution_service.rb`), which reads the **position**
endpoint up to `POST_SUBMIT_READBACK_ATTEMPTS = 12` times; each read is ~2.8s, so a lagging position
endpoint kept the window open ~37s > 5s. The order itself returns an `exchange_order_id` and Ethereal
documents `GET /v1/order/{id}` (filled quantity, reduce-only, status), which reflects fills before the
aggregated position endpoint.

---

## Change (smallest safe)

In `EtherealHedgeExecutionService#execute`, the post-submit confirmation now goes through
`confirm_post_submit_readback`:

1. For a **reduce-only close-to-flat** (`action == "close"`, expected short 0) with the feature
   enabled and an order id present, it first runs a **bounded** `fast_close_fill_readback`
   (`CLOSE_FILL_CONFIRM_ATTEMPTS = 6`, 0.25s apart):
   - `classify_close_fill` returns `:filled` only when the order status is **reduce-only**, in a
     **terminal FILLED** state, and filled at least the close size (remaining within one lot).
   - `:filled` -> confirmed as source-flat via the authoritative fill (records a final position read
     for observability). This closes the double-exposure window on fill confirmation, not on submit.
   - `:partial` -> never confirms flat; stops the fast path.
   - `:unknown`/unavailable/error -> falls back.
2. Any non-`:filled` outcome (or feature disabled, or non-close action) falls back **fail-closed** to
   the existing `poll_post_submit_readback` position poll. The window still only closes on an
   authoritative flat position readback in that path.

Safety properties:
- Source is never marked flat on submit alone, nor on a partial fill.
- Only a reduce-only, terminally-filled order for >= the close size is trusted.
- `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` is untouched (guard test added).

## Default-OFF + fail-closed (why)
The Ethereal `GET /v1/order/{id}` endpoint is "needs_auth_design" in
`docs/ETHEREAL_OPENAPI_ENDPOINT_MAP.md` and could not be validated against the live API here. So:
- The feature is gated by `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` (default **false**) — production
  behavior is byte-for-byte unchanged until explicitly enabled.
- The default `get_order_status` reader parses defensively and returns `nil` on any error/shape
  mismatch (-> `:unknown` -> position readback). The order-status reader is injectable for tests.
- `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` is read from process ENV (not an OperationalSettings
  gate), so it can be scoped to a single manual canary by passing it inline on the canary command —
  no DB mutation needed.

---

## Files changed
- `app/services/ethereal_hedge_execution_service.rb` — `confirm_post_submit_readback`,
  `fast_close_fill_readback`, `classify_close_fill`, `get_order_status` (injectable), env gate,
  constants; `execute` now routes close confirmation through the new path.
- `test/services/ethereal_hedge_execution_service_test.rb` — 5 new tests.
- `test/services/hedge_venue_migration_executor_test.rb` — guard test: default double-exposure
  threshold is still 5s.

## Tests run (test container, isolated DB)
- ethereal_hedge_execution_service_test — 31 runs, 0 failures (5 new):
  fast fill confirmation before slow polling; fail-closed fallback when order fill unavailable; partial
  fill never confirms flat; non-reduce-only fill ignored -> position readback; disabled-by-default does
  not query order status.
- hedge_venue_migration_executor_test — includes new 5s-threshold guard.
- manual_live_canary_runner + target_first_source_recovery + manual_canary_planner — 40 runs, 0
  failures (no regression from the confirmation refactor).
- RuboCop on changed files — 0 offenses.

Combined touched suites: 64 + 40 runs, 0 failures.

---

## Read-only verification / enable path (needs approval; not done here)
1. Deploy the code (change is not in the running image yet).
2. Validate `GET /v1/order/{id}` read-only against a recent Ethereal order id and confirm the response
   carries a terminal status + filled/remaining quantity + reduceOnly. If field names differ from the
   defensive defaults (`status/orderStatus`, `filledQuantity/cumulativeQuantity/executedQuantity`,
   `remainingQuantity/leavesQuantity`, `reduceOnly`), adjust `get_order_status`.
   Example (read-only):
   `docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
     'svc=EtherealHedgeExecutionService.new; puts svc.send(:get_order_status, "<order_id>").inspect'`
3. Enable only when validated — scope it to a single manual canary by adding
   `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true` to the inline env of `run_manual_live_canary`
   (alongside the other env-only gates). No DB change.

## Safety confirmation
No live canary, no runner start/restart, no gates enabled, no DB/env/secrets mutation, threshold
unchanged. Production behavior unchanged until the feature is validated and explicitly enabled.
Current production state unchanged: venue extended, extended short ~1.669, ethereal/nado flat, open
orders zero, inside_tolerance=true, runner inactive, route proofs 5/6.
