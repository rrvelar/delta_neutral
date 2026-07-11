# ethereal→extended double-exposure reduction — code + tests (NOT deployed)

**Route:** `ethereal->extended`, `target_first`.
**Goal:** reduce `double_exposure_seconds` below the `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS=5` gate.
**Status:** code + tests only. Nothing deployed, no canary, no gates armed, no orders/routes run, no thresholds/route policy/order construction changed, no blockers removed, no DB/env/secrets mutated.

⚠️ **Fragile-<5s certification:** the modelled floor after all four parts + Ethereal env constants is **~4.35s**, leaving only **~0.65s** of margin against Ethereal API jitter (each Ethereal read is ~2.8–3.1s and varies). A single slow order-list-fill GET can push a live measurement back over 5s. This remains a *fragile* attempt, not a durable guarantee.

## Files changed

| File | Part | Change |
|---|---|---|
| `app/services/migration_manual_live_canary_runner.rb` | A (builder) | `frozen_source_position_proof` builds a frozen source proof only when every invariant holds (target_first; from=ethereal; open orders zero; source snapshot fresh; migration DB gates armed; Ethereal auto paused; production runner inactive; planned source size present). Added injectable `production_runner_status:` seam for testing. Attaches proof to `receipt[:frozen_source_position]` before `run_precomputed_plan`. |
| `app/services/hedge_venue_migration_executor.rb` | A (consumer) | `DefaultLegRunner#frozen_ethereal_source_position` returns the frozen position (used **only** to seed the pre-close sizing read) when `invariants_proven == true`, sequence is target_first, venue is ethereal, and the frozen size matches the planned leg size within `FROZEN_SOURCE_SIZE_TOLERANCE=0.01`. Falls back to a fresh `venue.read_position` otherwise. The post-submit flat readback and order-list-fill confirmation are untouched. |
| `app/services/extended_mainnet_lifecycle_check.rb` | B | `read_only_account_diagnostics_for` returns `{status: "deferred", ...}` (no venue read) once an authoritative full fill (`extended_order_by_id_fill`, `confirmed == true`) is present, moving post-fill diagnostics off the double-exposure critical path. Final target readback still runs and is recorded. |
| `app/services/ethereal_hedge_execution_service.rb` | C, D | C: `build_order_preview(migration:)` defers the diagnostic-only `@venue.account_state` read for migration source closes (`account_diagnostics_deferred: true`, `account_value_usd`/`estimated_effective_leverage` nil). D: `ethereal_product_metadata_env_status` reports whether `ETHEREAL_LOT_SIZE`/`ETHEREAL_TICK_SIZE`/`ETHEREAL_ONCHAIN_ID` are all present so the `/v1/product` read can be skipped on the critical path; surfaced in the migration order preview. No blockers removed; `/v1/product` behavior unchanged when constants are absent. |

Test files changed: `test/services/hedge_venue_migration_executor_test.rb`, `test/services/migration_manual_live_canary_runner_test.rb`, `test/services/ethereal_hedge_execution_service_test.rb`, `test/services/extended_mainnet_lifecycle_check_test.rb`.

## Tests

**Suites run (throwaway test container, `RAILS_ENV=test`, isolated sqlite):**
`hedge_venue_migration_executor_test`, `migration_manual_live_canary_runner_test`, `ethereal_hedge_execution_service_test`, `extended_mainnet_lifecycle_check_test`, `migration_route_proof_registry_test`, `migration_manual_canary_gates_test`.

**Result: `210 runs, 1285 assertions, 0 failures, 0 errors, 0 skips`. RuboCop: `8 files inspected, no offenses detected`.**

Coverage of the 16 required checks:
- **A frozen proof used only when all invariants hold / falls back safely** — 6 consumer tests (`frozen_ethereal_source_position`) + 7 builder tests (`frozen_source_position_proof`: built when all hold; nil for unarmed gates, source auto enabled, open orders nonzero, stale snapshot, runner active, missing size, non-target_first).
- **Final Ethereal flat readback stays fresh post-submit / source close never confirmed on submit/accepted (must wait for order-list fill)** — covered by existing ethereal-service tests (`accepted submit requires readback confirmation before success`, `close probe close only success requires flat readback`, `close falls back fail-closed to position readback when order fill is unavailable`, `reduce-only close confirms via fast order fill before slow position polling`, `partial fill never confirms flat`). Part A reseeds only the pre-close sizing read; it does not touch this path.
- **B defers diagnostics after authoritative full fill; runs normally otherwise; target final readback still recorded; requires allowlisted source** — 3 Part B tests.
- **C migration close defers account_state (no balance read, deferred flag set); non-migration still reads it** — 2 Part C tests.
- **D env-present avoids /v1/product; env-absent keeps existing behavior; migration preview carries status, non-migration omits it** — 3 Part D tests.
- **Thresholds unchanged; route proof registry unchanged** — dedicated guard tests (all four latency thresholds 5/10/15/45; the 6-route `MigrationRouteProofRegistry::ROUTES` set).

## Before/after double-exposure model

| Scenario | Modelled `double_exposure_seconds` |
|---|---|
| Current (deployed) | **15.35s** |
| After A + B + C **with** Ethereal env constants set | **~4.35s** (<5s, fragile — ~0.65s margin) |
| After A + B + C **without** env constants (still reads `/v1/product`) | **~7.1s** (>5s — <5s unreachable) |

The ~4.35s path requires `ETHEREAL_LOT_SIZE`, `ETHEREAL_TICK_SIZE`, `ETHEREAL_ONCHAIN_ID` all set (all currently nil in prod). Without them the `/v1/product` read (~3s) stays on the critical path and <5s is unreachable — Part D reports this rather than inventing constants.

## Deploy steps (LATER — DO NOT run now)

1. Set `ETHEREAL_LOT_SIZE` / `ETHEREAL_TICK_SIZE` / `ETHEREAL_ONCHAIN_ID` from the authoritative `/v1/product` values (verify against a live read first).
2. Rebuild + restart the web image so the code goes live.
3. Run **one** supervised manual live canary for `ethereal->extended` under the full gated arm/disarm sequence; measure `double_exposure_seconds`.
4. Only if the measured value is safely < 5s does the route proof advance.

## Route-proof status

`ethereal->extended` remains **5/6** (still stale) until this code is deployed and re-measured by one supervised manual live canary. This change is code + tests only; it does not by itself move the proof.
