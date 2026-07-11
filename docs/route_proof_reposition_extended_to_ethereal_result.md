# Reposition canary result: extended->ethereal target_first (Position #6)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Outcome:** Reposition **PURPOSE achieved** (venue Extended → Ethereal), clean teardown. Route did **not**
certify (latency). Fast-fill evidence **not observable** in the curated receipt.

## Purpose (approved)
One supervised extended->ethereal target_first canary to move production venue Extended → Ethereal, so a
later separate approval can retry the final stale route ethereal->extended. `EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED=true`,
`ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true`.

## Preflight + arm (both gated strictly)
- Preflight PASSED all conditions: runner inactive, venue extended, only-active-short extended,
  ethereal/nado flat, open orders zero, inside_tolerance true (drift 0.0038 ≪ tol 0.0561, **tolerance
  breach resolved**), target_first_supported true, expected_final_inside_tolerance true; remaining blockers
  = 3 MIGRATION gates + ethereal target auto (would_pause true).
- **Both-venue gates worked:** arm paused the **ethereal target auto** (`previous_value "true"`), source
  extended auto already-off; post-arm dry-run `ready_no_live`, `ready_for_supervised_canary: true`, all
  blocker arrays empty.

## Live canary
- `final_status: LIVE_CANARY_CONFIRMED`; target (ethereal open) + source (extended close) both confirmed;
  `source_flat_after: true`, `target_holds_expected_short: true`, `final_inside_tolerance: true`,
  `open_orders_after: 0`. Order ids: ethereal `7381c1a2-…`, extended `2074936830431141888`.
- **Venue moved to Ethereal.** ethereal short 1.8703 (≈ fresh target 1.870336), extended 0, nado flat.

### Latency — NOT certified
- `double_exposure_seconds: 39.727257` (19:20:28.26 → 19:21:07.99) — **> 5**.
- `LATENCY_THRESHOLD_EXCEEDED: source_close_total_latency_seconds 37.640276s > 15.0s`
- `LATENCY_THRESHOLD_EXCEEDED: total_migration_latency_seconds 51.017808s > 45.0s`
- `route_production_safe: false`.
- The Ethereal target-open likely confirmed fast (window start is early, at the ethereal fill). The
  **Extended source close took ~37.6s** — consistent with the SLOW position readback, NOT the intended ~2s
  order-by-id fast-fill. So the **Extended fast-fill did not deliver its speedup** on this run.

## Cannot confirm WHY (diagnostics gap)
The persisted manual-canary receipt is curated and **contains none** of the fill-confirmation fields
(`extended_order_by_id_fill`, `authoritative_fill`, `double_exposure_start_source` /
`double_exposure_end_source`, `source_close_confirmation_source`, `*_fill_readback_agreement`). No separate
detailed executor receipt exists. So it is **not observable** whether the Extended fast-fill (a) never
engaged (inline-flag propagation to `ExtendedMainnetLifecycleCheck#close_fill_confirmation_enabled?`), or
(b) engaged but fell back to the slow position readback (Extended API read latency / order-status lag). This
is exactly the "per-leg receipt diagnostics" item recommended earlier but **not yet implemented**.

## Post-canary state — clean & safe (verified)
- Gates MIGRATION_LIVE/MANUAL/FULL all **false**.
- **Ethereal target auto restored to `true`** (disarm `restored_autos` = ethereal); `restore_pending: false`
  on both source and target. **No autos left paused, no gates enabled.**
- venue **ethereal** (1.8703), extended 0, nado 0, open orders zero, inside_tolerance true.
- Route proofs **5/6** — `extended->ethereal` **still READY_FOR_RANDOM** (via production_random_cycle; the
  latency-failed canary did NOT downgrade it); `ethereal->extended` still STALE. **No regression.**
- Runner **inactive**.

## Expected vs actual
| expected | actual |
|---|---|
| production venue ethereal | ✅ ethereal |
| ethereal holds target / extended 0 / nado flat | ✅ 1.8703 / 0 / 0 |
| open orders zero / inside_tolerance true | ✅ / ✅ |
| gates false / ethereal auto restored true / pending_restore false | ✅ / ✅ / ✅ |
| runner inactive / route proofs 5/6 (already READY) | ✅ / ✅ |
| target_open_confirmation_source = ethereal_order_list_open_fill | ❌ not surfaced in receipt |
| source_close_confirmation_source = extended_order_by_id_fill | ❌ not surfaced (and latency implies slow readback) |
| double_exposure_*_source = authoritative_fill | ❌ not surfaced |
| *_fill_readback_agreement = true | ❌ not surfaced |
| double_exposure_seconds ≤ 5 | ❌ 39.73 |

## Critical implication for the final goal (ethereal->extended retry)
`ethereal->extended` has **Extended as the target open**. If the Extended fast-fill did not deliver here (as
a source close), it will likely also fail for the Extended target open → `target_total_latency > 15s` →
`ethereal->extended` won't certify. **Before any ethereal->extended retry, diagnose the Extended fast-fill**
(read-only): (1) confirm the inline flag reaches `ExtendedMainnetLifecycleCheck`; (2) confirm a just-closed
Extended order is returned FILLED fast by `order_by_id`; and/or (3) surface the per-leg confirmation-source +
timing in the manual-canary receipt so the path is observable. Do NOT retry ethereal->extended until this is
understood.

## Safety confirmation
Exactly one supervised canary. Runner never started (inactive throughout). Gates disarmed, ethereal target
auto restored. No second route, no ethereal->extended, no runner/scheduler, no rebuild/deploy/push, no
threshold/route-policy change. DB mutations limited to arm/disarm gates + ethereal target-auto pause/restore.
Position healthy and hedged on Ethereal (1.8703, inside tolerance).
