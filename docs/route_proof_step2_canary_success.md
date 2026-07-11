# Position #6 — Step 2 Supervised Canary (nado → ethereal) — SUCCESS

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** ✅ Live target_first reposition executed via the updated gate flow with source-auto
pause/restore. Production venue moved nado → ethereal. Gates disarmed, source auto restored. Runner
never started.

Scope executed: **Step 2 only** (nado → ethereal, target_first). Step 3 not run.

---

## Flow executed (all via `docker compose -f docker-compose.prod.yml exec -T web`)

1. **Read-only status + gate status** — confirmed safe state and that the auto-pause code is now
   deployed (`source_auto` present, `would_pause=true`).
2. **Arm** — `arm_manual_canary_gates from=nado to=ethereal confirmation=I_UNDERSTAND_THIS_ARMS_ONE_MANUAL_CANARY`:
   armed 5 DB gates AND paused source auto `AERODROME_NADO_AUTO_REBALANCE_ENABLED`
   (`previous_value="true"` recorded).
3. **Verify after arm** — source auto `currently_enabled=false`, `restore_pending=true`; all 5 DB gates true.
4. **Dry-run after arm** — `rehearsal_status=ready_no_live`, `source_target_auto_blockers=[]`,
   all blockers empty, `target_first_supported=true`, `expected_final_inside_tolerance=true`.
5. **Live canary** — `env AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true migration:run_manual_live_canary
   position_id=6 from=nado to=ethereal sequence=target_first confirmation=...`. Run in the same shell
   invocation as disarm so gates/auto could not be left changed.
6. **Disarm + restore (unconditional)** — all 5 gates → false and source auto restored to `true`.
7. **Post-verify (read-only)** — status, route_proofs, gate status, systemd.

---

## Canary execution (real live migration)

```
route:             nado->ethereal
sequence:          target_first
final_status:      LIVE_CANARY_CONFIRMED
orders_submitted:  1
orders_placed:     1
signatures_created:1
source_flat_after: True
target_holds_expected_short: True
final_inside_tolerance: True
open_orders_after: 0
blockers:          none
```

---

## Result vs. expected

| Expected | Actual | OK |
|---|---|---|
| production venue → ethereal | ethereal | ✅ |
| nado short 0 | 0.0 | ✅ |
| ethereal short ≈ fresh target | 1.7675 | ✅ |
| extended flat | 0.0 | ✅ |
| open orders zero | zero on all venues | ✅ |
| inside_tolerance true | True | ✅ |
| source auto restored to prior value true | currently_enabled=true, restore_pending=false | ✅ |
| manual canary gates false | all false | ✅ |
| route proofs ≥ 5/6 | 5/6 | ✅ |
| ethereal->extended still stale | STALE | ✅ |

Post state: `current_direct_market_safe=True`, `active_short_venues=["ethereal"]`,
`direct_venue_shorts={nado:0.0, ethereal:1.7675, extended:0.0}`, runner stopped / pid None / duplicate=false.

Route proofs now:
```
extended->ethereal   READY_FOR_RANDOM   production_random_cycle
ethereal->extended   STALE                                        <-- only remaining (Step 3)
extended->nado       READY_FOR_RANDOM   manual live canary (Step 1)
nado->extended       READY_FOR_RANDOM   production_random_cycle
ethereal->nado       READY_FOR_RANDOM   production_random_cycle
nado->ethereal       READY_FOR_RANDOM   manual live canary (Step 2, refreshed)
completed: 5/6   stale: [ethereal->extended]
```

---

## The source-auto pause/restore mechanism worked as designed
- Before: `AERODROME_NADO_AUTO_REBALANCE_ENABLED=true` (this was the Step 2 blocker).
- Arm paused it to false and recorded `previous_value="true"`; the after-arm dry-run then had
  `source_target_auto_blockers=[]`.
- Disarm restored it to `true` and cleared the pause record; independent `manual_canary_gate_status`
  confirms `currently_enabled=true`, `restore_pending=false`.

---

## Safety confirmation
- Runner NOT started/restarted — systemd `delta-neutral-random-production-6.service` = `inactive`.
- Gates disarmed (all five false) AND source auto restored to prior value `true` — verified independently.
- DB mutations limited to arm/disarm manual-canary gates + scoped source-auto pause/restore (as authorized).
- Step 3 NOT run. No live orders beyond the single approved canary. No web recreate.
- `ethereal->extended` correctly still stale — not fabricated.
- Disarm+restore ran unconditionally in the same invocation as the live canary.
- Full canary receipt saved at `/tmp/step2_canary.out`.

---

## Remaining to reach 6/6 (needs separate explicit approval — not done)
- Only `ethereal->extended` is stale. Production venue is now **ethereal** (its source), so Step 3
  (`ethereal->extended`, target_first) can run directly and would land back on Extended.
- Ethereal auto-rebalance is currently `false`, so no source-auto pause is expected — to be confirmed
  at Step 3 preflight if approved.
