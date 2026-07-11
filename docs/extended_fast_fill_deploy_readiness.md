# Deploy-readiness review — Extended fast fill confirmation

**VPS:** France · **Path:** /opt/delta_neutral · **Branch:** feature/dashboard-hedge-execution-controls
**Date:** 2026-07-08 · **Status:** committed locally, **NOT built, NOT deployed, NOT pushed.**

## Key correction to the assumed groups
- **Group B was already committed & deployed.** `ethereal_hedge_execution_service.rb` and
  `hedge_venue_migration_executor.rb` are in HEAD `79a7138` (running image, built 06:01). They are NOT in
  the working tree diff — nothing to re-commit.
- **But a required companion was missing:** the deployed Ethereal service calls
  `HedgeBackends::EtherealReadOnlyProbe#find_order`, yet that method was **never committed** (0 occurrences
  in HEAD, 1 in the deployed service's call site). In the running image the call raises NoMethodError
  (rescued to nil) → the Ethereal fast fill **silently falls back to the slow readback** (safe, but the
  optimization never actually runs). Committing `find_order` is therefore **required**, not optional.

## Commits created (local, on feature branch)
1. `d9d3212` **Add Ethereal read-only find_order for authoritative fill confirmation**
   - `app/services/hedge_backends/ethereal_read_only_probe.rb`
   - `test/services/hedge_backends/ethereal_read_only_probe_test.rb`
2. `310ee63` **Add Extended authoritative fast fill confirmation (default-OFF)**
   - `app/services/extended_api_client.rb`
   - `app/services/hedge_backends/extended_read_only_probe.rb`
   - `app/services/extended_mainnet_lifecycle_check.rb`
   - `test/services/extended_api_client_test.rb`
   - `test/services/hedge_backends/extended_read_only_probe_test.rb`
   - `test/services/extended_mainnet_lifecycle_check_test.rb`
   - `test/services/hedge_venue_migration_executor_test.rb`
   - `docs/extended_fast_fill_confirmation_implementation.md`, `docs/extended_fill_confirmation_feasibility.md`,
     `docs/route_proof_latency_map.md`

## Group C — remaining working-tree changes (NOT committed) + decisions
| Item | What it is | Required by current safety path? | Tested? | Safe to ship now? | Decision |
|---|---|---|---|---|---|
| `app/services/migration_manual_canary_gates.rb` (M) | **Unrelated runtime** refactor of arm/disarm auto pause/restore (renames + `paused_autos` persistence) | **No** — HEAD version already works (it ran the last canary's arm/disarm) | Yes (passes with its test in the tree) | Functionally yes, but **unreviewed for deploy** | **STASH before build** (or commit + review as its own change later). Must NOT ride the Extended deploy. |
| `test/services/migration_manual_canary_gates_test.rb` (M) | Test for the above refactor | No | Yes | — | **Stash together** with the gates service (kept consistent). |
| `test/services/migration_route_proof_registry_test.rb` (M) | **Test-only**: adds fill-certification tests for the already-deployed executor + makes staleness dates relative (time-bomb fix) | Keeps the suite green over time | Yes | Yes (inert at runtime) | **Keep** (leave uncommitted, or a small test-hygiene commit). Do not stash — the time-bomb fix keeps the registry suite green. |
| `audit/` (?? , 2.1M) | Generated audit pack (2026-07-07), not code | No | n/a | Inert, but **bloats the build context** (not in `.dockerignore`) | **Exclude** — add `audit/` to `.dockerignore`; do not commit. |
| `docs/*.md` (?? , ~15) | Prior-session reports | No | n/a | Inert | Optional — leave untracked or commit as docs; not required for deploy. |

**The only unrelated RUNTIME change is `migration_manual_canary_gates.rb`.** Everything else remaining is
test-only or inert (docs/audit). Because a rebuild ships the whole working tree, the gates service change
must be stashed before building.

## Tests (test container, isolated sqlite)
- **Committed deploy set only** (gates refactor stashed out): required suites =
  **220 runs, 1365 assertions, 0 failures, 0 errors.** Proves the Extended + Ethereal-find_order deploy set
  is green standalone and does not need the gates refactor.
- Full working tree (everything present): 234 runs, 0 failures (recorded earlier).
- New `find_order` direct tests added (returns matching filled order / nil / never raises).
- **RuboCop** on all 9 changed files: **0 offenses.**

## Working tree clean after commit?
**No — by design.** After the two commits, the tree still holds: `migration_manual_canary_gates.rb` (M),
`migration_manual_canary_gates_test.rb` (M), `migration_route_proof_registry_test.rb` (M), `audit/` (??),
and ~15 untracked `docs/*.md`. The committed **runtime** deploy set (Extended + Ethereal `find_order`) is
complete and self-consistent; the remaining items are the unrelated gates refactor (stash), a test-only
registry change (keep), and inert docs/audit (exclude/ignore).

## Deploy commands (DO NOT EXECUTE YET)
```
# 0. From /opt/delta_neutral, on the feature branch, after this review.
# 1. Move the unrelated gates refactor out of the build context (reversible):
git stash push -m "gates-refactor" \
  app/services/migration_manual_canary_gates.rb test/services/migration_manual_canary_gates_test.rb
# 2. Keep audit/ (and untracked docs) out of the image build context:
grep -qxF 'audit/' .dockerignore || echo 'audit/' >> .dockerignore
# 3. Build the baked image and restart web (baked image => code is live only after this):
docker compose -f docker-compose.prod.yml build web
docker compose -f docker-compose.prod.yml up -d web
# 4. Restore the gates refactor to the working tree for its own later review:
git stash pop
```
Feature stays inert after deploy: `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED` /
`EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED` (and the Ethereal flags) remain **OFF** until passed inline on a
future approved canary.

## Post-deploy read-only verification (no runner exec, no live orders)
```
# new image built after the commits?
docker compose -f docker-compose.prod.yml images web        # note IMAGE created time
git log -1 --format='%h %ci %s'                             # commit time < image time => deployed
# production unchanged / safe:
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:random_production_status position_id=6
docker compose -f docker-compose.prod.yml exec -T web bin/rails migration:route_proofs position_id=6
systemctl is-active delta-neutral-random-production-6.service || true
```
Expect: venue extended, runner inactive, gates false, route proofs 5/6 — unchanged (flags OFF ⇒ no
behavior change on deploy).

## Future live plan (DO NOT RUN — separate explicit approval required)
A single supervised canary on an Extended-target route (e.g. `nado->extended`, target_first — needs venue
on nado first; or re-prove `ethereal->extended` after repositioning to ethereal) with
`EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED=true` (target=extended) and, where Ethereal is the source,
`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true` — via the arm/disarm gate flow. Expected: the Extended
target-open leg confirms in ~2s (order-by-id) instead of ~64s, so `target_total_latency_seconds` << 15s,
`total_migration_latency_seconds` << 45s, `double_exposure_seconds` <= 5s → route certifies. Same hard
limits as before (no runner start, disarm always, fail closed). Not part of this task.

## Safety confirmation
Local commits only. No build, no deploy, no push, no live canary, no runner start, no gates enabled, no
DB/env/secrets mutation, no orders/signatures/cancels, thresholds unchanged, feature default OFF.
Production unchanged (venue extended, runner inactive, 5/6).
