# Position #6 — Bring Route Proofs to 6/6 READY_FOR_RANDOM (Supervised Canary Plan)

**Position:** #6  ·  **Branch:** `feature/dashboard-hedge-execution-controls`  ·  **Date:** 2026-07-07
**Status:** Read-only inspection + dry-runs complete. **No live canary executed. Awaiting explicit approval.**

Goal: safely refresh the two remaining stale route proofs (`ethereal->extended`, `extended->nado`)
so all six routes are `READY_FOR_RANDOM`, **without** starting/restarting the production runner
and **without** any live order/signature until an explicitly approved supervised canary step.

---

## 1. Current safety verdict — SAFE TO PROCEED (planning/dry-run only)

| Check | Value | Verdict |
|---|---|---|
| Runner (systemd) | `inactive`, pid `None`, `duplicate_runner_process=false` | stopped, untouched |
| `current_direct_market_safe` | `true` | ok |
| Active short venues | `["extended"]` (single) | exactly one |
| Direct shorts | extended `1.622`, ethereal `0.0`, nado `0.0` | no unknowns |
| Open orders | zero on all three venues | ok |
| Inside tolerance | `true` (drift 0.0028 << tol 0.0487) | ok |
| Live gates | `MIGRATION_LIVE_ENABLED=false`, autopilot off | nothing can fire |
| Route proofs | 4/6 READY (all `production_random_cycle`), 2 stale | target of this plan |

Fail-closed conditions (unknown readback / non-zero or unknown open orders / multiple active
short venues / out-of-tolerance) are all clear.

Route proof state (read-only `migration:route_proofs position_id=6`):

```
extended->ethereal   READY_FOR_RANDOM   source=production_random_cycle  2026-07-04
ethereal->extended   STALE                                             2026-06-05   <-- refresh
extended->nado       STALE                                             2026-06-06   <-- refresh
nado->extended       READY_FOR_RANDOM   source=production_random_cycle  2026-07-04
ethereal->nado       READY_FOR_RANDOM   source=production_random_cycle  2026-07-04
nado->ethereal       READY_FOR_RANDOM   source=production_random_cycle  2026-06-11
```

---

## 2. Exact route sequence (minimal, 3 supervised migrations, ends back at `extended`)

Each supervised canary **moves the production venue**. `ethereal->extended` (target_first) can only
be proven while the hedge is on Ethereal; `extended->nado` (source_first) only from Extended. The
minimal path that proves both new routes and returns to the current production venue:

```
 start: extended
 1) extended->nado    (source_first)  -> proves stale route, lands on NADO
 2) nado->ethereal    (target_first)  -> REPOSITION (already READY, refreshes it), lands on ETHEREAL
 3) ethereal->extended(target_first)  -> proves stale route, lands on EXTENDED
 end:   extended  ->  6/6 READY_FOR_RANDOM
```

Three steps is the minimum: `extended->nado` starts at Extended (current) but lands on Nado, so one
reposition via the already-proven `nado->ethereal` is required to reach Ethereal for the second new
proof.

---

## 3. Expected proof status after each step

| After step | Production venue | Route proofs |
|---|---|---|
| 1 · extended->nado | nado | **extended->nado -> READY** · 5/6 |
| 2 · nado->ethereal | ethereal | nado->ethereal refreshed · still 5/6 (ethereal->extended pending) |
| 3 · ethereal->extended | **extended** | **ethereal->extended -> READY** · **6/6 READY_FOR_RANDOM** |

---

## 4. Dry-run phase — ALREADY EXECUTED (read-only, 0 orders / 0 signatures)

```bash
bin/rails migration:rehearse_route position_id=6 from=extended  to=nado     mode=full sequence=source_first dry_run=true
bin/rails migration:rehearse_route position_id=6 from=nado      to=ethereal mode=full sequence=target_first dry_run=true
bin/rails migration:rehearse_route position_id=6 from=ethereal  to=extended mode=full sequence=target_first dry_run=true
```

All three returned `dry_run: true`, `live: false`, `orders_submitted=0, orders_placed=0,
signatures_created=0`, `blocked_no_live` — blocked only by "live gate off" / venue-precondition
reasons (no safety/readback failures). Steps 2–3 additionally report
`position hedge execution_venue must be <src>` — expected, since those routes only become runnable
after the prior step repositions the venue.

---

## 5. Live phase — DO NOT EXECUTE WITHOUT EXPLICIT APPROVAL

Run one step at a time, verifying `READY_FOR_RANDOM` after each before starting the next. Enable
gates only for the single canary and disable them again after each step. Keep `MIGRATION_AUTO_ENABLED`
and `MIGRATION_RANDOM_ROTATION_LIVE_ENABLED` **OFF** throughout — this is a manual canary, not the
runner. Prefer passing gates inline on the command (non-persistent) so nothing is left enabled.

Gates required (from the dry-run blockers): `MIGRATION_LIVE_ENABLED`,
`MIGRATION_MANUAL_LIVE_CANARY_ENABLED`, `MIGRATION_FULL_ALLOWED`; plus for nado-touching steps 1–2
`AERODROME_NADO_HEDGE_LIVE_ENABLED`, `AERODROME_NADO_LIVE_MIGRATION_ENABLED`; plus for step 1
(source_first) `MIGRATION_SOURCE_FIRST_CANARY_ALLOWED`.

