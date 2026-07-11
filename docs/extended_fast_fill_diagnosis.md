# Diagnosis: why extended->ethereal did not certify (Extended fast-fill was NOT the problem)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** READ-ONLY diagnosis. No live canary, no arm, no runner/scheduler, no orders, no route, no
deploy/rebuild/push, no threshold/route-policy change, no DB/env/secrets mutation.

## Current safe state (verified)
Venue **ethereal** (1.8703), extended 0, nado 0, open orders zero, inside_tolerance true, gates false,
runner **inactive**, route proofs **5/6** (`ethereal->extended` STALE). Unchanged.

## Headline
**The Extended fast-fill worked.** Both legs confirmed via authoritative order fill
(`double_exposure_start_source = authoritative_fill`, `double_exposure_end_source = authoritative_fill`,
`*_fill_readback_agreement = true`). The ~40s double exposure is **real**, caused by the **Extended
source-close leg's BUILD phase (~34s of slow pre-submit Extended API reads)** — NOT the fill confirmation.

## Evidence (from the executor's full receipt, storage/hedge_migration_live_canaries/20260708.jsonl line 4)
| field | value |
|---|---|
| target_leg_accepted_at (ethereal open authoritative fill) | 19:20:28.257 |
| target_readback_confirmed_at | 19:20:28.311 (**+54ms** — ethereal fast open fill worked) |
| source_close_submit_started_at | 19:20:28.312 (immediate; `target_confirm_to_source_close = 0.0006s`) |
| **source_close_submit_finished_at** | **19:21:12.200 (~44s later)** |
| source_close_submit_latency_seconds | **43.89** |
| source_close_readback_latency_seconds | **2.36** (fast-fill readback was FAST) |
| second_leg timing | total=37.64, submit=1.0, readback=2.36, **slow_step=build** (~34s in build) |
| double_exposure_start_source / end_source | **authoritative_fill / authoritative_fill** |
| source_close_fill_readback_agreement | true |
| double_exposure_seconds | 39.73 |

Interpretation: the ethereal target open confirmed via order-list fill in ~54ms; the executor submitted the
Extended close immediately; but the Extended close **leg** spent ~34s in its **build** phase (pre-submit
Extended API calls: `read_position`, `account_state`, `market_metadata`, live/structural blockers, order
preview — several of them, some read more than once) before the close order was actually submitted. The
order then filled on-chain in ~102ms (`createdTime→updatedTime`) and the fast-fill confirmed it in 2.36s.
So both legs were genuinely open ~40s — a **real overhedge from build latency**, not a measurement artifact
and not a fast-fill failure.

## Read-only proofs collected
- Flag reaches the service: with the inline env, `close_fill_confirmation_enabled? = true`,
  `open_fill_confirmation_enabled? = true`; env flows ENV → runner (`env: ENV`) → executor →
  `DefaultLegRunner` → `env = @env.to_h.merge(...)` → venue/service.
- The Extended close order `2074936830431141888`: `order_by_id` in **0.98s** → `FILLED`, `reduceOnly=true`,
  `side=BUY`, `market=ETH-USD`, `qty=filledQty=1.866`, `cancelledQty=0`; `find_order` in **1.05s**;
  `classify_close_fill(size=1.866) → :filled`. The read path itself is fast and correct.
- Fast-fill window: `FILL_CONFIRM_ATTEMPTS=6`, `FILL_CONFIRM_INTERVAL_SECONDS=0.25`,
  `EXTENDED_API_TIMEOUT_SECONDS=1.0` → ~7.5s max; consistent with the observed 2.36s readback.

