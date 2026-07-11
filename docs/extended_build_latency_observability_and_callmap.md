# Extended build-latency: observability fix + call map (build reduction proposed, not implemented)

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** Part 1 (observability) implemented — code + tests, NOT deployed. Part 2 (call map) delivered.
Part 3 (build-read consolidation) **NOT implemented** — not obviously safe (readback staleness). No live
canary, no arm, no runner/scheduler, no orders, no route, no deploy/rebuild/push, no threshold/route-policy/
order-construction change, no blocker removal, no DB/env/secrets mutation.

## Diagnosis recap (from the prior investigation)
The Extended source-close leg took ~34s in its **build/pre-submit** phase (`slow_step=build`,
`source_close_submit_latency=43.89s`, fast-fill readback only 2.36s). Both legs confirmed via
`authoritative_fill`. The fast-fill worked; the bottleneck is the build phase issuing many slow Extended
API reads.

## Part 1 — Observability (IMPLEMENTED, code+tests, not deployed)
The executor's full receipt already had the diagnostics, but the canary receipt dropped/redacted them.
Root causes: (a) `MigrationManualLiveCanaryRunner#from_executor_result` curated them away; (b) the receipt
writer's `sensitive_key?` matched `/confirmation/` and redacted `*_confirmation_source`.

- `app/services/migration_manual_live_canary_runner.rb#from_executor_result` — now carries:
  `double_exposure_start_source`, `double_exposure_end_source`, `target_open_confirmation_source`,
  `source_close_confirmation_source`, `target_open_fill_confirmed_at`,
  `target_open_position_readback_confirmed_at`, `source_close_fill_confirmed_at`,
  `source_close_position_readback_confirmed_at`, `target_open_fill_readback_agreement`,
  `source_close_fill_readback_agreement`, `target_total_latency_seconds`,
  `source_close_total_latency_seconds`, `total_migration_latency_seconds`, and per-leg
  `target_leg_timing` / `source_leg_timing` = `{slow_step, total_action_latency_seconds,
  build_latency_seconds, submit_latency_seconds, readback_latency_seconds}` (via new `leg_timing_summary`
  + `seconds_between`).
