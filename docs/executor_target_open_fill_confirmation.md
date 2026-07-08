# Executor fix: start/gate target_first on the authoritative target-open FILL

**VPS:** France · **Path:** /opt/delta_neutral · **Date:** 2026-07-08
**Scope:** Code + tests only. No live canary, no runner start, no gates, no production DB/env/secrets
mutation, no venue-adapter/order-construction change, no route-policy change,
`MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` unchanged. **Not deployed** (redeploy required).

Fixes the real ~40s target_first overhedge for Ethereal-as-target: the Ethereal target-open leg now
returns/confirms on the authoritative order **FILL** (when enabled), so the executor submits the source
close immediately after a trusted target fill instead of after the slow ~34s position poll — and the
double-exposure window now **starts at the authoritative fill timestamp**, not after the readback.

---

## Root cause (recap)
For target_first the executor submits the source close only after `leg_runner(target)` returns. For an
Ethereal target OPEN, `execute()` fell through to `poll_post_submit_readback` (12 × ~2.8s ≈ 34s) because
the fast-fill path was **close-only**. So the source close was submitted ~34s late and both legs stayed
open ~40s. The window start (`target_leg_accepted_at ||= target_leg_submit_finished_at`) was also stamped
only after that slow readback, so receipts **understated** the real overhedge. See
`docs/target_first_real_double_exposure_root_cause.md`.

## Change

### Ethereal service (`app/services/ethereal_hedge_execution_service.rb`)
- `confirm_post_submit_readback` — new branch: for `action == "open"`, `expected_short > 0`,
  `open_fill_confirmation_enabled?`, and a present order id, try `fast_open_fill_readback` first; fall back
  to `poll_post_submit_readback` unless it authoritatively confirms.
- `open_fill_confirmation_enabled?` — reads `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED` (**default OFF**).
- `open_leg_size(order)` — the open order's `rounded_size_eth`.
- `fast_open_fill_readback(order_id:, open_size:)` — bounded poll of the order-list fill via
  `EtherealReadOnlyProbe#find_order` (validated `GET /v1/order` list). Confirms only on `classify_open_fill == :filled`;
  a `:partial` breaks and falls back; anything else keeps polling then falls back. On confirm returns
  `confirmation_source: "ethereal_order_list_open_fill"` + a `fill:` hash.
- `classify_open_fill(status, open_size:)` — `:filled` **only** when NOT reduce-only, terminal FILLED,
  `filled >= open_size − lot`, and `remaining` within one lot; `:partial` when partially filled; else
  `:unknown`. (Mirror of `classify_close_fill` with `reduce_only == false`.)
- `open_fill_confirmation(...)` helper + `result()` now surfaces `open_fill_confirmation` and (already)
  `readback_confirmation_source` — `confirmed_at` is the readback-confirmation time (when we
  authoritatively knew the open filled).

### Leg runner (`hedge_venue_migration_executor.rb` `DefaultLegRunner#normalize_service_result`)
- Passes `open_fill_confirmation: receipt[:open_fill_confirmation]` through to the leg result.

### Executor target_first flow (both sites: `run` and `execute_receipt`)
- After `record_target_acceptance_timing!`: `apply_authoritative_target_open_confirmation!(receipt, first_leg)`.
  - authoritative open fill present → `target_leg_accepted_at = fill.confirmed_at` (window start),
    `target_open_confirmation_source = fill.source`, `target_open_fill_confirmed_at = fill.confirmed_at`,
    `double_exposure_start_source = "authoritative_fill"`.
  - no authoritative fill → `double_exposure_start_source = "position_readback"`, existing
    `target_leg_submit_finished_at` start preserved byte-for-byte.
- `authoritative_target_open_fill` trusts only `confirmed == true`, `reduce_only == false`, timestamped,
  sourced confirmations. Never confirms on submit alone.
- After the final readback: `record_target_open_fill_agreement!(receipt)` records
  `target_open_position_readback_confirmed_at` and, when an authoritative fill was used,
  `target_open_fill_readback_agreement = (target_holds_expected_short == true)`.
- Because the target leg now returns on the fill, the source close is submitted immediately after the
  authoritative target fill (no separate control-flow change needed — the slow poll is what was gating it).
- The prior authoritative **source-close** fill fix is retained (covers Ethereal-as-source).

## Receipt fields added
- `target_open_confirmation_source` ("ethereal_order_list_open_fill" | "position_readback")
- `target_open_fill_confirmed_at`
- `target_open_position_readback_confirmed_at`
- `double_exposure_start_source` ("authoritative_fill" | "position_readback")
- `target_open_fill_readback_agreement` (true | false | nil)
- `open_fill_confirmation` (and, on the Ethereal receipt, `open_fill_confirmation` + `readback_confirmation_source`)

## Why this does NOT weaken safety
- **Never confirmed on submit.** An authoritative open requires the venue to report the order terminally
  FILLED, non-reduce-only, for at least the open size (remaining within one lot), validated by
  `classify_open_fill`. Partial / non-FILLED / reduce-only / 404 / ambiguous → fall back to the slow
  position readback (fail closed), and if that does not confirm, the existing
  `stop_after_unconfirmed_first_leg` path holds — **the source close is not submitted**.
- **Window start only moves EARLIER.** `fill.confirmed_at` is stamped inside the service before the leg
  returns, so it is always ≤ `target_leg_submit_finished_at`. A larger/equal window can only make the
  proof *more* conservative — it never masks real exposure.
