# Production Random Rotation — Route-Proof Freshness Fix

**Position:** #6  ·  **Branch:** `feature/dashboard-hedge-execution-controls`  ·  **Date:** 2026-07-06
**Status:** Implemented + tested (not deployed, not committed)

Successful production random-rotation cycles now renew route-proof freshness, so the
runner is no longer stopped by expired canary receipts after it has already migrated the
same routes successfully in production. Current live market safety is also separated from
route-proof *restart* readiness.

---

## Root cause

`MigrationRouteProofRegistry` scans canary / rehearsal / recovery / latency / continuation
receipt directories, but **never the production runner's own cycle log**
(`storage/random_rotation_production/*_position_6.jsonl`). A successful production migration
therefore produced no proof evidence. Each route's freshness rested entirely on the last
*supervised canary* receipt, which expires after the 30-day TTL (`stale_after`). Once the
June 5–7 canary receipts crossed 30 days old, 5/6 routes flipped to `STALE`, and the
runner's preflight raised:

- `all enabled route proofs must be READY_FOR_RANDOM`
- `stale route proofs must be resolved`

…stopping the runner even though it had just migrated those routes successfully in
production.

Secondary problem (item 7): the runner's `current_direct_market_safe?` was gated on
`direct[:blockers].empty?`, and those blockers included the route-proof *restart* blockers.
So a demonstrably safe market (single venue `extended=1.672`, inside tolerance, zero open
orders) was reported `current_direct_market_safe=false` and `production_status="blocked"` —
conflating live market safety with restart readiness.

---

## Changed files

| File | Change |
|---|---|
| `app/services/migration_route_proof_registry.rb` | Ingest production cycle events as a new `production_random_cycle` proof source (strict evidence gate). |
| `app/services/migration_random_production_runner.rb` | Separate live market safety from route-proof restart blockers; expose `restart_blocked_by_route_proofs` + `route_proof_restart_blockers`. |
| `test/services/migration_route_proof_registry_test.rb` | 13 new tests (rotation routes ready, stale-legacy-overridden regression, 10 negatives) + made one pre-existing time-bomb deterministic. |
| `test/services/migration_random_readiness_test.rb` | New test: Extended regains a live-eligible route from fresh production evidence. |
| `test/services/migration_random_production_runner_test.rb` | 2 new tests: market-safe-while-restart-blocked, and market unsafe when a real blocker coexists. |

---

## How production cycles become proof evidence

`MigrationRouteProofRegistry` gained a `production_dir` (default
`MigrationRandomProductionRunner::LOG_DIR`). For each route it now also finds the freshest
successful production cycle via `latest_production_cycle_proof`:

1. `read_production_cycle_events` reads only `*_position_<id>.jsonl` (skipping the `latest_`
   copy), keeps `event == "cycle"`, and memoises per position.
2. `normalize_production_cycle_event` flattens the nested `execution` hash to the flat proof
   shape, stamps `timestamp` from the cycle's `started_at`, derives `position_id` from the
   filename, and records `receipt_source: "production_random_cycle"`.
3. `production_cycle_proof?` is a **strict, fail-closed** gate. A cycle only renews freshness
   when **all** hold:
   - canonical `cycle_status` success **and** `blockers == []`
   - `source_flat_after` (or `source_flat_confirmed`)
   - `target_holds_expected_short` (or `target_holds_hedge_confirmed`)
   - `third_venue_flat`
   - `open_orders_clear_after` **and** `open_orders_after == 0`
   - `final_inside_tolerance`
   - `production_venue_finalized`
   - **not** `manual_action_required`
   - final venue == target venue

   Anything false/unknown is rejected.
4. A fresh production proof is the strongest evidence, so it wins in `status_for` →
   `READY_FOR_RANDOM`, still subject to the same 30-day staleness. The route report gained a
   `proof_source` field.

---

## Status separation (item 7)

- `current_direct_market_safe?` now checks `market_safety_blockers` — all `direct[:blockers]`
  **except** route-proof restart blockers (matched by `ROUTE_PROOF_RESTART_BLOCKER_PATTERN`).
