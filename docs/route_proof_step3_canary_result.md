# Position #6 — Step 3 Supervised Canary (ethereal → extended) — EXECUTED, proof NOT certified

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** Live target_first migration executed and repositioned the hedge to Extended safely, but the
route proof was **not** certified (double-exposure exceeded the safety budget). Route proofs remain
**5/6**, not 6/6. Gates disarmed, ethereal source-auto restored, runner inactive.

Scope executed: **Step 3 only** (ethereal → extended, target_first). No further route run.

---

## Flow executed (all via `docker compose -f docker-compose.prod.yml exec -T web`)

1. Read-only status + gate status + dry-run — all go/no-go conditions passed; `source_auto` showed
   `AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED` enabled (`would_pause=true`); before-arm dry-run
   correctly flagged the ethereal auto blocker.
2. Arm — 3 base DB gates armed AND ethereal source-auto paused (`previous_value="true"`).
3. Verify after arm — source auto `false`, `restore_pending=true`; DB gates true.
4. Dry-run after arm — `ready_no_live`, `source_target_auto_blockers=[]`, blockers NONE.
5. Live canary — `env EXTENDED_LIVE_ENABLED=true EXTENDED_MAINNET_PROBE_ENABLED=true
   run_manual_live_canary … from=ethereal to=extended sequence=target_first`.
6. Disarm + restore (unconditional) — gates false; ethereal auto restored to `true`.
7. Post-verify (read-only) — status, route_proofs, gate status, systemd.

---

## Canary execution (real live migration)

```
route:             ethereal->extended
sequence:          target_first
final_status:      LIVE_CANARY_CONFIRMED
orders_submitted:  1
orders_placed:     1
signatures_created:1
target_leg_readback_confirmed: True
source_leg_readback_confirmed: True
source_flat_after: True
target_holds_expected_short: True
final_inside_tolerance: True
open_orders_after: 0
double_exposure_seconds: 37.163131     <-- exceeded the production-safe budget
route_production_safe:   False
production_safe_route:   False
```

---

## Why the proof was NOT certified

`ethereal->extended` is `target_first` by policy, which opens Extended (target) BEFORE closing
Ethereal (source), so the position was OVERHEDGED for ~37 seconds. The route-proof registry's
production-safe budget is `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS = 5s` (default). 37.16s >> 5s, so
`route_production_safe=false`, and `live_canary_proof?` refuses to certify it. The route keeps its old
(stale) June-5 proof.

This is the safety system working as designed: a migration that double-exposed for 37s is not a
production-safe route proof, even though it finished inside tolerance. (Contrast Step 1
`extended->nado` source_first: `double_exposure=0`, `underhedge=4.93s` -> production-safe -> READY.)

---

## Actual outcome vs. expected

| Expected | Actual | OK |
|---|---|---|
| production venue extended | extended | ✅ |
| ethereal short 0 | 0.0 | ✅ |
| extended short ≈ fresh target | 1.669 | ✅ |
| nado flat | 0.0 | ✅ |
| open orders zero | zero on all | ✅ |
| inside_tolerance true | True | ✅ |
| ethereal->extended READY_FOR_RANDOM | STALE | ❌ |
| route proofs 6/6 | 5/6 | ❌ |
| manual canary gates false | all false | ✅ |
| ethereal source auto restored | restored to true | ✅ |
| runner inactive | inactive | ✅ |

Final state: `current_direct_market_safe=True`, `active_short_venues=["extended"]`,
`direct_venue_shorts={nado:0.0, ethereal:0.0, extended:1.669}`, open orders zero, inside tolerance.
A transient ~37s overhedge occurred during the migration; the final state is delta-neutral.

Route proofs now:
```
extended->ethereal   READY_FOR_RANDOM   production_random_cycle
ethereal->extended   STALE              (June-5 proof; this canary not certified: 37s double-exposure)
extended->nado       READY_FOR_RANDOM   manual live canary (Step 1)
nado->extended       READY_FOR_RANDOM   production_random_cycle
ethereal->nado       READY_FOR_RANDOM   production_random_cycle
nado->ethereal       READY_FOR_RANDOM   production_random_cycle
completed: 5/6   stale: [ethereal->extended]
```

---

## Safety confirmation
- Runner NOT started/restarted — systemd `delta-neutral-random-production-6.service` = `inactive`.
- Gates all false; ethereal source-auto restored to prior value `true`
  (`restored_source_auto.restored=true`, `restore_pending=false`) — verified independently.
- DB mutations limited to arm/disarm manual-canary gates + scoped ethereal source-auto pause/restore.
- No additional route run after Step 3; disarm+restore ran unconditionally in the same invocation as
  the live canary. No web recreate.
- Full canary receipt saved at `/tmp/step3_canary.out`.

---

## Options to reach 6/6 for ethereal->extended (needs explicit approval — not done)
1. Retry the target_first canary hoping for a sub-5s double-exposure window — may keep failing if
   Extended opens are consistently slow.
2. Prove it source_first (close Ethereal first -> underhedge instead of overhedge, like Step 1) — but
   the route policy for ethereal->extended is target_first, so this diverges from policy and needs a
   decision.
3. Let the production runner earn it via a production_random_cycle (how the other 4 READY routes were
   certified) — but the runner is currently stopped.
4. Adjust MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS — NOT recommended (weakens the safety budget).

Recommended next read-only step (if approved): investigate why the target_first Extended-open leg took
~37s (timing breakdown in the receipt) before deciding between options 1–3.
