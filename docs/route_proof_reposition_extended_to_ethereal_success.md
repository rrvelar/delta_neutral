# Position #6 — Reposition extended -> ethereal (target_first) — SUCCESS

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** ✅ Live target_first reposition moved production venue Extended -> Ethereal using the
both-venue (source + target) auto pause/restore. Gates disarmed, ethereal target auto restored, runner
inactive. `ethereal->extended` NOT run.

Scope executed: reposition only (extended -> ethereal, target_first). The final proof
`ethereal->extended` was NOT run in this approval.

---

## Why this run needed the new mechanism
`extended->ethereal` migrates INTO ethereal, whose auto-rebalance was enabled
(`AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED=true`). The canary blocks on
`target venue auto must be disabled during migration canary: ethereal`. The prior source-only pause
could not clear a TARGET-venue auto. The updated arm/disarm pauses/restores BOTH source and target
venue autos, which cleared it.

## Flow (all via docker compose ... exec -T web)
1. Read-only status + gate status + dry-run — safe; gate status confirmed `target_auto` deployed
   (ethereal, would_pause=true).
2. Arm — 3 base DB gates armed; ethereal target auto paused (`previous_value="true"`); extended source
   auto untouched (already false).
3. Verify after arm — target auto false, restore_pending=true; DB gates true.
4. Dry-run after arm — `ready_no_live`, `source_target_auto_blockers=[]`, blockers NONE.
5. Live canary — `env AERODROME_ETHEREAL_HEDGE_LIVE_ENABLED=true run_manual_live_canary ...
   from=extended to=ethereal sequence=target_first` (same shell invocation as disarm).
6. Disarm + restore (unconditional) — gates false; ethereal target auto restored to true.
7. Post-verify (read-only) — status, route_proofs, gate status, systemd.

## Canary execution (real live migration)
```
route:             extended->ethereal
sequence:          target_first
final_status:      LIVE_CANARY_CONFIRMED
orders_submitted:  1
signatures_created:1
source_flat_after: True
target_holds_expected_short: True
final_inside_tolerance: True
open_orders_after: 0
blockers:          none
```

## Result vs. expected
| Expected | Actual | OK |
|---|---|---|
| production venue ethereal | ethereal | ✅ |
| extended short 0 | 0.0 | ✅ |
| ethereal short ~ fresh target | 1.7155 | ✅ |
| nado flat | 0.0 | ✅ |
| open orders zero | zero on all | ✅ |
| inside_tolerance true | True | ✅ |
| source & target autos restored | source false (unchanged), target true (restored) | ✅ |
| gates false | all false | ✅ |
| route proofs >= 5/6 | 5/6 | ✅ |
| ethereal->extended still stale | STALE | ✅ |
| runner inactive | inactive | ✅ |

Post state: `current_direct_market_safe=True`, `active_short_venues=["ethereal"]`,
`direct_venue_shorts={nado:0.0, ethereal:1.7155, extended:0.0}`, runner stopped / pid None / duplicate=false.

Route proofs now: completed 5/6 = [extended->ethereal, extended->nado, nado->extended, ethereal->nado,
nado->ethereal]; stale = [ethereal->extended].

## The both-venue auto pause/restore worked
- Arm paused ethereal (target) auto true -> false, recorded previous_value "true"; after-arm dry-run
  then had `source_target_auto_blockers=[]`.
- Disarm restored ethereal auto to true (`restored_autos: [AERODROME_ETHEREAL_AUTO_REBALANCE_ENABLED]`)
  and cleared restore state; independent gate status confirms target_auto currently_enabled=true,
  restore_pending=false, all db_gates false.

## Safety confirmation
- Runner NOT started/restarted — systemd `delta-neutral-random-production-6.service` = inactive; runner
  not run.
- Gates all false; both autos restored (source false unchanged, target ethereal true) — verified
  independently.
- DB mutations limited to arm/disarm manual-canary gates + scoped source/target auto pause/restore.
- `ethereal->extended` NOT run. No web recreate. Disarm+restore ran unconditionally after the live canary.
- Full canary receipt saved at `/tmp/reposition_canary.out`.

## Next (needs separate explicit approval)
Production venue is now ethereal, so `ethereal->extended` (the last stale route) can be retried with
`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true`. Ethereal is now the SOURCE, so its auto will be paused
by the source-auto path. This step is NOT approved yet.