- `production_status` marks `"blocked"` only for real market-safety blockers.
- The `status` / `write_status` payloads gained `restart_blocked_by_route_proofs` and
  `route_proof_restart_blockers`, so a consumer sees "market safe, restart blocked by route
  proofs" explicitly instead of a false unsafe signal.

---

## Before / after on real production data (read-only)

| Route | Before (deployed old code) | After (this fix) |
|---|---|---|
| extended->ethereal | **STALE** 2026-06-05 | **READY_FOR_RANDOM** · production_random_cycle · 2026-07-04 |
| nado->extended | **STALE** 2026-06-06 | **READY_FOR_RANDOM** · production_random_cycle · 2026-07-04 |
| ethereal->nado | READY (canary) 2026-06-07 | **READY_FOR_RANDOM** · production_random_cycle · 2026-07-04 |
| nado->ethereal | **STALE** 2026-06-06 | **READY_FOR_RANDOM** · production_random_cycle · 2026-06-11 |
| ethereal->extended | STALE 2026-06-05 | STALE (no recent production evidence) |
| extended->nado | STALE 2026-06-06 | STALE (no recent production evidence) |

`completed` **1/6 → 4/6**; `stale` **5 → 2**. The two remaining stale routes were genuinely
not exercised in production within the TTL, so the strict gate correctly does **not**
fabricate readiness — a supervised canary remains the path to refresh them.

`current_direct_market_safe` (item 7): the deployed old image reports `status: stopped`,
**`current_direct_market_safe: false`**, `blockers: [route-proof blockers]` for a safe
market. Under the fix that same input yields `current_direct_market_safe: true` +
`restart_blocked_by_route_proofs: true` + the two blockers under
`route_proof_restart_blockers` (proven by new runner tests).

---

## Test results

| Suite | Result |
|---|---|
| `migration_route_proof_registry_test.rb` | **30 pass** (13 new) |
| `migration_random_readiness_test.rb` | **3 pass** (1 new) |
| `migration_random_production_runner_test.rb` | **31 pass** (2 new) |
| `migration_random_system_test.rb` + `migration_execution_preflight_test.rb` | **146 pass** |
| Dashboard regression (`operator_dashboard_helper_test`, `migration_random_production_dashboard_test`) | **22 pass** |
| `bin/rails ethereal:hedge_payload_check` | `orders_placed: 0, signatures_created: 0`, gate passed |
| RuboCop (changed files) | **0 offenses** |

Read-only production checks (old deployed image, documenting the "before"):
`migration:route_proofs` (5 stale), `migration:random_readiness`
(`current_live_eligible_routes: []`), `migration:random_production_status`
(`current_direct_market_safe: false`, blockers = route-proof only, market actually safe).

---

## Safety confirmation

No runner start/stop/restart/reload. No live orders, signatures, or cancels. No
canary/migration/rebalance invoked. No production DB/env/secrets mutated. All production
interaction was read-only: reading status/log files and running read-only `migration:*`
commands. The fix demonstration ran the new code in a throwaway test container mounted
read-only against real storage with a position stub.

---

## Known remaining items

- **Not deployed / not committed** (per instructions). Effect applies only after a deploy.
- **Two routes remain STALE** (`ethereal->extended`, `extended->nado`) — correctly, since
  they have no recent production evidence. Full 6/6 restart still needs a supervised canary
  for those two.
- **Route enablement unchanged:** all 6 routes are enabled in production but the rotation
  only exercises a subset over any window. Restricting required proofs to actively-rotated
  routes is a route-policy (DB/env) decision, not touched here.
- **Dashboard wiring (optional follow-up):** the runner now emits
  `restart_blocked_by_route_proofs` / `route_proof_restart_blockers`, but the Production
  Control Center UI doesn't yet render them.
- One pre-existing, unrelated **time-bomb test** used hardcoded `2026-06-06T20:00:00Z`
  receipts that crossed the 30-day boundary today; its timestamps were made relative to keep
  it deterministic, preserving intent.
