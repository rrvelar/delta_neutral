# Final-proof canary result: ethereal->extended (target_first) — finalized safely, NOT certified

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Operation:** User-approved single supervised live canary — final proof retry for the last stale route
(`ethereal->extended`, target_first, Position #6). Runner untouched (inactive throughout).

## Verdict
The live migration **executed and finalized safely** (venue moved ethereal → extended, position healthy),
but the route proof **did NOT certify**: the Extended target-open leg took ~64.8s to confirm, failing the
production latency thresholds. `ethereal->extended` remains **STALE**; route proofs stay **5/6**.

---

## Deployment verified before going live (read-only)
- Running web image `03b4b0d237dd` **Created 2026-07-08 06:01:33**, ~1.5 min after HEAD commit `79a7138`
  ("Use authoritative Ethereal target open fill in executor") at **05:59:59**.
- Committed HEAD contains both `apply_authoritative_source_close_confirmation!` and
  `apply_authoritative_target_open_confirmation!`; working tree clean.
- ⇒ Both executor fixes are genuinely deployed in the running image.

## Pre-flight gating (all passed)
- runner stopped, `pid: null`, `duplicate_runner_process: false`
- current venue **ethereal**; only active short venue ethereal (1.8054); extended & nado flat (fresh read,
  `exposure_stale: false`); open orders zero
- `inside_tolerance: true` (drift 0.0086 within tolerance 0.0544)
- `target_first_supported: true`, `source_first_supported: false`
- `expected_final_inside_tolerance: true`
- `ethereal->extended` the only stale route
- Dashboard note: the `random_production_status` snapshot showed an Extended read timeout ("retained as
  stale diagnostic only"); the `rehearse_route` execution path read Extended fresh (0.0, not stale), so it
  was a dashboard-path artifact, not an execution blocker.

## Arm → verify → live
- `arm_manual_canary_gates` set MIGRATION_LIVE_ENABLED / MIGRATION_MANUAL_LIVE_CANARY_ENABLED /
  MIGRATION_FULL_ALLOWED = true and **paused ethereal source auto** (previous_value true). Extended target
  auto already false.
- Post-arm dry-run: `rehearsal_status: "ready_no_live"`, `ready_for_supervised_canary: true`, all blocker
  arrays empty.
- Live canary run with `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true EXTENDED_LIVE_ENABLED=true
  EXTENDED_MAINNET_PROBE_ENABLED=true`. Disarm chained unconditionally (`;`).

## Canary receipt (storage/hedge_migration_live_canaries/20260708.jsonl)
| field | value |
|---|---|
| final_status | `LIVE_CANARY_CONFIRMED` |
| target_leg_status | `TARGET_SUBMITTED_AND_CONFIRMED` (extended open, order `2074738406414946304`) |
| source_leg_status | `SOURCE_CLOSE_CONFIRMED` (ethereal close, order `ba6e01c0-…`) |
| source_flat_after / target_holds_expected_short | true / true |
| final_inside_tolerance / open_orders_after | true / 0 |
| **double_exposure_seconds** | **13.141488** (06:12:58.87 → 06:13:12.01) — **> 5s** |
| total_route_seconds | 85.21167 |
| **route_production_safe / production_safe_route** | **false / false** |
| warning | `LATENCY_THRESHOLD_EXCEEDED: target_total_latency_seconds 64.831736s > 15.0s` |
| warning | `LATENCY_THRESHOLD_EXCEEDED: total_migration_latency_seconds 85.21167s > 45.0s` |
| warning | "Route finalized safely but latency thresholds failed for production random; route must be re-proven with acceptable latency." |

## Root cause — bottleneck moved to the Extended target-open leg
- The deployed **source-close** authoritative-fill fix worked: measured double-exposure dropped from the
  prior ~37–40s to ~13s.
- But this route's **target is Extended**, and the **Extended open leg took ~64.8s to confirm** its
  readback → fails `target_total_latency > 15s` → `route_production_safe = false` regardless of the
  double-exposure value.
- The **target-open fill fix is Ethereal-only** (it reads the Ethereal order-list fill). Extended has no
  equivalent fast-open-fill path wired here, so the Extended open still blocks on its slow readback.
- Measurement note: `double_exposure_started_at` is stamped only after that ~64s Extended readback, so the
  measured 13.14s understates the true both-legs-open period (~64s+). The `target_total_latency` guard is
  what correctly caught it. Same window-start-after-readback bug identified for Ethereal targets, now
  manifest on the Extended target.

## Post-canary state (verified)
- Gates: MIGRATION_LIVE_ENABLED / MANUAL_LIVE_CANARY / FULL_ALLOWED all **false**.
- Autos: ethereal source auto **restored to true**; extended target auto false. No restore pending.
- `random_production_status`: status **stopped**, `pid: null`, `duplicate_runner_process: false`,
  current venue **extended**, extended short **1.816**, ethereal 0.0, nado 0.0, open orders zero,
  `inside_tolerance: true`, `restart_blocked_by_route_proofs: true`.
- `route_proofs`: **5/6 READY_FOR_RANDOM**; `ethereal->extended` **STALE** (old 2026-06-05 proof; the
  latency-failed canary was not ingested as a fresh READY proof).
- `systemctl is-active delta-neutral-random-production-6.service` → **inactive**.

## Expected vs actual
| expected | actual |
|---|---|
| production venue extended | ✅ extended |
| ethereal short 0 / extended ~fresh target / nado flat | ✅ 0 / 1.816 / 0 |
| open orders zero / inside_tolerance true | ✅ / ✅ |
| ethereal->extended READY_FOR_RANDOM | ❌ STALE |
| route proofs 6/6 | ❌ 5/6 |
| double_exposure_end_source="authoritative_fill" | ❌ not surfaced in canary receipt |
| source_close_fill_readback_agreement=true | ❌ not surfaced |
| double_exposure_seconds ≤ 5 | ❌ 13.14 |
| gates false / autos restored / runner inactive | ✅ / ✅ / ✅ |

## Net
Venue flipped ethereal → extended without certifying; still **5/6**. Re-proving `ethereal->extended`
requires being on ethereal again (a reposition) and would hit the **same ~64s Extended-open wall**.
Certifying this route at the current 15s target-latency threshold is blocked by **Extended's
open-confirmation latency** — a venue characteristic, not reachable by the Ethereal-focused fixes.

## Options (none change MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS or latency thresholds)
1. Build an **Extended fast open-fill confirmation** analogous to the Ethereal one — only if Extended
   exposes an authoritative per-order fill status we can read read-only.
2. **Investigate/reduce** the Extended open readback latency (~64s).
3. Accept `ethereal->extended` cannot certify at current latency thresholds.

## Safety confirmation
Exactly one supervised canary. Runner never started (inactive throughout). Gates disarmed, autos restored.
No threshold changed. No further routes run. DB mutations limited to arm/disarm canary gates + scoped
ethereal source-auto pause/restore. Position healthy and hedged on extended.
