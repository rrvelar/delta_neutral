# Generalized route-proof latency map (all 6 routes, 3 venues)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** READ-ONLY investigation + code/test plan. No live execution, no runner, no gates, no DB/env/
secrets mutation, no route-policy change, no order-construction change, no threshold change.

## Current production state (read-only)
- runner **stopped**, `pid: null`, `duplicate_runner_process: false`, `systemctl is-active` → **inactive**
- current venue **extended**; `direct_venue_shorts`: nado 0.0, ethereal 0.0, **extended 1.816**; open orders zero
- `inside_tolerance: true`; gates all false; `restart_blocked_by_route_proofs: true` (route proofs 5/6,
  `ethereal->extended` STALE)

## Root cause (generalized)
Target_first legs confirm via **slow position readback**. That (a) delays the next leg → real overhedge,
and (b) inflates `target_total_latency_seconds` / `total_migration_latency_seconds`. Authoritative
order-**fill** confirmation lets the leg return fast, but only where the venue exposes a read-only
order/fill-by-id endpoint. **Ethereal has it (wired); Extended does not; Nado has a digest path wired only
as a source_first fallback.** The 64.8s wall on `ethereal->extended` is Extended's position read timing
out (~10s each). The deployed authoritative-fill fixes only re-anchor the double-exposure window
timestamps; they do NOT reduce `target_total_latency_seconds` (that is the leg's own build→readback span,
`hedge_venue_migration_executor.rb:701`) — only a venue fast-fill path that makes the leg *return* fast
reduces it.

## Matrix 1 — route / leg
| Route | Seq | Target open | Source close | Bottleneck | Blocking budget |
|---|---|---|---|---|---|
| ethereal->extended | target_first | extended (SLOW, no fast-fill) | ethereal close (fast-fill) | extended target open ~64s | double_exposure>5, target_total>15, total>45 |
| nado->extended | target_first | extended (SLOW, no fast-fill) | nado close (~2.75s) | extended target open | target_total>15, total>45 |
| extended->ethereal | target_first | ethereal open (fast-fill) | extended close (SLOW, no fast-fill) | extended source close delays double_exposure END | double_exposure>5 |
| nado->ethereal | target_first | ethereal open (fast-fill) | nado close (~2.75s) | none major | READY |
| extended->nado | source_first | nado open (~2.75s) | extended close (SLOW; before underhedge window) | mostly OK | READY (underhedge 4.9s) |
| ethereal->nado | source_first | nado open (~2.75s) | ethereal close (fast-fill) | none major | READY via prod cycle¹ |

¹ `ethereal->nado` latency-proof receipt shows `route_production_safe=false / failed_latency_threshold`
but is currently READY via a `production_random_cycle` event — flag for separate review.

Source_first (nado-target) routes have NO double-exposure (target opens after source flat); their risk is
underhedge vs `MIGRATION_MAX_UNHEDGED_SECONDS=10s`.

## Matrix 2 — venue / action confirmation capability
| Venue · action | Confirms via | Order id? | Read-only fill-by-id? | terminal/reduceOnly/size/remaining? | Fast-fill built? | Flag |
|---|---|---|---|---|---|---|
| Ethereal open | order-list fill (fast) → else readback | yes | yes (`EtherealReadOnlyProbe#find_order`, GET /v1/order incl. filled) | yes | yes `fast_open_fill_readback` | `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED` (off) |
| Ethereal close | order-list fill (fast) → else readback | yes | yes | yes | yes `fast_close_fill_readback` | `ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED` (off) |
| Extended open | position readback (slow, ~10s/read) | yes (`exchange_order_id`) | NO (client only `/user/orders`=open) | NO | NO | none |
| Extended close | position readback (slow) | yes | NO | NO | NO | none |
| Nado open | position readback (~2.75s); digest confirm only as source_first fallback | yes (digest) | partial (`NadoExecutionConfirmation.confirm_digest` + archive; `base_filled`) | partial | fallback-only | `AERODROME_NADO_*` |
| Nado close | position readback only (no digest path) | yes | partial | partial | NO | — |