```bash
# STEP 1: extended -> nado (source_first)
bin/rails migration:random_production_status position_id=6      # expect market_safe=true, venue=extended
bin/rails migration:rehearse_route position_id=6 from=extended to=nado mode=full sequence=source_first dry_run=true
# live (APPROVAL REQUIRED):
MIGRATION_LIVE_ENABLED=true MIGRATION_MANUAL_LIVE_CANARY_ENABLED=true MIGRATION_FULL_ALLOWED=true \
AERODROME_NADO_HEDGE_LIVE_ENABLED=true AERODROME_NADO_LIVE_MIGRATION_ENABLED=true MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true \
bin/rails migration:run_manual_live_canary position_id=6 from=extended to=nado sequence=source_first \
  confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
# post-verify:
bin/rails migration:route_proofs position_id=6                  # expect extended->nado = READY_FOR_RANDOM
bin/rails migration:random_production_status position_id=6      # expect venue=nado, single venue, inside tol, open orders zero
# rollback if it fails (source_first underhedge -> re-open target):
bin/rails migration:recover_target_first_source_close position_id=6 from=extended to=nado dry_run=true

# STEP 2: nado -> ethereal (target_first, reposition)
bin/rails migration:rehearse_route position_id=6 from=nado to=ethereal mode=full sequence=target_first dry_run=true
MIGRATION_LIVE_ENABLED=true MIGRATION_MANUAL_LIVE_CANARY_ENABLED=true MIGRATION_FULL_ALLOWED=true \
AERODROME_NADO_HEDGE_LIVE_ENABLED=true AERODROME_NADO_LIVE_MIGRATION_ENABLED=true \
bin/rails migration:run_manual_live_canary position_id=6 from=nado to=ethereal sequence=target_first \
  confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
bin/rails migration:route_proofs position_id=6                  # nado->ethereal refreshed
bin/rails migration:random_production_status position_id=6      # expect venue=ethereal, safe
bin/rails migration:recover_target_first_source_close position_id=6 from=nado to=ethereal dry_run=true

# STEP 3: ethereal -> extended (target_first)
bin/rails migration:rehearse_route position_id=6 from=ethereal to=extended mode=full sequence=target_first dry_run=true
MIGRATION_LIVE_ENABLED=true MIGRATION_MANUAL_LIVE_CANARY_ENABLED=true MIGRATION_FULL_ALLOWED=true \
bin/rails migration:run_manual_live_canary position_id=6 from=ethereal to=extended sequence=target_first \
  confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY
bin/rails migration:route_proofs position_id=6                  # expect 6/6 READY_FOR_RANDOM, venue=extended
bin/rails migration:random_readiness position_id=6             # current_live_eligible_routes populated
bin/rails migration:recover_target_first_source_close position_id=6 from=ethereal to=extended dry_run=true
```

**Rollback/recovery model:**
- target_first (steps 2, 3): if the 2nd leg (source close) fails leaving double exposure ->
  `recover_target_first_source_close … dry_run=true` (inspect), then live-recover on approval to
  close the source leg.
- source_first nado target (step 1): if target-open fails after the source close leaving underhedge
  -> re-open the hedge on the target before anything else; never submit the second leg on a stale
  readback.
- After any failure: stop, re-run `migration:random_production_status` (fail closed on
  unknown/multi-venue/open-orders), and do not proceed to the next step.

**Step-1 watch-item:** `extended->nado` is a nado-target route, which the registry requires a
latency proof for. After step 1 confirm the status is specifically `READY_FOR_RANDOM` (not
`NOT_PRODUCTION_SAFE_LATENCY`); if the canary's double-exposure/underhedge exceeded thresholds it
lands in the latter and needs a repeat rather than a "stale" repair.

---

## 5b. Tests added / adjusted

- `test/services/migration_execution_preflight_test.rb` — new test
  **"requires all six enabled route proofs READY_FOR_RANDOM before restart"**: the restart preflight
  is clean only at 6/6 and raises both `all enabled route proofs must be READY_FOR_RANDOM` and
  `stale route proofs must be resolved` when any enabled route is missing/stale.
- Canary -> READY refresh is already covered by ~9 existing registry tests (live-canary / latency /
  recovery proofs).
- Fixed two more pre-existing 30-day time-bomb tests in the registry suite (hardcoded `2026-06-06`
  receipts crossed the TTL as real time advanced) -> made relative, preserving intent.
- Result: `migration_route_proof_registry_test` (30) + `migration_execution_preflight_test` (10) =
  **40 pass, 0 failures**; RuboCop clean.

---

## 6. Proof nothing live happened during planning / dry-run

- No runner started: `systemctl is-active delta-neutral-random-production-6.service` -> `inactive`;
  status `stopped`, `pid: None`, `duplicate_runner_process: false` (before and after).
- No live orders / signatures: all three dry-runs reported
  `orders_submitted=0, orders_placed=0, signatures_created=0`.
- No proof-state mutation: route proofs byte-identical before and after the dry-runs — still
  `completed=[extended->ethereal, ethereal->nado, nado->ethereal, nado->extended]`,
  `stale=[ethereal->extended, extended->nado]` (dry-runs write only to the unscanned
  `storage/hedge_migration_route_rehearsals` dir).
- No DB/env/secrets mutation, no web recreate. Only read-only status/proof commands and
  `dry_run=true` rehearsals were executed.
