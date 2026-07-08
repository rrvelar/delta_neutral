# Extended fast fill-confirmation — implementation (code + tests, NOT deployed)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** Code + tests only. Not deployed. No live canary, no runner start, no gates, no DB/env/secrets
mutation, no orders/signatures/cancels, no order-construction change, no route-policy change,
`MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS`/latency thresholds unchanged. Default-OFF, fail-closed.

Adds authoritative Extended order-fill confirmation (analogous to Ethereal) so an Extended target-open /
source-close leg can confirm via a single ~2s order-by-id read instead of the ~64s position-readback loop.
The migration executor already consumes `open_fill_confirmation` / `close_fill_confirmation`
venue-agnostically, so no executor code change was needed.

## Current production state (read-only)
Venue **extended** (short 1.816), ethereal/nado flat, open orders zero, `inside_tolerance: true`, runner
**inactive**, gates false, route proofs **5/6** (`ethereal->extended` STALE).

## Files changed / added
- `app/services/extended_api_client.rb` — **added** read-only `order_by_id(order_id)` →
  `GET /user/orders/{order_id}`, `order_history(market:)`, `trades(market:)`. No write changes.
- `app/services/hedge_backends/extended_read_only_probe.rb` — **new** `HedgeBackends::ExtendedReadOnlyProbe#find_order`
  (unwraps `{status:OK,data}`, normalizes `{id(String), status, market, side, qty_eth, filled_eth,
  cancelled_eth, remaining_eth (=qty-filledQty), reduce_only, raw}`; **never raises**, nil on
  error/404/non-OK/shape mismatch; `data.id` stringified because it exceeds 2^53).
- `app/services/extended_mainnet_lifecycle_check.rb` — added default-OFF flags
  `open_fill_confirmation_enabled?` (`EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED`) /
  `close_fill_confirmation_enabled?` (`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED`); `confirm_after_submit`
  (fast path → else slow readback); `fast_open_fill_readback` / `fast_close_fill_readback` /
  `fast_fill_readback`; `classify_open_fill` / `classify_close_fill` / `classify_fill`;
  `build_open_fill_confirmation` / `build_close_fill_confirmation`; `order_size`,
  `order_status_digest`, `decimal`/`decimal_or_nil`; injectable `order_probe:`; new constants
  (`FILL_CONFIRM_ATTEMPTS=6`, `FILL_CONFIRM_INTERVAL_SECONDS=0.25`, `FILL_LOT_TOLERANCE_ETH=0.001`,
  `TERMINAL_FILLED_ORDER_STATUSES=%w[FILLED]`, `FILL_MARKET_SYMBOL="ETH-USD"`). `sign_and_submit` now routes
  confirmation through `confirm_after_submit`; `result` receipt now surfaces `readback_confirmation_source`,
  `open_fill_confirmation`, `close_fill_confirmation`.
- Tests: `test/services/extended_api_client_test.rb` (+3), `test/services/hedge_backends/extended_read_only_probe_test.rb`
  (new, 6), `test/services/extended_mainnet_lifecycle_check_test.rb` (+8, `build_service` gains
  `order_probe:`), `test/services/hedge_venue_migration_executor_test.rb` (+2 Extended-shaped executor tests).

## Executor integration (no code change needed)
`DefaultLegRunner#normalize_service_result` already passes `open_fill_confirmation` /
`close_fill_confirmation` through, and `authoritative_target_open_fill` / `authoritative_source_close_fill`
only require `confirmed==true`, the correct `reduce_only` sense, a present `confirmed_at`, and a non-blank
`source` — all satisfied by the Extended `source: "extended_order_by_id_fill"` confirmations. Verified by two
new executor tests: an Extended target-open fill sets `double_exposure_start_source="authoritative_fill"`
and starts the window at the fill time; an Extended source-close fill sets
`double_exposure_end_source="authoritative_fill"` with `source_close_fill_readback_agreement=true`.

## Confirmation rules (fail-closed)
`classify_fill` confirms `:filled` **only** when: order present, `reduce_only` matches the action
(open=false / close=true), `market == "ETH-USD"`, `side` matches (open=SELL / close=BUY), status terminal
`FILLED`, `filledQty >= expected_size − 0.001`, and `remaining (=qty−filledQty)` within one lot. Anything
partial → `:partial`; anything else → `:unknown`. `:partial`/`:unknown`/unavailable → fall back to the
existing slow position readback. An IOC that under-fills fails `filledQty >= size − lot` and falls back.