## Files / functions inspected (file:line)
### Extended (Agent A)
- `app/services/extended_mainnet_lifecycle_check.rb`: `poll_short_readback` :494-508 (target open confirm),
  `poll_flat_readback` :544-558 (source close confirm); `DEFAULT_READBACK_ATTEMPTS=6`/`INTERVAL=0.5s`
  :5-6 (overridable `EXTENDED_POST_SUBMIT_READBACK_ATTEMPTS/INTERVAL_SECONDS` :560-568); timing
  :574-594; `exchange_order_id` :636-641 (order id captured).
- `app/services/extended_api_client.rb`: only `open_orders`→`/user/orders` :34 (open only), `positions`
  :30, `submit_order` :58. **No order-by-id / history / fills/trades endpoint. No ExtendedReadOnlyProbe.**
- Flags: `EXTENDED_LIVE_ENABLED`, `EXTENDED_MAINNET_PROBE_ENABLED`, `EXTENDED_AUTO_REBALANCE_ENABLED`
  (`extended_mainnet_lifecycle_check.rb:145-147`).

### Nado (Agent B)
- `app/services/nado_hedge_execution_service.rb`: `execute`→`poll_post_submit_readback` :808-812; loop
  :1387-1410 (`POST_SUBMIT_READBACK_ATTEMPTS=12`×0.25s open, `POST_SUBMIT_CLOSE_READBACK_ATTEMPTS=12`×0.25s
  close); digest captured as `exchange_order_id` :1454-1478.
- `app/services/nado_execution_confirmation.rb`: `confirm_digest` (order-by-digest `query type:order`
  :47, `base_filled` :98-104; archive endpoint :63-81). Authoritative but source_first-fallback only.
- `hedge_venue_migration_executor.rb`: source_first nado reconciliation :240-267, digest confirm
  :1023-1036, canonical readback still required :972-993; underhedge timing :211/236/238/841-846.
- Source_first avoids double-exposure (target opens only after `leg_confirmed?(source_leg)` :200-216).

### Executor budgets (Agent C) — `hedge_venue_migration_executor.rb`
- Thresholds: double_exposure `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS`=5 (:882-884, guard
  `double_exposure_exceeds_threshold?` :849-854); underhedge `MIGRATION_MAX_UNHEDGED_SECONDS`=10
  (:886-888); total_route `MIGRATION_MAX_TOTAL_ROUTE_SECONDS`=30 (:890-892);
  **target_total_latency `MIGRATION_MAX_TARGET_LEG_LATENCY_SECONDS`=15 (:1514-1516)**;
  source_close_total `MIGRATION_MAX_SOURCE_CLOSE_LATENCY_SECONDS`=15 (:1518-1520);
  **total_migration `MIGRATION_MAX_TOTAL_ROUTE_LATENCY_SECONDS`=45 (:1522-1524)**;
  target_confirm→source_close `MIGRATION_TARGET_TO_SOURCE_CLOSE_MAX_LATENCY_SECONDS`=10 (:1117-1121).
- Two systems: SAFETY/incident (`apply_latency_incident!` :894-918 sets `route_production_safe=false`,
  `latency_incident=true`) driven by double_exposure (target_first, :137) / source_first_risk (:284);
  WARNING/annotation (`annotate_migration_latency!`/`latency_threshold_exceeded_entries` :1488-1500) emits
  the "LATENCY_THRESHOLD_EXCEEDED" strings for target_total (15) and total_migration (45).
- `target_total_latency_seconds` computed :701 from the leg's `timing[:total_action_latency_seconds]`
  (Ethereal `finalized_timing` build→readback_confirmed :705) → **includes the slow open readback**.
- Authoritative-fill fixes only rewrite `target_leg_accepted_at`/`source_close_flat_confirmed_at`
  (double-exposure window); they do NOT touch `target_total_latency_seconds`.
- Confirmation wiring: `DefaultLegRunner#normalize_service_result` :498-517 passes `confirmed`,
  `open_fill_confirmation`, `close_fill_confirmation`, `readback`. Gate `leg_confirmed?` :1435-1437 keys off
  `confirmed` (falls back to slow `readback_confirmed`); fill-confirmation fields only tighten the
  double-exposure timing, not the confirm decision.

### Route policy + registry (Agent D)
- `app/services/migration_route_operational_policy.rb`: `route_strategy(from:,to:)` :24 →
  `default_strategy(to)` :159-161 = `source_first` if `to=="nado"` else `target_first`. Keys in
  `operational_settings.rb` `ROUTE_STRATEGY_KEYS_BY_ROUTE` :38-45. nado-target = source_first; else
  target_first (confirmed).
