# Extended build-read consolidation — implementation (code + tests, NOT deployed)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-09
**Scope:** Code + tests only. Not deployed. No live canary, no arm, no runner/scheduler, no orders, no
route, no rebuild/push, no threshold/route-policy/order-construction change, no blocker removed, no DB/env/
secrets mutation. Positions/balance are NOT cached across the submit boundary.

Reduces the Extended pre-submit build latency by reading each required Extended endpoint **once per leg**
via an in-memory, opt-in read snapshot, reusing it for order preview + all blockers + diagnostics, while
the post-submit readback still reads **fresh**. Mirrors the fresh Python `snapshot → gate → submit →
readback` pattern, adapted to an in-memory per-leg snapshot (no persisted/stale snapshot).

## Files changed
- `app/services/hedge_venues/extended.rb`
  - `VOLATILE_READ_METHODS = %i[positions balance open_orders]`; `@read_snapshot` (nil = OFF).
  - Opt-in scope API: `read_snapshot_active?`, `begin_read_snapshot!`, `end_read_snapshot!`,
    `invalidate_volatile_reads!`.
  - `read_only_call(method, force: false, **kwargs)` — memoizes per `[method, kwargs]` **only while a
    snapshot is active**; `force: true` or no snapshot ⇒ fresh (unchanged behavior). New `uncached_read`
    keeps the existing rescue/error-hash contract.
  - `read_position(symbol:, force: false)` and `account_value_fields(force: false)` thread `force`.
- `app/services/extended_mainnet_lifecycle_check.rb`
  - `run` opens a build snapshot (only if a caller hasn't already) and closes it in `ensure`.
  - After `submit_order`: `@venue.invalidate_volatile_reads!` (drops positions/balance/open_orders).
  - `poll_short_readback` / `poll_flat_readback` call `read_position(..., force: true)` (fresh each attempt).
- `app/services/hedge_venue_migration_executor.rb`
  - `DefaultLegRunner#run_extended_leg` / `#run_extended_source_close_leg` wrap the leg (pre-read + service
    call) in `with_extended_read_snapshot(venue)` so the executor pre-read and the lifecycle build share
    one snapshot; lifecycle sees it active and does not re-own it.
- `test/services/extended_mainnet_lifecycle_check_test.rb` — `counting_api_client` (counts GETs per
  endpoint, snapshots counts at the submit boundary) + 5 tests.

## Before / after GET count (per Extended leg, before submit)
| endpoint | before | after |
|---|---|---|
| positions | ~4-5 | 1 |
| balance | ~8 | 1 |
| leverage | ~3-4 | 1 |
| account_info | ~3-4 | 1 |
| market | ~3 | 1 |
| open_orders | ~3-4 | 1 |
| fees | ~2 | 1 |
| **total before submit** | **~30-40** | **≤ 8 (asserted; ~7, one per endpoint)** |
| post-submit readback | fresh positions/balance | **fresh** (force: true) — unchanged |

Estimated build latency: ~34s → ~6-8s (must be re-measured on the next canary via the deployed
`slow_step` / `build_latency_seconds` diagnostics).

## Tests (test container, isolated sqlite)
New (in `extended_mainnet_lifecycle_check_test.rb`):
- open build issues **≤8 GETs, ≤1 per endpoint before submit**, run still `success`, and the readback
  re-reads positions+balance **fresh** (count > at-submit).
- close build same (≤8, ≤1/endpoint), readback re-reads positions fresh.
- snapshot **OFF by default** — two `read_position` calls on a plain venue hit the API twice (no cache leak
  into other callers).
- blockers identical with the snapshot — leverage 10x still `blocked_before_submit` with the exact blocker,
  no order placed.
- an errored read inside a snapshot **fails closed** (nil position).

Suites run: extended_mainnet_lifecycle_check, extended_api_client, hedge_backends/extended_read_only_probe,
extended_migration_full, extended_migration_step, extended_auto_rebalance_once,
extended_pending_rebalance_reconciler, hedge_venue_migration_executor, migration_manual_live_canary_runner,
migration_route_proof_registry, migration_manual_canary_gates, hedge_venue_accounting —
**227 runs, 1467 assertions, 0 failures, 0 errors.** RuboCop on the 4 changed files: **0 offenses.**
(Earlier full Extended regression set: 148 runs, 0 failures.)

## Why safety is not weakened
- **Opt-in, default OFF.** Without an active snapshot, `read_only_call` behaves exactly as before (fresh
  every call), so every other caller (dashboards, auto-rebalance, reconcilers, status) is unchanged
  (asserted).
- **Build snapshot = a single consistent pre-submit moment.** During the build no order has been placed, so
  positions/balance/leverage/etc. are static; one read per endpoint yields identical values to today's
  repeated reads (and is more internally consistent). All blockers evaluate identically (asserted:
  leverage-10x still blocks; a clean open still succeeds).
- **Volatile reads never cross submit.** `positions`/`balance`/`open_orders` are invalidated immediately
  after `submit_order`; the readback passes `force: true` (fresh each poll attempt); the Ethereal/Extended
  order-by-id fast fill reads the order fresh and is untouched.
- **Final readback unchanged.** The executor's `final_readback_status`/verifier runs its own fresh reads;
  no cache reaches it.
- **Fail-closed preserved.** An errored read is returned as the same error hash and handled by the same
  blockers (nil position ⇒ fail closed, asserted). No blocker removed; order construction, thresholds,
  route policy, and proof-registry semantics unchanged.

## Deploy steps required later (NOT done here)
1. Commit the 4 changed files.
2. Rebuild the prod image (`docker compose -f docker-compose.prod.yml build web`) and restart `web` — baked
   image, so this is live only after a rebuild.
3. No flag needed — the snapshot is engaged automatically inside the migration Extended leg path; other
   paths are unaffected (default OFF).

## Read-only verification commands
```
docker run --rm --user 0:0 -e RAILS_ENV=test -e SECRET_KEY_BASE=test_only_key \
  -v /opt/delta_neutral:/rails --entrypoint sh delta_neutral-web -lc \
  'bin/rails db:test:prepare && bin/rails test \
     test/services/extended_mainnet_lifecycle_check_test.rb \
     test/services/hedge_venue_migration_executor_test.rb &&
   bin/rubocop app/services/hedge_venues/extended.rb \
     app/services/extended_mainnet_lifecycle_check.rb \
     app/services/hedge_venue_migration_executor.rb'
```

## Is ethereal->extended safe to retry now? **NO — still blocked.**
This is code + tests only; nothing is deployed. `ethereal->extended` remains NOT safe to retry until this
consolidation is **deployed** AND a supervised canary **measures** (via the deployed observability
diagnostics) `target_total_latency < 15s` and `double_exposure_seconds < 5s`. Until then the ~34s Extended
build latency is unchanged in production.

## Safety confirmation
Code + tests only. No deploy/rebuild/push, no live canary, no arm, no runner/scheduler, no route, no
orders/signatures/cancels, no threshold/route-policy/order-construction change, no blocker removed, no DB/
env/secrets mutation, positions/balance not cached across submit. Production unchanged: venue ethereal,
runner inactive, gates false, route proofs 5/6.
