# Position #6 — Step 1 Supervised Canary (extended → nado) — SUCCESS

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** ✅ Live source_first canary executed successfully. Production venue moved extended → nado,
`extended->nado` is now `READY_FOR_RANDOM` (5/6). Gates armed then disarmed. Runner never started.

Scope executed: **Step 1 only** (extended → nado, source_first). Steps 2 and 3 were **not** run.

---

## Flow executed (all via `docker compose -f docker-compose.prod.yml exec -T web`)

1. **Preflight (read-only)** — `random_production_status` + `rehearse_route … source_first dry_run=true`.
   All go/no-go conditions passed:
   runner stopped / pid null / duplicate=false · venue=extended · only active short=extended ·
   ethereal & nado flat · open orders zero · inside_tolerance=true · **source_first_supported=true** ·
   **expected_final_inside_tolerance=true**. Dry-run blockers were only the expected gate blockers.

2. **Arm DB gates** — `migration:arm_manual_canary_gates from=extended to=nado confirmation=I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY`
   → set 5 DB gates true: `MIGRATION_LIVE_ENABLED, MIGRATION_MANUAL_LIVE_CANARY_ENABLED,
   MIGRATION_FULL_ALLOWED, AERODROME_NADO_HEDGE_LIVE_ENABLED, AERODROME_NADO_LIVE_MIGRATION_ENABLED`.

3. **Live canary** — `env EXTENDED_LIVE_ENABLED=true EXTENDED_MAINNET_PROBE_ENABLED=true
   MIGRATION_SOURCE_FIRST_CANARY_ALLOWED=true migration:run_manual_live_canary position_id=6
   from=extended to=nado sequence=source_first confirmation=I_UNDERSTAND_THIS_RUNS_A_LIVE_HEDGE_MIGRATION_CANARY`.
   Executed in the same shell invocation as the disarm so gates could not be left enabled.

4. **Disarm (unconditional)** — `migration:disarm_manual_canary_gates` → all 5 DB gates back to false.

5. **Post-verify (read-only)** — `route_proofs` + `random_production_status`.

---

## Canary execution (real live migration)

```
action:            manual_live_canary
route:             extended->nado
sequence:          source_first
final_status:      SOURCE_FIRST_FINALIZED_BY_CANONICAL_NADO_READBACK
orders_submitted:  2
orders_placed:     2
signatures_created:2
source_flat_after: True
target_holds_expected_short: True
final_inside_tolerance: True
open_orders_after: 0
route_latency_proof:    True
route_production_safe:  True
double_exposure_seconds:0
underhedge_seconds:     4.929382
blockers:          none
```

Note: the receipt also carried residual plan fields `submitted:false / dry_run:true`. Those are
misleading leftovers from the merged canary plan; the order/signature counts, the finalized status,
the measured latency, and the actual on-venue state change are authoritative — the migration ran live.

---

## Result vs. expected

| Expected | Actual | OK |
|---|---|---|
| production venue → nado | nado | ✅ |
| extended short → 0 | 0.0 | ✅ |
| nado short ≈ fresh target | 1.757 | ✅ |
| ethereal flat | 0.0 | ✅ |
| open orders zero | zero on all venues | ✅ |
| inside_tolerance true | True | ✅ |
| extended->nado READY_FOR_RANDOM | READY_FOR_RANDOM (ts 2026-07-07T08:30:56Z) | ✅ |
| route proofs 5/6 READY | 5/6 | ✅ |

Post-canary status: `current_direct_market_safe=True`, `active_short_venues=["nado"]`,
`direct_venue_shorts = {nado:1.757, ethereal:0.0, extended:0.0}`, runner `stopped` / pid None /
duplicate=false.

Route proofs now:
```
extended->ethereal   READY_FOR_RANDOM   production_random_cycle  2026-07-04
ethereal->extended   STALE                                       2026-06-05   <-- only remaining (Step 3)
extended->nado       READY_FOR_RANDOM   manual live canary       2026-07-07   <-- refreshed this step
nado->extended       READY_FOR_RANDOM   production_random_cycle  2026-07-04
ethereal->nado       READY_FOR_RANDOM   production_random_cycle  2026-07-04
nado->ethereal       READY_FOR_RANDOM   production_random_cycle  2026-06-11
completed: 5/6   stale: [ethereal->extended]
```

---

## Safety confirmation
- Runner **not** started/restarted — systemd `delta-neutral-random-production-6.service` = `inactive`.
- Gates **disarmed** — all five DB gates back to `false` (verified twice: disarm output + independent
  `manual_canary_gate_status`). Disarm ran unconditionally right after the live attempt.
- Only DB mutation was arm/disarm of the manual-canary gates for this one route (as approved).
- Step 2 and Step 3 **not** run. No other DB/env/secrets mutation. No web recreate.
- `ethereal->extended` correctly still stale — the strict registry did not fabricate it.
- Full 113-field canary receipt saved at `/tmp/step1_canary_v2.out`.

---

## Remaining to reach 6/6 (needs separate explicit approval — not done)
- Only `ethereal->extended` remains stale. Production venue is now **nado**.
- Reaching Ethereal requires one reposition (`nado->ethereal`, already READY, target_first), then the
  `ethereal->extended` proof (target_first) which lands back on Extended.
- Any further live step is gated on explicit per-step approval and the same arm → canary → disarm flow.