## Root cause category
- **A (flag didn't reach service):** ruled out.
- **B (fast path fell back to slow position readback):** ruled out — both legs = `authoritative_fill`.
- **C (confirmed but not propagated):** ruled out — the executor consumed it (`double_exposure_*_source =
  authoritative_fill`, agreements true).
- **D (diagnostics dropped from the canary receipt):** CONFIRMED — the executor's full receipt (jsonl line
  4) has all diagnostics, but `MigrationManualLiveCanaryRunner#from_executor_result`
  (`app/services/migration_manual_live_canary_runner.rb:86-124`) curates them away before writing the
  canary receipt (jsonl line 5). Also `source_close_confirmation_source` / `target_open_confirmation_source`
  appear `<redacted>` in the executor receipt (worth checking `sanitize_sensitive`/`sensitive_key?`, though
  the decisive fields — `slow_step`, latencies, `double_exposure_*_source` — are readable).
- **E (the real latency):** CONFIRMED — the **Extended leg BUILD phase (~34s of slow pre-submit Extended
  API reads)** is the bottleneck, independent of the (working) fast-fill.

## Files / functions
- Root cause (E): `app/services/hedge_venue_migration_executor.rb` `DefaultLegRunner#run_extended_source_close_leg`
  (extra `read_position` before the service call) → `ExtendedHedgeExecutionService#run_lifecycle` →
  `ExtendedMainnetLifecycleCheck#run` build path: `read_position` (L24), `build_orders`/`close_preview`,
  `structural_blockers` → `@venue.live_readiness_blockers` / `@venue.blockers` / `account_state` /
  `market_metadata_diagnostics` / `read_position` again (`app/services/hedge_venues/extended.rb`,
  `app/services/extended_api_client.rb`). Multiple slow Extended GETs in the build.
- Observability (D): `app/services/migration_manual_live_canary_runner.rb#from_executor_result` (curation);
  `app/services/hedge_venue_migration_executor.rb#sensitive_key?` (L1545) for the confirmation-source
  redaction.

## Smallest safe fix (proposed — NOT implemented)
1. **Observability first (code+tests, no behavior change):**
   - `from_executor_result`: carry the executor diagnostics into the written canary receipt —
     `double_exposure_start_source`, `double_exposure_end_source`, `source_close_confirmation_source`,
     `target_open_confirmation_source`, `*_fill_confirmed_at`, `*_position_readback_confirmed_at`,
     `*_fill_readback_agreement`, `target_total_latency_seconds`, `source_close_total_latency_seconds`,
     and per-leg `slow_step` + `submit_latency` + `readback_latency`.
   - `sensitive_key?`: stop redacting non-sensitive `*_confirmation_source` diagnostics (keep secrets
     redacted). Tests: canary receipt surfaces the fields; secrets still redacted.
2. **Real latency fix (E) — reduce the Extended leg BUILD time:**
   - Eliminate redundant `read_position` calls in the Extended leg/build (read once, pass through) and
     avoid re-fetching `account_state`/`market_metadata` multiple times per leg.
   - Characterize/parallelize or cache the pre-submit Extended readiness reads; each Extended GET is slow
     from this VPS. Count the GETs in the close-leg build and cut the count (biggest lever).
   - Keep order construction, gates, thresholds, and the fail-closed live blockers unchanged; this is a
     read-consolidation change, not a safety-check removal.
   (Investigate + propose precisely before implementing; do NOT touch order construction or drop any live
   readiness blocker.)

## Is ethereal->extended safe to retry now? **NO.**
For `ethereal->extended`, **Extended is the target open** — the same ~34s Extended build-phase latency
would inflate `target_total_latency` (> 15s) AND, because target_first waits for the target open before
closing the source, produce a real ~34s+ overhedge. The fast-fill working does not help; the bottleneck is
the Extended leg build. Do NOT retry until (a) diagnostics are surfaced in the canary receipt and (b) the
Extended build-phase read latency is reduced/characterized and shown to bring `target_total_latency` under
15s and `double_exposure` under 5s.

## Safety confirmation
Read-only diagnosis only. No live action, no arm, no runner/scheduler, no route, no deploy/rebuild/push, no
threshold/route-policy change, no DB/env/secrets mutation. Production unchanged: venue ethereal, runner
inactive, gates false, 5/6.
