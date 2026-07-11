# ethereal->extended canary (post build-read consolidation): venue moved, latency fixed on Extended, still not 6/6

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-09
**Outcome:** One supervised ethereal->extended target_first canary. Migration **finalized safely** (venue →
extended). The Extended build-read consolidation **worked** (target latency 64.8s → 8.16s). But
**double_exposure 15.35s > 5s** → route not certified; a NEW bottleneck (the Ethereal source-close leg build
+ the target-confirm→source-submit gap) is now the limiter. Route proofs remain **5/6**.

## Pre-arm snapshot (all gates passed)
venue ethereal, ethereal 1.8703, extended/nado flat, open orders zero, inside_tolerance true (drift
−0.0117 ≪ tol 0.0558), runner inactive, 5/6, ethereal->extended STALE, sequence target_first, all blockers
arm-clearable.

## Arm + post-arm dry-run
- Arm: set MIGRATION_LIVE/MANUAL_LIVE_CANARY/FULL_ALLOWED = true; **paused ethereal source auto**
  (`previous_value "true"`); extended target auto already off.
- Post-arm dry-run: `rehearsal_status: ready_no_live`, `ready_for_supervised_canary: true`, all blocker
  arrays empty.

## Live canary receipt
`storage/hedge_migration_live_canaries/20260709.jsonl` · `final_status: LIVE_CANARY_CONFIRMED`
Order ids: extended open `2075076602277453824`, ethereal close `78696b97-9284-42a2-86b9-2ce6ce078cc4`.

### Per-leg timing (observability b91e6aa surfaced these)
| leg | total | build | submit | readback | slow_step |
|---|---|---|---|---|---|
| target open (extended) | **8.157s** | **3.133s** | 0.975s | 0.962s | build |
| source close (ethereal) | 9.221s | **5.317s** | 0.754s | 3.085s | build |

### Latency / fill diagnostics
| field | value | vs threshold |
|---|---|---|
| **target_total_latency_seconds** | **8.157** | **< 15 ✓** (was 64.8s pre-consolidation) |
| total_migration_latency_seconds | 24.551 | < 45 ✓ (was 85s) |
| **double_exposure_seconds** | **15.350** | **> 5 ✗** |
| double_exposure_start_source | authoritative_fill | ✓ |
| double_exposure_end_source | authoritative_fill | ✓ |
| target_open_confirmation_source | **extended_order_by_id_fill** | ✓ Extended fast-fill worked |
| source_close_confirmation_source | **ethereal_order_list_fill** | ✓ Ethereal fast-fill worked |
| target_open_fill_readback_agreement | true | ✓ |
| source_close_fill_readback_agreement | true | ✓ |
| route_production_safe | **false** | double_exposure > 5s |

## What the diagnostics prove
- **The Extended build-read consolidation delivered.** The extended TARGET open leg build dropped from
  ~34s to **3.13s**; `target_total_latency` 64.8s → **8.16s** (< 15s); `total_migration` 85s → 24.55s.
- **Both fast-fills authoritative** (extended order-by-id + ethereal order-list), agreements true, window
  bounded by real fills.
- **Why double_exposure is still 15.35s** (window = extended-open-fill 04:36:30.79 → ethereal-close-fill
  04:36:46.14): (a) ~3s between the extended open authoritative fill and the source-close submit (the target
  leg still finishes its position readback before the source close is submitted:
  target_open_position_readback_confirmed_at = 04:36:33.79), then (b) the **Ethereal source-close leg ~9s**
  (build **5.317s** + submit 0.75 + fill readback 3.09). The consolidation was Extended-only; the Ethereal
  build is now the dominant cost.

## Final production state (verified)
| item | value |
|---|---|
| venue | **extended** |
| direct shorts | extended **1.857**, ethereal 0.0, nado 0.0 |
| open orders | zero (all) |
| inside_tolerance | true |
| DB gates | MIGRATION_LIVE/MANUAL/FULL all **false** |
| ethereal source auto | **restored true**, `pending_restore=false` |
| extended target auto | false (unchanged) |
| runner | **stopped / inactive** |
| route proofs | **5/6**; `ethereal->extended` STALL (proof_timestamp 2026-06-05, unchanged — the latency-failed canary did not certify or downgrade it) |

## Not 6/6 — reason
`double_exposure_seconds 15.35 > MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS (5)` ⇒ `route_production_safe: false`
⇒ the canary does not certify `ethereal->extended`. It stays STALE; proofs remain 5/6.

## Next lever (for a future, separately-approved change)
Reduce `double_exposure` under 5s by attacking the two remaining components (both now observable):
1. **Ethereal source-close leg build (~5.3s):** apply the same read-consolidation pattern to the Ethereal
   execution service's pre-submit build.
2. **Target-confirm → source-submit gap (~3s):** submit the source close immediately after the target
   authoritative FILL rather than after the target position readback (fail-closed on partial/ambiguous).
Neither changes thresholds, route policy, or order construction. Extended-side latency is already solved.

## Confirmation of teardown
Gates disarmed (all false). Ethereal source auto **restored to true**, no pending restore. Extended target
auto left false (as before). Runner inactive. Exactly one route run (ethereal->extended); no retries, no
loop, no runner/scheduler, no other route, no deploy/rebuild/push, no threshold/route-policy/order-
construction change. DB mutations limited to the intended arm/disarm gate + ethereal source-auto
pause/restore. Position healthy and hedged on Extended (1.857, inside tolerance).