## Receipt metadata (Extended leg)
`readback_confirmation_source` ("extended_order_by_id_fill" | "extended_position_readback"),
`open_fill_confirmation` / `close_fill_confirmation` (`{confirmed, source, reduce_only, confirmed_at,
open/close_size_eth, filled_eth, remaining_eth, order_status}`). The executor then derives the per-leg
diagnostics already added: `target_open_confirmation_source`, `target_open_fill_confirmed_at`,
`target_open_position_readback_confirmed_at`, `source_close_confirmation_source`,
`source_close_fill_confirmed_at`, `source_close_position_readback_confirmed_at`, `double_exposure_start_source`,
`double_exposure_end_source`, `target_open_fill_readback_agreement`, `source_close_fill_readback_agreement`.

## Why safety is not weakened
- **Default OFF.** With both flags unset, `confirm_after_submit` goes straight to the existing
  `poll_short_readback`/`poll_flat_readback` — byte-for-byte prior behavior (asserted by the
  disabled-by-default test, which also asserts the order probe is never queried).
- **Never confirmed on submit / acceptance.** Confirmation requires the venue to report the order terminally
  FILLED for the right reduce-only sense, side, market, and at least the submitted size. (Extended's own docs:
  "do not mark success from REST acceptance alone" — respected.)
- **Fail-closed everywhere.** Partial / underfill / cancelled / rejected / expired / reduceOnly-mismatch /
  side-or-market-mismatch / 404 / non-OK / probe raise → fall back to the slow position readback; if that
  doesn't confirm, the leg is unconfirmed and the executor holds (source close not submitted on an
  unconfirmed target open).
- **Final position readback still mandatory.** The executor's `final_readback_status` after both legs must
  independently confirm source flat + target holds + third venue flat + inside tolerance + zero open orders;
  a fill that disagrees → `*_fill_readback_agreement=false` and success is already false → not certified.
- **Thresholds unchanged**; route policy, order construction, and the source_first path untouched. Ethereal
  and Nado behavior unchanged (Ethereal fast-fill tests still pass).

## Tests run (test container, isolated sqlite)
`extended_api_client`, `extended_read_only_probe` (new), `extended_mainnet_lifecycle_check`,
`extended_migration_full`, `extended_migration_step`, `ethereal_hedge_execution_service`,
`hedge_venue_migration_executor`, `migration_manual_live_canary_runner`, `migration_route_proof_registry`,
`migration_manual_canary_gates`, `migration_manual_canary_planner`, `migration_random_readiness`:
**234 runs, 1469 assertions, 0 failures, 0 errors.** RuboCop on the 7 changed files: **0 offenses.**
(Extended-only subset alone: 50 runs, 0 failures.)

## Deploy steps required later (not done here)
1. Commit the working-tree changes (Extended `extended_api_client.rb`,
   `hedge_backends/extended_read_only_probe.rb`, `extended_mainnet_lifecycle_check.rb` + tests).
2. Rebuild the prod image (`docker compose -f docker-compose.prod.yml build web`) and restart the web
   container — the running image is baked, so these edits are NOT live until then.
3. Feature stays OFF until `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED=true` /
   `EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true` are passed (inline on a future approved canary).
4. **Heads-up:** the working tree also carries pre-existing uncommitted changes from earlier sessions
   (`hedge_backends/ethereal_read_only_probe.rb`, `migration_manual_canary_gates.rb`, and two test files).
   A rebuild would ship those too — review before committing/deploying.

## Read-only verification commands
```
docker run --rm --user 0:0 -e RAILS_ENV=test -e SECRET_KEY_BASE=test_only_key \
  -v /opt/delta_neutral:/rails --entrypoint sh delta_neutral-web -lc \
  'bin/rails db:test:prepare && bin/rails test \
     test/services/extended_api_client_test.rb \
     test/services/hedge_backends/extended_read_only_probe_test.rb \
     test/services/extended_mainnet_lifecycle_check_test.rb \
     test/services/hedge_venue_migration_executor_test.rb &&
   bin/rubocop app/services/extended_api_client.rb \
     app/services/hedge_backends/extended_read_only_probe.rb \
     app/services/extended_mainnet_lifecycle_check.rb'
# is it deployed? (expect: not in the running baked image until rebuild)
git status --porcelain app/services/extended_api_client.rb app/services/extended_mainnet_lifecycle_check.rb
```

## Impact once enabled (expected)
A single order-by-id GET (~2s) replaces the multi-attempt position-readback loop (~64s), so an Extended
target-open leg returns fast — shrinking `target_total_latency_seconds`, the real overhedge, and the
double-exposure window for the four Extended-touching routes (`ethereal->extended`, `nado->extended`,
`extended->ethereal`, `extended->nado`). Certification still requires the final readback + latency budgets;
the actual filled-size fee/slippage is unchanged (order construction untouched).

## Safety confirmation
Code + tests only. No deploy, no live canary, no runner start, no gates enabled, no DB/env/secrets mutation,
no orders/signatures/cancels, no order-construction/route-policy change, thresholds unchanged, default OFF.
Production unchanged (venue extended, runner inactive, 5/6).
