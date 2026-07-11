# Executor fix: end target_first double-exposure at the authoritative source-close fill

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** Code + tests only. No live canary, no runner start, no gates, no production DB/env/secrets
mutation, no venue-adapter/order-construction/route-policy change,
`MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` unchanged. Not deployed (redeploy required).

Fixes the correct layer: the migration executor now ends the target_first overhedge window at the
authoritative reduce-only source-close FILL confirmation (when present) instead of the slow position
readback — but only when the final position readback independently agrees the source is flat.

---

## Root cause (recap)
For target_first the executor measured double-exposure as
`target_leg_accepted_at -> source_close_flat_confirmed_at`, and `source_close_flat_confirmed_at` was
stamped when the executor's own `final_readback_status` (a position readback) confirmed source flat. The
Ethereal position endpoint lags the actual fill by ~38s, so the window stayed open ~38s > 5s even though
the close order had filled in ~1-2s. The prior service-layer fast fill confirmation did not affect this
executor-level timestamp.

## Change

### Ethereal service surfaces the authoritative fill (`app/services/ethereal_hedge_execution_service.rb`)
- `fast_close_fill_readback` now carries the fill details and tags the source `ethereal_order_list_fill`.
- `result` adds `readback_confirmation_source` and, for a confirmed reduce-only close, a
  `close_fill_confirmation` hash (`confirmed, source, reduce_only, confirmed_at, close_size_eth,
  filled_eth, remaining_eth, order_status`) via the new `close_fill_confirmation` helper. `confirmed_at`
  is the readback-confirmation time (when we authoritatively knew the close filled).

### Leg runner passes it through (`hedge_venue_migration_executor.rb` DefaultLegRunner#normalize_service_result)
- Adds `close_fill_confirmation: receipt[:close_fill_confirmation]` to the leg result.

### Executor ends the window on the fill (target_first only)
- After the source close, `mark_time!(:source_close_position_readback_confirmed_at)` records the slow
  position confirmation time, then the new `apply_authoritative_source_close_confirmation!` decides
  `source_close_flat_confirmed_at`:
  - authoritative fill present AND `source_flat_after == true` (final readback agrees) ->
    `source_close_flat_confirmed_at = fill.confirmed_at`, `double_exposure_end_source = "authoritative_fill"`.
  - fill present but final readback does NOT confirm flat -> keep the slow window, flag
    `source_close_fill_readback_agreement = false` (fail closed; proof will not certify).
  - no authoritative fill -> existing position-readback behavior exactly
    (`double_exposure_end_source = "position_readback"`).
- `authoritative_source_close_fill` only trusts a `confirmed == true`, `reduce_only == true`,
  timestamped, sourced confirmation. Guarded to `migration_sequence == "target_first"` only.
- Applied at both target_first sites (`run` and `run_precomputed_plan`); `execute_source_first` (line
  206) is untouched.

## Receipt fields added
- `source_close_confirmation_source` ("ethereal_order_list_fill" | "position_readback")
- `source_close_fill_confirmed_at`
- `source_close_position_readback_confirmed_at`
- `double_exposure_end_source` ("authoritative_fill" | "position_readback")
- `source_close_fill_readback_agreement` (true | false | nil)
- (Ethereal receipt) `readback_confirmation_source`, `close_fill_confirmation`

## Why this does NOT weaken safety
- The window shortens ONLY when BOTH hold: (a) the close order is reduce-only and terminally FILLED for
  at least the close size (validated by `classify_close_fill` in the service), AND (b) the independent
  final position readback confirms `source_flat_after == true`. Two authoritative confirmations, not one.
- If the fill claims closed but the final readback disagrees -> fail closed: the slow window is kept, the
  disagreement is flagged, and the migration does not finalize (source not flat) so the route does not
  certify.
- No authoritative fill / partial / ambiguous / 404 -> byte-for-byte existing position-readback behavior.
- `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` is unchanged (guard test) — the threshold still gates
  certification; we only measure the true (shorter) risk window correctly.
- source_first (nado-target latency) path untouched. Never marks flat on submit or partial fill.
- Route proof registry logic unchanged: it still certifies on `double_exposure_seconds <= 5` plus the
  safety flags; the new fields let it/operators distinguish authoritative-fill vs fallback/ambiguous.

## Files changed
- `app/services/ethereal_hedge_execution_service.rb` — `fast_close_fill_readback`, `result`,
  new `close_fill_confirmation`.
- `app/services/hedge_venue_migration_executor.rb` — `DefaultLegRunner#normalize_service_result`;
  target_first source-close block (both sites); new `apply_authoritative_source_close_confirmation!`
  and `authoritative_source_close_fill`.
- `test/services/hedge_venue_migration_executor_test.rb` — 4 new tests + helper.
- `test/services/ethereal_hedge_execution_service_test.rb` — updated close-fill test (source rename +
  close_fill_confirmation assertions).
- `test/services/migration_route_proof_registry_test.rb` — 2 new tests (certified-by-fill,
  fill-disagreement-not-ready); also made recurring hardcoded-June-date time-bombs relative.

## Tests run (test container, isolated DB)
- Executor: authoritative-fill ends window at fill ts (and slow readback still runs, later); fill+readback
  disagreement fails closed (not certified); partial/non-confirmed fill -> position readback + unsafe;
  no fill -> position readback (existing); default double-exposure threshold still 5s.
- Ethereal service: fast fill confirms before slow polling and surfaces `close_fill_confirmation`;
  fallback / partial / non-reduce-only / disabled-by-default unchanged.
- Registry: fill-shortened target_first canary -> READY_FOR_RANDOM; fill-disagreement canary -> not READY.
- Required suites (ethereal, executor, manual_live_canary_runner, route_proof_registry, manual_canary_gates,
  manual_canary_planner, random_readiness): **142 runs, 0 failures**. RuboCop on changed files: 0 offenses.

## Read-only verification commands
```
# is the fix deployed?
docker compose -f docker-compose.prod.yml exec -T web bin/rails runner \
  'puts HedgeVenueMigrationExecutor.private_instance_methods.include?(:apply_authoritative_source_close_confirmation!)'
# (currently => false: redeploy required)
```
After redeploy, a future approved `ethereal->extended` canary with
`ETHEREAL_CLOSE_FILL_CONFIRMATION_ENABLED=true` should show, in the receipt:
`double_exposure_end_source: "authoritative_fill"`, `source_close_fill_readback_agreement: true`,
`double_exposure_seconds` a few seconds, and `route_production_safe` not downgraded -> route certifies to
READY_FOR_RANDOM (6/6). No live execution was performed here.

## Redeploy needed
Yes. Verified read-only that the running image does NOT yet contain
`apply_authoritative_source_close_confirmation!`. The fix takes effect only after a rebuild/redeploy.

## Safety confirmation
No live canary, no runner start/restart, no gates enabled, no production DB/env/secrets mutation, no
venue-adapter/order-construction/route-policy change, threshold unchanged. Production state unchanged:
venue extended, extended short ~1.748, ethereal/nado flat, open orders zero, inside_tolerance=true, runner
inactive, route proofs 5/6.