- **Final readback still required.** After both legs, `final_readback_status` must independently confirm
  source flat, target holds expected short, third venue flat, zero open orders, inside tolerance. A fill
  that disagrees with the final readback → `target_open_fill_readback_agreement = false` and success is
  already false (target_holds is a success precondition) → not certified.
- `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS` unchanged (guard test still asserts 5). Route policy unchanged.
  Venue adapters / order construction unchanged. source_first path untouched.
- **Default OFF.** With `ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED` unset, behavior is byte-for-byte the
  slow position readback (asserted by the disabled-by-default test).

## Files changed
- `app/services/ethereal_hedge_execution_service.rb` — `confirm_post_submit_readback` (open branch),
  `open_fill_confirmation_enabled?`, `open_leg_size`, `fast_open_fill_readback`, `classify_open_fill`,
  `open_fill_confirmation`, `result()` wiring.
- `app/services/hedge_venue_migration_executor.rb` — `DefaultLegRunner#normalize_service_result`;
  `apply_authoritative_target_open_confirmation!`, `authoritative_target_open_fill`,
  `record_target_open_fill_agreement!`; wired into both `run` and `execute_receipt`.
- `test/services/ethereal_hedge_execution_service_test.rb` — 6 new tests + `open_fill_service`/`run_open`.
- `test/services/hedge_venue_migration_executor_test.rb` — 4 new tests + extended `run_ethereal_to_extended`.

## Functions changed / added
- Service: `confirm_post_submit_readback` (edit) · `open_fill_confirmation_enabled?` `open_leg_size`
  `fast_open_fill_readback` `classify_open_fill` `open_fill_confirmation` (new) · `result` (edit).
- Executor: `normalize_service_result` (edit) · `apply_authoritative_target_open_confirmation!`
  `authoritative_target_open_fill` `record_target_open_fill_agreement!` (new) · `run` / `execute_receipt`
  (two-line wiring each).

## Tests run (test container, isolated sqlite)
- Ethereal service: open confirms via fast fill before slow poll (source + `open_fill_confirmation`
  surfaced, ≤1 position read); partial open never fast-confirms; reduce-only fill ignored → position
  readback; unavailable/404 → position readback; **disabled by default → no order-status query, old
  behavior**; `classify_open_fill` unit (filled non-reduce vs reduce-only → :unknown).
- Executor: window starts at the authoritative fill timestamp (start_source `authoritative_fill`, fields
  set, start earlier than submit-finished, agreement true); no authoritative fill → position_readback
  start unchanged; disagreement → `agreement=false` and not success; **non-authoritative target open →
  source close NOT submitted** (`source_close_submit_started_at` nil).
- **All seven required suites: 152 runs, 1015 assertions, 0 failures, 0 errors.**
  (ethereal, executor, manual_live_canary_runner, route_proof_registry, manual_canary_gates,
  manual_canary_planner, random_readiness.) Existing authoritative source-close-fill and
  `MIGRATION_MAX_DOUBLE_EXPOSURE_SECONDS == 5` guard tests still pass.
- RuboCop on the 4 changed files: **0 offenses**.

## Read-only verification commands
```
# tests + rubocop (throwaway container, isolated test sqlite — never prod):
docker run --rm --user 0:0 -e RAILS_ENV=test -e SECRET_KEY_BASE=test_only_key \
  -v /opt/delta_neutral:/rails --entrypoint sh delta_neutral-web -lc \
  'bin/rails db:test:prepare && bin/rails test \
     test/services/ethereal_hedge_execution_service_test.rb \
     test/services/hedge_venue_migration_executor_test.rb \
     test/services/migration_manual_live_canary_runner_test.rb \
     test/services/migration_route_proof_registry_test.rb \
     test/services/migration_manual_canary_gates_test.rb \
     test/services/migration_manual_canary_planner_test.rb \
     test/services/migration_random_readiness_test.rb &&
   bin/rubocop app/services/ethereal_hedge_execution_service.rb \
     app/services/hedge_venue_migration_executor.rb'
```

## Redeploy needed
**Yes.** The running production image is baked (`build: .`, only `storage/` bind-mounted), so these
`app/services/*.rb` edits are not in the running container — they take effect only after a rebuild/redeploy.
The feature is additionally gated OFF by default; a future approved `extended->ethereal` canary would set
`ETHEREAL_OPEN_FILL_CONFIRMATION_ENABLED=true` to exercise it. After redeploy + enable, an
`extended->ethereal` target_first receipt should show `double_exposure_start_source: "authoritative_fill"`,
`target_open_confirmation_source: "ethereal_order_list_open_fill"`, and a materially smaller
`double_exposure_seconds` (source-close fill latency, not ~40s).

## Residual (venue-latency floor)
Even after the fix the overhedge floor is the **source-close fill** latency: an Ethereal source close
(with the close fast-fill) is ~1–3s (meets 5s); an **Extended** source close observed ~6s may still miss
5s by ~1s — a real venue floor to be measured from the next detailed-timestamp canary receipt, **not** a
threshold change.

## Safety confirmation
No live canary, no runner start/restart, no gates enabled, no production DB/env/secrets mutation, no
venue-adapter/order-construction/route-policy change, threshold unchanged, default OFF. Production state
unchanged: venue ethereal, runner inactive, route proofs 5/6.
