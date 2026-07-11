# Position #6 — Final proof retry ethereal->extended (fast close confirmation) — still STALE

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-07
**Outcome:** Live target_first `ethereal->extended` executed and returned production venue to Extended
safely, but was NOT certified: `double_exposure_seconds=37.99 > 5`. Route proofs remain **5/6**;
`ethereal->extended` still STALE. Gates disarmed, ethereal source auto restored, runner inactive.

Scope executed: this proof retry only. No route run after. Runner not started.

---

## Root cause: the fast fill fix is in the wrong layer

- `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true` was passed inline. The migration ran, but the
  double-exposure window (`21:32:49 -> 21:33:27`, ~38s) is unchanged from the prior attempt (~37s).
- The receipt shows NO `order_fill` evidence. The window *ends* at `source_close_flat_confirmed_at`,
  which is set by the EXECUTOR's `final_readback_status` (a position readback at the executor level,
  `hedge_venue_migration_executor.rb:126-127`) — NOT by the Ethereal service leg readback where the
  fast fill confirmation was added. So the executor still waits ~38s for the lagging Ethereal position
  endpoint to read flat, regardless of the service-layer fast path.
- Therefore the service-layer fast close confirmation cannot shrink the measured double-exposure
  without changing executor semantics (trusting the leg's authoritative fill for source-flat).

## Canary execution (real live migration)
```
route:             ethereal->extended
sequence:          target_first
final_status:      LIVE_CANARY_CONFIRMED
orders_submitted:  1
signatures_created:1
source_flat_after: True
target_holds_expected_short: True
final_inside_tolerance: True
open_orders_after: 0
double_exposure_seconds: 37.990098
route_production_safe:   False
```

## Outcome vs. expected
| Expected | Actual | OK |
|---|---|---|
| production venue extended | extended | ✅ |
| ethereal short 0 | 0.0 | ✅ |
| extended short ~ fresh target | 1.748 | ✅ |
| nado flat | 0.0 | ✅ |
| open orders zero | zero on all | ✅ |
| inside_tolerance true | True | ✅ |
| ethereal->extended READY_FOR_RANDOM | STALE | ❌ |
| route proofs 6/6 | 5/6 | ❌ |
| gates false | all false | ✅ |
| source/target autos restored | ethereal auto -> true, restore_pending false | ✅ |
| runner inactive | inactive | ✅ |

Post state: `current_direct_market_safe=True`, `active_short_venues=["extended"]`,
`direct_venue_shorts={nado:0.0, ethereal:0.0, extended:1.748}`, `restart_blocked_by_route_proofs=True`,
runner stopped / pid None / duplicate=false. Route proofs: completed 5/6; stale [ethereal->extended].

Net effect of the last two approvals (reposition extended->ethereal, then this proof retry): a
round-trip extended->ethereal->extended (two live migrations), safely back on Extended, but no new
proof earned — `ethereal->extended` target_first inherently overhedges ~38s.

## Both-venue auto pause/restore worked again
Arm paused ethereal (source) auto true -> false (`previous_value="true"`); after-arm dry-run had
`source_target_auto_blockers=[]`; disarm restored ethereal auto to true and cleared restore state
(verified independently: source_auto currently_enabled=true, restore_pending=false, db_gates all false).

## Safety confirmation
- Runner NOT started/restarted — systemd inactive; production runner not run.
- Gates all false; ethereal source auto restored to true.
- DB mutations limited to arm/disarm gates + scoped source/target auto pause/restore.
  `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` untouched.
- No route run after this. Disarm+restore ran unconditionally after the live canary.
- Full canary receipt saved at `/tmp/final_proof_canary.out`.

## Options to actually certify ethereal->extended (need explicit approval — none taken)
1. Make the EXECUTOR's `source_close_flat_confirmed_at` trust the leg's authoritative fill confirmation
   (order FILLED for >= close size) instead of an independent position poll — a change to
   `hedge_venue_migration_executor.rb` (execution semantics; previously off-limits).
2. Prove `ethereal->extended` source_first — close Ethereal first so the risky window becomes
   Extended-open underhedge (10s budget vs 5s); diverges from the target_first route policy.
3. Let the production runner certify it via production_random_cycle — needs the runner and uses
   target_first (same ~38s issue), so ineffective without option 1.
4. NOT recommended: weakening MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS.