- `app/services/migration_route_proof_registry.rb`: `status_for` :145-183 (READY/STALE/
  NOT_PRODUCTION_SAFE_LATENCY/FAILED_NEEDS_REPAIR); `stale?` :632-638 (**30-day TTL, constructor arg
  `stale_after: 30.days` :14** + git-commit drift check); anti-fabrication guards — dry-run rejected
  (`production_latency_proof_event?` :529-533, `production_receipt_event?` :535-538 require
  `!dry_run && (live||submitted||orders_submitted>0||orders_placed>0)`); `live_canary_proof?` :360-369
  requires target+source readback confirmed, final_inside_tolerance, source_flat_after,
  target_holds_expected_short, open_orders_after==0, AND `production_safe_latency?`;
  `production_cycle_proof?` :296-320 strict; **latency-failed canary (`route_production_safe=false`) →
  NOT_PRODUCTION_SAFE_LATENCY, never READY** (`latency_unsafe?` :470-486, gate :368).

## Assessment
- Fast/safe today: Ethereal open+close (fast-fill, flag on), Nado open/close (~2.75s).
- Slow/readback-bound: **Extended open + Extended close** (~10s/read).
- Authoritative fill endpoints: Ethereal (full, wired); Nado (digest, fallback-only).
- Cannot accelerate with current APIs: **Extended** — no read-only order-by-id/history/fills in the client;
  filled orders vanish from `/user/orders`. Needs a NEW Extended read (not present, not assumable).

## Recommended smallest safe implementation order
1. **Prerequisite (cheapest):** determine Extended live-API reality (needs API docs / one read-only probe):
   (a) does the order **submit response** already carry synchronous fill status/size (marketable order)?
   → confirm from the response, no extra call; (b) is there a read-only **order-by-id / order-history /
   user-trades** endpoint returning terminal-filled orders with filled size + reduceOnly?; (c) is the
   whole Extended API slow from this VPS or only position aggregation?
2. **If (1) yields a usable fast read:** build `ExtendedReadOnlyProbe#find_order` + `classify_open_fill`/
   `classify_close_fill` + `fast_open_fill_readback`/`fast_close_fill_readback` mirroring Ethereal, behind
   default-OFF `EXTENDED_OPEN_FILL_CONFIRMATION_ENABLED` / `EXTENDED_CLOSE_FILL_CONFIRMATION_ENABLED`,
   fail-closed. Unblocks the 4 Extended-touching routes.
3. **Add per-leg receipt diagnostics** (confirmation source + timing for every leg) — this session's canary
   receipt did not surface them, making leg-level root-cause harder.
4. **(Optional, lower priority)** wire Nado digest confirmation into the primary path behind a default-OFF
   flag; Nado is already ~2.75s and nado-target is source_first (no double-exposure).

No shared abstraction yet — per-venue fast-fill behind its own default-OFF flag (as Ethereal already is);
extract a shared `classify_fill` only once a second venue is implemented.

## Tests to add (when implementing)
- Route matrix: every enabled route resolves a known sequence + a known confirmation model.
- Fallback: slow position-readback remains default when fill flags OFF (byte-for-byte).
- Target-open fill confirmation starts double-exposure at real fill time; source-close fill confirmation
  ends it at real fill time.
- Partial / ambiguous / non-matching / reduceOnly-mismatch fill never confirms (fail closed → readback).
- Final position readback disagreement prevents certification.
- Thresholds unchanged (guard tests for all budget defaults).
- Registry cannot certify a fabricated / dry-run / unexecuted / latency-failed receipt (extend existing
  anti-fabrication tests to any new venue path).

## Is any live route safe to retry now? NO.
Every path to 6/6 requires an Extended leg to confirm fast: `ethereal->extended` needs Extended-as-target;
returning to ethereal via `extended->ethereal` needs Extended-as-source-close. Until Extended has a fast
authoritative confirmation, a retry re-fails on the ~64s wall and only flips the venue. The 5 READY routes
are fine; do not restart the runner.

## Safety confirmation
Read-only investigation only. No live execution, no runner start, no gates, no DB/env/secrets mutation, no
route-policy/order-construction change, no threshold change. Production unchanged (venue extended, runner
inactive, 5/6).
