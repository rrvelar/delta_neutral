# Full 6-Route Instrumentation Matrix Audit (2026-07-12)

Read-only audit of every route's qualifying proof event AND the complete
historical measurement record (`storage/hedge_migration_checks/*.jsonl` holds
full executor receipts for every runner cycle — dozens of honest measurements
the registry never consults). Verdict up front: **the registry's 6/6
"production_safe" state is built on blank-latency wrapper events for 4 of 6
routes, and honest measurements show 3 of 6 routes consistently FAIL the 5s
double-exposure bar.**

## A. Registry/proof status (current)

| route | status | proof ts | safe | qualifying event type | latency fields on qualifying event |
|---|---|---|---|---|---|
| extended->ethereal | READY | 2026-07-04 | true | production_random_cycle | **all blank** |
| ethereal->extended | READY | 2026-07-10 | true | manual_live_canary | de 3.929 (modern) |
| extended->nado | READY | 2026-07-07 | true | manual_live_canary | uh 4.929 (modern) |
| nado->extended | READY | 2026-07-11 | true | production_random_cycle | **all blank** |
| ethereal->nado | READY | 2026-07-11 | true | nado continuation receipt | **all blank** (modern 4.508 canary exists but doesn't qualify) |
| nado->ethereal | STALE | 2026-06-11 | true | production_random_cycle | **all blank** |

## B/C. Honest measurement record vs qualifying events

From `hedge_migration_checks` executor receipts (every runner cycle since June)
plus manual canary receipts:

| route | seq | honest measurements | source-close evidence | verdict vs 5s/10s bars |
|---|---|---|---|---|
| ethereal->nado | source_first | uh **4.42–4.68s across ~25 cycles + 4.508 canary**, safe true every time | n/a (source close precedes window; nado open ends window at execution-confirm ~0.7s) | **PASSES consistently** |
| extended->nado | source_first | uh **4.42–4.67s across ~10 cycles + 4.929 canary** | n/a (same family) | **PASSES consistently** |
| ethereal->extended | target_first | June: ~32–34s (pre fast-fill); **modern: 3.929s** (Jul 10 canary, authoritative fill both ends) | ethereal close: order-list fill OFF → fast position readback | **PASSES (modern)** |
| extended->ethereal | target_first | June: never measured (blank); **modern: 9.20s (Jul 10 canary), 9.12s (Jul 11 cycle)** — both `latency_incident: true` | extended close: order-by-id fill (fast, 1.0s) — the 9.1s is leg overhead, see below | **FAILS ~9s** |
| nado->extended | target_first | **27.5–30.7s in EVERY measured cycle (~20 samples, Jun 7–Jul 4)**, all `safe: false, latency_incident: true`; Jul 11 cycle-1 receipt lost to the EACCES bug | nado close: position readback (~28s onchain state lag) | **FAILS ~28s** |
| nado->ethereal | target_first | June: never measured (blank); **modern: 33.92s (Jul 12 canary)** | nado close: position readback (tx accepted at +1.4s; state lag ~30s) | **FAILS ~30s+** |

extended->ethereal 9.12s decomposition (Jul 11 cycle receipt): target fill →
close submit gap 0.0004s ✓; then close-leg preamble **1.97s** (fresh source read
— `frozen_source_position: null`: the frozen sizing proof only builds for
`from=ethereal`); build **2.09s**; **build→sign gap 2.95s** (unaccounted
Extended-leg overhead); submit 1.09s; order-by-id fill confirm 1.02s.

## D. Classification

| route | classification | why |
|---|---|---|
| ethereal->extended | **MODERN_VALID** | modern passing measurement qualifies |
| extended->nado | **MODERN_VALID** | modern passing measurement qualifies |
| ethereal->nado | **MODERN_VALID (registry-mapping defect)** | passes consistently; qualifying event is a blank continuation wrapper — hardening must credit the measured event, not the wrapper |
| extended->ethereal | **LEGACY_UNTRUSTED + MODERN_BUT_FAILING (~9s)** | blank Jul-4 cycle wrapper qualifies; every honest measurement fails; needs close-leg latency work (frozen sizing for from=extended + the 2.95s build→sign gap) |
| nado->extended | **LEGACY_UNTRUSTED + MODERN_BUT_FAILING (~28s) + NEEDS_CODE_PATH** | blank Jul-11 cycle wrapper qualifies; ~20 honest failures; needs Nado tx-receipt close confirmation |
| nado->ethereal | **STALE + MODERN_BUT_FAILING (~30s) + NEEDS_CODE_PATH** | same from-Nado close problem |

## Systemic findings

1. **Production-cycle wrapper events mask failing measurements.** The registry
   qualifies on the freshest event; cycle wrappers carry no latency fields and
   pass `latency_unsafe?` permissively, even when the same cycle's own executor
   receipt (in `hedge_migration_checks/`) recorded `safe: false,
   latency_incident: true`. nado->extended has ~20 consecutive failing honest
   measurements while showing READY+safe.
2. **Continuation receipts have the same masking effect** (ethereal->nado's
   qualifying event) — though that route genuinely passes, the crediting is wrong.
3. **From-Nado closes need terminal onchain evidence** (tx receipt) — position
   readback lags ~28-30s; the tx is accepted in ~1.4s.
4. **extended->ethereal needs ~4-5s of Extended-close-leg overhead removed**
   (preamble read + build→sign gap) to pass honestly.
5. The `hedge_migration_checks` receipts are the authoritative honest record and
   should be a registry input for latency evidence.

## Implications for the hardening (Phase 2+)

After blank-latency events stop qualifying as production_safe, the immediate
registry state will be approximately: ethereal->extended VALID, extended->nado
VALID, ethereal->nado VALID (once measured-event crediting lands),
extended->ethereal / nado->extended / nado->ethereal NOT production_safe until
their code paths land and fresh certifications pass. That is the honest state.
