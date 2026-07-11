# ethereal->nado Certification — PASSED; new stale-artifact blocker found (2026-07-11)

One supervised source-first canary, run with the operator-acknowledged
`MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true` interlock. Exactly one route, no
retries. Gates disarmed, ethereal auto restored. Runner never started.

## Result: the WATCH is CLEARED

- `final_status: SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK`
- **`route_production_safe: true`**, `route_latency_proof: true`, `latency_proof_status: passed`
- **`underhedge_seconds: 4.508 < 10`** (`MIGRATION_MAX_UNHEDGED_SECONDS` default)
- Route proof registry now: **all 6 routes READY_FOR_RANDOM with
  route_production_safe: true, latency passed, stale 0, missing 0.**
  ethereal->nado proof timestamp `2026-07-11T03:08:27Z`.

## Sequence and timings

- Pre-arm snapshot: all abort checks passed (venue ethereal 1.6878, others flat,
  orders zero, tolerance true, runner inactive, source_first, 6/6 proofs).
- Arm: `ok` — 3 migration + 2 nado DB gates armed; ethereal auto paused
  (prev true); nado auto already off. Post-arm readiness (with interlock):
  `ready: true`, `blockers: []`, `source_first_allowed: true`.
- Source close (Ethereal reduce-only 1.6878, order `46f7941f-...`): total 3.15s —
  build 1.51s, sign 0.05s, submit 0.80s, flat position readback 0.78s (1 poll).
- Underhedge window: source flat `03:08:33.433` → nado execution confirmed
  `03:08:37.942` = **4.508s**.
- Nado open (1.6894, digest `0x99535b3d...`): total 3.40s — build 0.28s,
  submit 0.31s, execution readback 2.76s (12 polls); canonical nado readback then
  finalized the route (total_route 33.81s; double_exposure "0" by source_first
  definition).
- Disarm: all 5 gates false; `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` restored
  `true`. Receipt: `storage/hedge_migration_live_canaries/20260711.jsonl`.

## Final production state

- Venue: **nado** holds `1.688` (fresh target ~1.6894); ethereal/extended flat
- Open orders zero on all venues; `inside_tolerance: true`; no unconfirmed readbacks
- Gates all false; runner `stopped`/systemd `inactive`; no duplicate process
- Autos: ethereal restored `true` (pre-arm value); nado auto now `true` — set by the
  **executor's finalization behavior** ("migration executor finalized production
  venue", audit-trailed 03:09:01Z), the same by-design mechanism that enabled
  extended's auto after yesterday's migration; extended auto now `false` (same
  finalization flow). Not gate-flow leakage.

## Route proof table

| route | status | production_safe | latency | proof ts |
|---|---|---|---|---|
| extended->ethereal | READY_FOR_RANDOM | true | passed | 2026-07-04 |
| ethereal->extended | READY_FOR_RANDOM | true | passed | 2026-07-10 |
| extended->nado | READY_FOR_RANDOM | true | passed | 2026-07-07 |
| nado->extended | READY_FOR_RANDOM | true | passed | 2026-07-04 |
| **ethereal->nado** | **READY_FOR_RANDOM** | **true** | **passed** | **2026-07-11** |
| nado->ethereal | READY_FOR_RANDOM | true | passed | 2026-06-11 |

## NEW blocker: runner restart readiness is now BLOCK (stale artifact, not live risk)

`random_production_status` now reports
`blockers: ["pending target=Nado migration continuation must be completed before burn-in"]`
and `current_direct_market_safe: false`. Diagnosis (read-only):

- The pending-continuation classifier scans all canary receipts and keys on the
  LATEST `TARGET_ACCEPTED_AWAITING_CONTINUATION` event — a **2026-06-05
  ethereal->nado artifact** (pending id `6684ae14249769e5`,
  `manual_action_required: true`), month-old and long since superseded.
- It was previously masked: the old 2026-07-04 proof's `final_readback_summary`
  contained `production_venue_finalized: true`, so
  `MigrationRouteProofRegistry#resolved_nado_target_continuation?` auto-resolved it.
- Today's fresh proof REPLACED that entry, and its summary is built from the
  runner's canary receipt — whose `from_executor_result` does **not** copy
  `production_venue_finalized` / `open_orders_clear_after` / `other_venues_flat`
  (the executor line has them; the runner line doesn't — the same
  receipt-surfacing gap class as yesterday's fix 4). `finalized_route_readback?`
  therefore fails, the registry no longer resolves the June artifact, and the
  classifier's fallback rejects it because the stale event itself carries
  `manual_action_required: true`.
- The live market state is demonstrably fine (one-leg normal on nado, verified
  above); the blocker is a bookkeeping regression, but it WOULD block a runner
  restart preflight.

**Fix paths (next step, not executed — deploy banned this turn):**
1. Code (preferred, matches fix-4 pattern): surface `production_venue_finalized`,
   `open_orders_clear_after`, `third_venue_flat`, `other_venues_flat` in
   `MigrationManualLiveCanaryRunner#from_executor_result`; test; deploy. The
   registry then auto-resolves the June artifact and the blocker clears without
   touching semantics.
2. Possibly the artifact's own recorded continuation path
   (`migration:continue_target_first_after_nado_confirmed position_id=6
   from=ethereal to=nado dry_run=true`) — an existing app reconciliation path;
   evaluate before running.

## Verdicts

- **ethereal->nado WATCH: CLEARED** — fresh READY_FOR_RANDOM +
  route_production_safe=true + latency passed; all six routes now fully green.
- **Runner restart readiness: BLOCK** (was PASS in this morning's audit) — solely
  due to the unmasked stale June-5 pending-continuation artifact described above.
  Not a live exposure issue; needs the small receipt fix (or app reconciliation)
  before restart.

## Confirmations

Exactly one route run (ethereal->nado, source_first), no retries, no other route,
no runner/scheduler start, no deploy/rebuild/push, no threshold/policy/order
changes; DB mutations were only arm/disarm + auto pause/restore (plus the
executor's own audited finalization auto-toggles). Gates false at end.
