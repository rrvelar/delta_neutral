# Stale Pending-Continuation Artifact — FIXED; restart readiness PASS (2026-07-11)

Runner restart blocker "pending target=Nado migration continuation must be
completed before burn-in" is **cleared**. No runner/scheduler start, no canary,
no gates armed, no orders/signatures (continuation dry-run receipt shows
`orders_submitted: 0, signatures_created: 0`), no push.

## What was done

1. **Code fix (commit `8c0cf5b`)** — `MigrationManualLiveCanaryRunner#from_executor_result`
   now copies the executor finalization flags into the canary receipt:
   `production_venue_finalized`, `open_orders_clear_after`, `third_venue_flat`,
   `other_venues_flat`. The proof registry qualifies live proofs on the runner
   receipt (its `live_canary_proof?` needs `target/source_leg_readback_confirmed`,
   which only the runner line has), so without these flags a fresh proof failed
   `finalized_route_readback?` and stopped auto-resolving stale pending artifacts.
   Prevents recurrence for all future canaries.
2. **Tests** — new runner test (flags propagate) and a new registry test file
   `migration_route_proof_registry_pending_continuation_test.rb`: artifact resolves
   when the fresh proof summary carries the flags; stays unresolved when absent;
   summary exposes the flags. 30 runs new/runner suite + 96 runs regression
   (registry semantics, executor, readiness) — all green; RuboCop clean.
3. **Deploy** — image `f9a67780f9e2`, fix verified present in the running container.
4. **Existing June-5 artifact resolved via the app's own reconciliation path** —
   `migration:continue_target_first_after_nado_confirmed position_id=6
   from=ethereal to=nado dry_run=true` (evaluated in code first: dry-run never
   submits orders and never finalizes DB). Its receipt matched the artifact
   exactly (`pending_migration_id: 6684ae14249769e5`, June digest) with
   `final_status: MIGRATION_FINALIZED`, target confirmed, source already flat,
   inside tolerance, `production_venue_finalized: true` — satisfying
   `resolved_nado_target_continuation?`'s continuation branch. No timestamp hacks,
   no receipts deleted, no registry semantics changed.

## Post-deploy verification (read-only)

- `random_production_status`: **`blockers: []`**, **`current_direct_market_safe: true`**,
  `restart_blocked_by_route_proofs: false`, status `stopped`, pid/lock null,
  no duplicate runner, systemd `inactive`
- One-leg normal on **nado**: `1.688` (only short), ethereal/extended `0.0`,
  open orders zero ×3, `inside_tolerance: true`, gates all false,
  `unconfirmed_venue_readbacks: []`
- Route proofs: **6/6 READY_FOR_RANDOM, all `route_production_safe: true`,
  all latency `passed`, stale 0, missing 0.** (ethereal->nado's qualifying event
  is now the 03:26 continuation receipt; its live canary receipt reference and
  the 4.51s underhedge certification receipt are unchanged on disk.)

## Verdict: **PASS**

Runner restart readiness is PASS: no blockers, market safe, 6/6 fully green,
one-leg normal state, runner inactive. The only remaining hygiene items (unchanged):
unpushed local commits `d024ca0` + `8c0cf5b` (push when authorized), pre-existing
uncommitted `.dockerignore`/registry-test modifications, and the intermittent
`extended_optional` snapshot read timeout noted in the earlier audit.

Runner NOT started, per instructions. Exact start command when you decide:
`sudo systemctl start delta-neutral-random-production-6.service`