- `app/services/hedge_venue_migration_receipt_writer.rb#sensitive_key?` — added
  `NON_SENSITIVE_CONFIRMATION_KEYS` allowlist (`confirmation_type`, `target_confirmation_source`,
  `source_close_confirmation_source`, `target_open_confirmation_source`, `readback_confirmation_source`)
  so those diagnostics survive; secrets/keys/signatures/tokens/`required_confirmation_phrase` stay redacted.
  (Note: the executor's own `sensitive_key?` never matched "confirmation"; the receipt writer was the
  redactor — the task's pointer to the executor method was slightly off.)
- Tests: `migration_manual_live_canary_runner_test.rb` (+1: canary receipt surfaces the diagnostics +
  per-leg `slow_step`/`build_latency_seconds`); new `hedge_venue_migration_receipt_writer_test.rb` (+2:
  confirmation-source diagnostics unredacted; secrets + generic confirmation material still redacted,
  redaction recurses into nested hashes).

## Part 2 — Extended build-phase API call map (empirical, offline counting client)
GET count per single method call (`HedgeVenues::Extended` with a counting fake client):
| method | positions | balance | account_info | market | leverage | fees | open_orders | total |
|---|---|---|---|---|---|---|---|---|
| `read_position` | 1 | 1 | | | | | | 2 |
| `account_state` | 2 | **5** | 1 | 2 | **3** | 2 | 2 | **17** |
| `read_only_account_diagnostics(cp)` | | 1 | 1 | | 1 | | 1 | 4 |
| `blockers` | 1 | 2 | | | 1 | | | 4 |
| `close_preview` | 1 | 2 | | | 1 | | | 4 |

Key structural redundancies (file:line):
- `read_position` (`hedge_venues/extended.rb:44-53`) always appends `account_value_fields` → an **extra
  `balance` GET on every position read** (`:648-650`).
- `account_state` (`:103-108`) re-reads account_info + balance + market **and calls `read_position`**
  (positions + balance) — and its internal diagnostics (`read_only_account_diagnostics`,
  `margin_gate_diagnostics`, `account_value_fields`) each independently re-fetch `balance`/`leverage`,
  giving **balance ×5, leverage ×3** for one `account_state`.
- Nothing is memoized: `read_only_call` (`:596`) hits the API every time.
- The lifecycle-check build path (`ExtendedMainnetLifecycleCheck#run`) calls `read_position` (L24),
  `build_orders`/`close_preview`, `structural_blockers` (→ `blockers`/`live_readiness_blockers`,
  `mode_position_blockers`→`read_position`), `live_blockers` (→ `read_position`, **`account_state`**,
  open_orders), and `result()` (→ `read_only_account_diagnostics`, `market_metadata_diagnostics`). Summed,
  one close-leg build issues ~30-40 sequential GETs; at `EXTENDED_API_TIMEOUT_SECONDS=1.0` that is ~30-40s
  — matching the observed ~34s.

## Read classification (why naive memoization is unsafe)
- **Volatile (change on fill; must be read FRESH for the post-submit flat readback):** `positions`,
  `balance`. The close readback fallback (`poll_flat_readback → @venue.read_position` → positions+balance)
  MUST see post-fill state; caching them across submit would corrupt the readback → unsafe.
- **Static within a leg (safe to memoize):** `market` (increments/config/mark), `account_info` (account
  status/vault), `fees`, `leverage` (unchanged during a canary).

## Part 3 — Proposed smallest safe fix (NOT implemented; needs review)
1. **Config-read memoization (obviously safe, partial win):** memoize `read_only_call(:market/:account_info/
   :fees/:leverage)` per venue instance (fresh per leg). Cuts the config GETs (market ×2→1, leverage ×3→1,
   fees ×2→1, account_info dedup). Test: a 2nd `account_state` issues ≤1 each of those; `balance`/`positions`
   still fetched fresh each call.
2. **Build-scoped volatile caching (bigger win, needs review):** thread a build-phase snapshot of
   `positions`/`balance` through the lifecycle-check build so the build reuses ONE read, and **invalidate it
   before the post-submit readback** so the readback reads fresh. Test: post-submit readback issues a fresh
   positions/balance GET; every blocker still evaluates; fail-closed preserved.
3. **`read_position` extra balance:** make `account_value_fields` lazy/optional where only `short_size` is
   needed (readback), after verifying no consumer of that position hash needs `account_value` in that path.
- Expected reduction: ~30-40 GETs → ~8-12, i.e. build ~34s → roughly ~8-12s (must re-measure to confirm
  `target_total_latency < 15s` and `double_exposure < 5s`).
- Keep order construction, live readiness blockers, thresholds, and final readback unchanged — this is
  read-consolidation only.
- **Recommendation:** implement after review, with the offline GET-count test as the acceptance gate; the
  volatile-cache part must not ship without the "readback reads fresh" test. Not obviously safe enough to
  implement unreviewed now.

## Files changed (Part 1)
- `app/services/migration_manual_live_canary_runner.rb`
- `app/services/hedge_venue_migration_receipt_writer.rb`
- `test/services/migration_manual_live_canary_runner_test.rb`
- `test/services/hedge_venue_migration_receipt_writer_test.rb` (new)

## Tests run
`migration_manual_live_canary_runner`, `hedge_venue_migration_receipt_writer` (new),
`hedge_venue_migration_executor`, `extended_mainnet_lifecycle_check`, `extended_api_client`,
`extended_read_only_probe`, `migration_route_proof_registry`, `migration_manual_canary_gates`:
**155 runs, 1046 assertions, 0 failures.** RuboCop on the 4 changed files: **0 offenses.**

## Why safety is not weakened
- Part 1 only adds non-sensitive diagnostic fields to the written canary receipt and stops redacting
  non-secret `*_confirmation_source` strings; secrets/keys/signatures/tokens/confirmation phrase remain
  redacted (asserted). No execution/threshold/gate/order behavior changed.
- Part 3 (the behavior-touching consolidation) was deliberately NOT implemented because the meaningful part
  (positions/balance) is not obviously safe (readback staleness). No live-behavior change was made.

## Is ethereal->extended safe to retry now? **NO.**
Only observability was added; the Extended build latency (~34s of redundant GETs) is unchanged. For
`ethereal->extended`, Extended is the target open — the same build latency would blow
`target_total_latency > 15s` and create a real ~34s overhedge. Do NOT retry until the build-read
consolidation is implemented (post-review) and a canary shows `target_total_latency < 15s` and
`double_exposure < 5s` (now observable via the Part 1 diagnostics).

## Safety confirmation
Code + tests only (Part 1). No deploy/rebuild/push, no live canary, no arm, no runner/scheduler, no route,
no orders/signatures/cancels, no threshold/route-policy/order-construction change, no blocker removal, no
DB/env/secrets mutation. Production unchanged: venue ethereal (1.8703), runner inactive, gates false, 5/6.
